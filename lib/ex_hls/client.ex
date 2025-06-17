defmodule ExHLS.Client do
  @moduledoc "HLS Client"

  use GenServer

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @type state :: map()
  @type frame :: any()
  @opaque client :: pid()

  @h264_time_base 90_000

  def start(url, demuxing_engine_impl \\ DemuxingEngine.MPEGTS) do
    GenServer.start(__MODULE__, url: url, demuxing_engine_impl: demuxing_engine_impl)
  end

  @impl true
  def init(url: url, demuxing_engine_impl: demuxing_engine_impl) do
    playlist_content = Req.get!(url).body

    state = %{
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
    variants =
      state.multivariant_playlist.items
      |> Enum.map(fn variant -> {variant.name, variant_description(variant)} end)
      |> Map.new()

    {:reply, variants, state}
  end

  @impl true
  def handle_call({:choose_variant, variant_name}, _from, state) do
    chosen_variant =
      Enum.find(state.multivariant_playlist.items, fn variant -> variant.name == variant_name end)

    media_playlist = Path.join(state.base_url, chosen_variant.uri) |> Req.get!()

    state =
      Map.put(state, :media_playlist, ExM3U8.deserialize_media_playlist!(media_playlist.body, []))

    media_base_url = Path.join(state.base_url, Path.dirname(chosen_variant.uri))
    state = Map.put(state, :media_base_url, media_base_url)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:read_frame, media_type}, _from, state) do
    track_id = get_track_id(state, media_type)
    {result, state} = do_read_frame(state, track_id)
    {:reply, result, state}
  end

  @spec read_variants(client()) :: map()
  def read_variants(pid) do
    GenServer.call(pid, :read_variants)
  end

  @spec choose_variant(client(), String.t()) :: :ok
  def choose_variant(pid, variant_name) do
    GenServer.call(pid, {:choose_variant, variant_name})
  end

  def read_video_frame(pid) do
    GenServer.call(pid, {:read_frame, :video})
  end

  def read_audio_frame(pid) do
    GenServer.call(pid, {:read_frame, :audio})
  end

  @spec do_read_frame(state(), integer()) :: {frame() | :end_of_stream, state()}
  defp do_read_frame(state, track_id) do
    impl = state.demuxing_engine_impl

    case state.demuxing_engine |> impl.pop_frame(track_id) do
      {:error, :empty_track_data, demuxing_engine} ->
        %{state | demuxing_engine: demuxing_engine}
        |> download_chunk()
        |> case do
          {:ok, state} -> do_read_frame(state, track_id)
          {:end_of_stream, state} -> {:end_of_stream, state}
        end

      {:ok, frame, demuxing_engine} ->
        state = %{state | demuxing_engine: demuxing_engine}
        {frame, state}
    end
  end

  defp variant_description(variant) do
    %{
      framerate: variant.frame_rate,
      resolution: variant.resolution,
      codecs: variant.codecs,
      bandwidth: variant.bandwidth
    }
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

        # |> put_in([:media_playlist, :timeline], rest)

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

  defp convert_h264_ts(nil), do: nil

  defp convert_h264_ts(ts) do
    (ts * ExHLS.Frame.time_base() / @h264_time_base)
    |> trunc()
  end
end
