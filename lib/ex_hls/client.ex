defmodule ExHLS.Client do
  @moduledoc """
  Module providing functionality to read and demux HLS streams.
  It allows reading chunks from the stream, choosing variants, and managing media playlists.
  """

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @opaque client :: map()
  @type chunk :: any()

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

  @spec new(String.t()) :: client()
  def new(url) do
    %{status: 200, body: request_body} = Req.get!(url)
    multivariant_playlist = request_body |> ExM3U8.deserialize_multivariant_playlist!([])

    %{
      media_playlist: nil,
      media_base_url: nil,
      multivariant_playlist: multivariant_playlist,
      base_url: Path.dirname(url),
      video_chunks: [],
      demuxing_engine_impl: nil,
      demuxing_engine: nil,
      queues: %{audio: Qex.new(), video: Qex.new()},
      timestamp_offsets: %{audio: nil, video: nil},
      last_timestamps: %{audio: nil, video: nil}
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
        `choose_variant/2` function before reading chunks. Available variants:
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

  @spec read_video_chunk(client()) :: chunk() | :end_of_stream
  def read_video_chunk(client), do: pop_queue_or_do_read_chunk(client, :video)

  @spec read_audio_chunk(client()) :: chunk() | :end_of_stream
  def read_audio_chunk(client), do: pop_queue_or_do_read_chunk(client, :audio)

  defp pop_queue_or_do_read_chunk(client, media_type) do
    client.queues[media_type]
    |> Qex.pop()
    |> case do
      {{:value, chunk}, queue} ->
        client = client |> put_in([:queues, media_type], queue)
        {chunk, client}

      {:empty, _queue} ->
        do_read_chunk(client, media_type)
    end
  end

  @spec do_read_chunk(client(), :audio | :video) :: {chunk() | :end_of_stream, client()}
  defp do_read_chunk(client, media_type) do
    client = ensure_media_playlist_loaded(client)

    with impl when impl != nil <- client.demuxing_engine_impl,
         track_id <- get_track_id!(client, media_type),
         {:ok, chunk, demuxing_engine} <- client.demuxing_engine |> impl.pop_chunk(track_id) do
      client =
        with %{timestamp_offsets: %{^media_type => nil}} <- client do
          client |> put_in([:timestamp_offsets, media_type], chunk.dts_ms)
        end
        |> put_in([:last_timestamps, media_type], chunk.dts_ms)
        |> put_in([:demuxing_engine], demuxing_engine)

      {chunk, client}
    else
      other ->
        case other do
          {:error, _reason, demuxing_engine} -> %{client | demuxing_engine: demuxing_engine}
          nil -> client
        end
        |> download_chunk()
        |> case do
          {:ok, client} -> do_read_chunk(client, media_type)
          {:end_of_stream, client} -> {:end_of_stream, client}
        end
    end
  end

  @spec get_tracks_info(client()) ::
          {:ok, %{optional(integer()) => struct()}, client()}
          | {:error, reason :: any(), client()}
  def get_tracks_info(client) do
    with impl when impl != nil <- client.demuxing_engine_impl,
         {:ok, tracks_info} <- client.demuxing_engine |> impl.get_tracks_info() |> dbg() do
      {:ok, tracks_info, client}
    else
      _other ->
        media_type = media_type_with_lower_ts(client)
        {chunk_or_eos, client} = do_read_chunk(client, media_type)

        with %ExHLS.Chunk{} <- chunk_or_eos do
          client
          |> update_in([:queues, media_type], &Qex.push(&1, chunk_or_eos))
          |> get_tracks_info()
        else
          :end_of_stream ->
            {:error, "end of stream reached, but tracks info is not available", client}
        end
    end
  end

  defp media_type_with_lower_ts(client) do
    cond do
      client.timestamp_offsets.audio == nil ->
        :audio

      client.timestamp_offsets.video == nil ->
        :video

      true ->
        [:audio, :video]
        |> Enum.min_by(fn media_type ->
          client.last_timestamps[media_type] - client.timestamp_offsets[media_type]
        end)
    end
  end

  defp download_chunk(client) do
    client = ensure_media_playlist_loaded(client)

    case client.media_playlist.timeline do
      [%{uri: segment_uri} | rest] ->
        client =
          with %{demuxing_engine: nil} <- client do
            resolve_demuxing_engine(segment_uri, client)
          end

        request_result =
          Path.join(client.media_base_url, segment_uri)
          |> Req.get!()

        demuxing_engine =
          client.demuxing_engine
          |> client.demuxing_engine_impl.feed!(request_result.body)

        client =
          %{
            client
            | demuxing_engine: demuxing_engine,
              media_playlist: %{client.media_playlist | timeline: rest}
          }

        {:ok, client}

      [_other_tag | rest] ->
        %{client | media_playlist: %{client.media_playlist | timeline: rest}}
        |> download_chunk()

      [] ->
        client =
          client
          |> Map.update!(:demuxing_engine, &client.demuxing_engine_impl.end_stream/1)

        {:end_of_stream, client}
    end
  end

  defp resolve_demuxing_engine(segment_uri, %{demuxing_engine: nil} = client) do
    demuxing_engine_impl =
      case Path.extname(segment_uri) do
        ".ts" -> DemuxingEngine.MPEGTS
        ".m4s" -> DemuxingEngine.CMAF
        ".mp4" -> DemuxingEngine.CMAF
        _other -> raise "Unsupported segment URI extension: #{segment_uri |> inspect()}"
      end

    %{
      client
      | demuxing_engine_impl: demuxing_engine_impl,
        demuxing_engine: demuxing_engine_impl.new()
    }
  end

  defp get_track_id!(client, type) when type in [:audio, :video] do
    case get_track_id(client, type) do
      {:ok, track_id} -> track_id
      :error -> raise "Track ID for #{type} not found in client #{inspect(client, pretty: true)}"
    end
  end

  defp get_track_id(client, type) when type in [:audio, :video] do
    impl = client.demuxing_engine_impl

    with {:ok, tracks_info} <- client.demuxing_engine |> impl.get_tracks_info() do
      tracks_info
      |> Enum.find_value(:error, fn
        {id, %AAC{}} when type == :audio -> {:ok, id}
        {id, %RemoteStream{content_format: AAC}} when type == :audio -> {:ok, id}
        {id, %H264{}} when type == :video -> {:ok, id}
        {id, %RemoteStream{content_format: H264}} when type == :video -> {:ok, id}
        _different_type -> false
      end)
    else
      {:error, _reason} -> :error
    end
  end
end
