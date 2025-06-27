defmodule ExHLS.Client do
  @moduledoc """
  Module providing functionality to demux HLS streams.
  It allows reading frames from the stream, choosing variants, and managing media playlists.
  """

  use GenServer

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @type state :: map()
  @type frame :: any()
  @opaque client :: pid()

  @doc """
  Starts the ExHLS client with the given URL and demuxing engine implementation.

  By default, it uses `DemuxingEngine.MPEGTS` as the demuxing engine implementation.
  """
  @spec start(String.t(), DemuxingEngine.MPEGTS | DemuxingEngine.CMAF) ::
          {:ok, client()} | {:error, term()}
  def start(url, demuxing_engine_impl \\ DemuxingEngine.MPEGTS) do
    GenServer.start(__MODULE__, url: url, demuxing_engine_impl: demuxing_engine_impl)
  end

  @impl true
  def init(url: url, demuxing_engine_impl: demuxing_engine_impl) do
    playlist_content = Req.get!(url).body

    state = %{
      media_playlist: nil,
      media_base_url: nil,
      multivariant_playlist: ExM3U8.deserialize_multivariant_playlist!(playlist_content, []),
      base_url: Path.dirname(url),
      audio_frames: [],
      video_frames: [],
      demuxing_engine_impl: demuxing_engine_impl,
      demuxing_engine: demuxing_engine_impl.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:read_variants, _from, state) do
    {:reply, get_variants_map(state), state}
  end

  @impl true
  def handle_call({:choose_variant, variant_id}, _from, state) do
    state = handle_choose_variant(variant_id, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:read_frame, media_type}, _from, state) do
    {result, state} = do_read_frame(state, media_type)
    {:reply, result, state}
  end

  defp get_variants_map(state) do
    state.multivariant_playlist.items
    |> Enum.flat_map(fn
      %ExM3U8.Tags.Stream{} = variant -> [variant_description(variant)]
      _other_tag -> []
    end)
    |> Enum.with_index(fn variant, index -> {index, variant} end)
    |> Map.new()
  end

  defp variant_description(%ExM3U8.Tags.Stream{} = variant) do
    variant
    |> Map.take([:frame_rate, :resolution, :codecs, :bandwidth, :uri])
  end

  defp handle_choose_variant(variant_id, state) do
    chosen_variant =
      get_variants_map(state)
      |> Map.fetch!(variant_id)

    media_playlist = Path.join(state.base_url, chosen_variant.uri) |> Req.get!()

    deserialized_media_playlist =
      ExM3U8.deserialize_media_playlist!(media_playlist.body, [])

    media_base_url = Path.join(state.base_url, Path.dirname(chosen_variant.uri))

    %{
      state
      | media_playlist: deserialized_media_playlist,
        media_base_url: media_base_url
    }
  end

  defp ensure_media_playlist_loaded(%{media_playlist: nil} = state) do
    state
  end

  defp ensure_media_playlist_loaded(state) do
    get_variants_map(state)
    |> Map.to_list()
    |> case do
      [] ->
        read_media_playlist_without_variant(state)

      [{variant_id, _variant}] ->
        handle_choose_variant(variant_id, state)

      _many_variants ->
        raise """
        If there are available variants, you have to choose one of them using `choose_variant/2` function \
        before reading frames. \
        Available variants: #{state.multivariant_playlist.items |> Enum.map(& &1.name) |> inspect(limit: :infinity)}. \
        You can get more info using `read_variants/1` function.
        """
    end
  end

  defp read_media_playlist_without_variant(%{media_playlist: nil} = state) do
    media_playlist =
      state.base_url
      |> Path.join("output.m3u8")
      |> Req.get!()

    deserialized_media_playlist =
      ExM3U8.deserialize_media_playlist!(media_playlist.body, [])

    %{
      state
      | media_playlist: deserialized_media_playlist,
        media_base_url: state.base_url
    }
  end

  @spec read_variants(client()) :: %{optional(String.t()) => struct()}
  def read_variants(pid) do
    GenServer.call(pid, :read_variants)
  end

  @spec choose_variant(client(), String.t()) :: :ok
  def choose_variant(pid, variant_name) do
    GenServer.call(pid, {:choose_variant, variant_name})
  end

  @spec read_video_frame(client()) :: frame() | :end_of_stream
  def read_video_frame(pid) do
    GenServer.call(pid, {:read_frame, :video})
  end

  @spec read_audio_frame(client()) :: frame() | :end_of_stream
  def read_audio_frame(pid) do
    GenServer.call(pid, {:read_frame, :audio})
  end

  @spec do_read_frame(state(), :audio | :video) :: {frame() | :end_of_stream, state()}
  defp do_read_frame(state, media_type) do
    state = ensure_media_playlist_loaded(state)

    impl = state.demuxing_engine_impl
    track_id = get_track_id(state, media_type)

    case state.demuxing_engine |> impl.pop_frame(track_id) do
      {:error, _reason, demuxing_engine} ->
        %{state | demuxing_engine: demuxing_engine}
        |> download_chunk()
        |> case do
          {:ok, state} -> do_read_frame(state, media_type)
          {:end_of_stream, state} -> {:end_of_stream, state}
        end

      {:ok, frame, demuxing_engine} ->
        state = %{state | demuxing_engine: demuxing_engine}
        {frame, state}
    end
  end

  defp download_chunk(state) do
    impl = state.demuxing_engine_impl

    case List.pop_at(state.media_playlist.timeline, 0) do
      {nil, []} ->
        state = state |> Map.update!(:demuxing_engine, &impl.end_stream/1)
        {:end_of_stream, state}

      {segment_info, rest} ->
        request_result =
          Path.join(state.media_base_url, segment_info.uri)
          |> Req.get!()

        demuxing_engine = state.demuxing_engine |> impl.feed!(request_result.body)

        state =
          %{
            state
            | demuxing_engine: demuxing_engine,
              media_playlist: %{state.media_playlist | timeline: rest}
          }

        {:ok, state}
    end
  end

  defp get_track_id(state, type) when type in [:audio, :video] do
    impl = state.demuxing_engine_impl

    with {:ok, tracks_info} <- state.demuxing_engine |> impl.get_tracks_info() do
      tracks_info
      |> Enum.find_value(fn
        {id, %AAC{}} when type == :audio -> id
        {id, %RemoteStream{content_format: AAC}} when type == :audio -> id
        {id, %H264{}} when type == :video -> id
        {id, %RemoteStream{content_format: H264}} when type == :video -> id
        _different_type -> nil
      end)
    else
      {:error, _reason} -> nil
    end
  end
end
