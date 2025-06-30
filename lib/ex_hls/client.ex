defmodule ExHLS.Client do
  @moduledoc """
  Module providing functionality to demux HLS streams.
  It allows reading frames from the stream, choosing variants, and managing media playlists.
  """

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @opaque client :: map()
  @type frame :: any()

  @type variant_description :: %{
          id: integer(),
          name: String.t() | nil,
          frame_rate: number() | nil,
          resolution: {integer(), integer()} | nil,
          codecs: String.t() | nil,
          bandwidth: integer() | nil,
          uri: String.t() | nil
        }

  @doc """
  Starts the ExHLS client with the given URL and demuxing engine implementation.

  By default, it uses `DemuxingEngine.MPEGTS` as the demuxing engine implementation.
  """

  @spec new(String.t(), DemuxingEngine.MPEGTS | DemuxingEngine.CMAF) :: client()
  def new(url, demuxing_engine_impl \\ DemuxingEngine.MPEGTS) do
    multivariant_playlist =
      Req.get!(url).body
      |> ExM3U8.deserialize_multivariant_playlist!([])

    %{
      media_playlist: nil,
      media_base_url: nil,
      multivariant_playlist: multivariant_playlist,
      base_url: Path.dirname(url),
      audio_frames: [],
      video_frames: [],
      demuxing_engine_impl: demuxing_engine_impl,
      demuxing_engine: demuxing_engine_impl.new()
    }
  end

  defp ensure_media_playlist_loaded(%{media_playlist: nil} = client) do
    get_variants(client)
    |> Map.to_list()
    |> case do
      [] ->
        read_media_playlist_without_variant(client)

      [{variant_id, _variant}] ->
        choose_variant(client, variant_id)

      _many_variants ->
        raise """
        If there are available variants, you have to choose one of them using \
        `choose_variant/2` function before reading frames. Available variants:
        #{get_variants(client) |> inspect(limit: :infinity, pretty: true)}
        """
    end
  end

  defp ensure_media_playlist_loaded(client), do: client

  defp read_media_playlist_without_variant(%{media_playlist: nil} = client) do
    media_playlist =
      client.base_url
      |> Path.join("output.m3u8")
      |> Req.get!()

    deserialized_media_playlist =
      ExM3U8.deserialize_media_playlist!(media_playlist.body, [])

    %{
      client
      | media_playlist: deserialized_media_playlist,
        media_base_url: client.base_url
    }
  end

  @spec get_variants(client()) :: %{optional(integer()) => variant_description()}
  def get_variants(client) do
    client.multivariant_playlist.items
    |> Enum.filter(&match?(%ExM3U8.Tags.Stream{}, &1))
    |> Enum.with_index(fn variant, index ->
      variant_description =
        variant
        |> Map.take([:name, :frame_rate, :resolution, :codecs, :bandwidth, :uri])
        |> Map.put(:id, index)

      {index, variant_description}
    end)
    |> Map.new()
  end

  @spec choose_variant(client(), String.t()) :: client()
  def choose_variant(client, variant_id) do
    chosen_variant =
      get_variants(client)
      |> Map.fetch!(variant_id)

    media_playlist = Path.join(client.base_url, chosen_variant.uri) |> Req.get!()

    deserialized_media_playlist =
      ExM3U8.deserialize_media_playlist!(media_playlist.body, [])

    media_base_url = Path.join(client.base_url, Path.dirname(chosen_variant.uri))

    %{
      client
      | media_playlist: deserialized_media_playlist,
        media_base_url: media_base_url
    }
  end

  @spec read_video_frame(client()) :: frame() | :end_of_stream
  def read_video_frame(client), do: do_read_frame(client, :video)

  @spec read_audio_frame(client()) :: frame() | :end_of_stream
  def read_audio_frame(client), do: do_read_frame(client, :audio)

  @spec do_read_frame(client(), :audio | :video) :: {frame() | :end_of_stream, client()}
  defp do_read_frame(client, media_type) do
    client = ensure_media_playlist_loaded(client)

    impl = client.demuxing_engine_impl
    track_id = get_track_id(client, media_type)

    case client.demuxing_engine |> impl.pop_frame(track_id) do
      {:error, _reason, demuxing_engine} ->
        %{client | demuxing_engine: demuxing_engine}
        |> download_chunk()
        |> case do
          {:ok, client} -> do_read_frame(client, media_type)
          {:end_of_stream, client} -> {:end_of_stream, client}
        end

      {:ok, frame, demuxing_engine} ->
        client = %{client | demuxing_engine: demuxing_engine}
        {frame, client}
    end
  end

  defp download_chunk(client) do
    impl = client.demuxing_engine_impl

    case List.pop_at(client.media_playlist.timeline, 0) do
      {nil, []} ->
        client = client |> Map.update!(:demuxing_engine, &impl.end_stream/1)
        {:end_of_stream, client}

      {segment_info, rest} ->
        request_result =
          Path.join(client.media_base_url, segment_info.uri)
          |> Req.get!()

        demuxing_engine = client.demuxing_engine |> impl.feed!(request_result.body)

        client =
          %{
            client
            | demuxing_engine: demuxing_engine,
              media_playlist: %{client.media_playlist | timeline: rest}
          }

        {:ok, client}
    end
  end

  defp get_track_id(client, type) when type in [:audio, :video] do
    impl = client.demuxing_engine_impl

    with {:ok, tracks_info} <- client.demuxing_engine |> impl.get_tracks_info() do
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
