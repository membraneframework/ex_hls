defmodule ExHLS.Client do
  @moduledoc """
  Module providing functionality to read and demux HLS streams.
  It allows reading chunks from the stream, choosing variants, and managing media playlists.
  """

  use Bunch.Access

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @enforce_keys [
    :media_playlist,
    :media_base_url,
    :multivariant_playlist,
    :root_playlist_string,
    :base_url,
    :demuxing_engine_impl,
    :demuxing_engine,
    :media_types,
    :queues,
    :timestamp_offsets,
    :last_timestamps,
    :start_at_ms,
    :base_timestamp_ms,
    :end_stream_executed?
  ]

  defstruct @enforce_keys

  @opaque client :: %__MODULE__{}

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

  @spec new(String.t(), non_neg_integer()) :: client()
  def new(url, start_at_ms \\ 0) do
    %{status: 200, body: request_body} = Req.get!(url)
    multivariant_playlist = request_body |> ExM3U8.deserialize_multivariant_playlist!([])

    %__MODULE__{
      media_playlist: nil,
      media_base_url: nil,
      multivariant_playlist: multivariant_playlist,
      root_playlist_string: request_body,
      base_url: Path.dirname(url),
      demuxing_engine_impl: nil,
      demuxing_engine: nil,
      media_types: [:audio, :video],
      queues: %{audio: Qex.new(), video: Qex.new()},
      timestamp_offsets: %{audio: nil, video: nil},
      last_timestamps: %{audio: nil, video: nil},
      start_at_ms: start_at_ms,
      base_timestamp_ms: nil,
      end_stream_executed?: false
    }
  end

  defp ensure_media_playlist_loaded(%__MODULE__{media_playlist: nil} = client) do
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

  defp read_media_playlist_without_variant(%__MODULE__{media_playlist: nil} = client) do
    {deserialized_media_playlist, base_timestamp_ms} =
      client.root_playlist_string
      |> ExM3U8.deserialize_media_playlist!([])
      |> skip_to_start_at(client.start_at_ms)

    %{
      client
      | media_playlist: deserialized_media_playlist,
        media_base_url: client.base_url,
        base_timestamp_ms: base_timestamp_ms
    }
  end

  @spec get_variants(client()) :: %{optional(integer()) => variant_description()}
  def get_variants(%__MODULE__{} = client) do
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
  def choose_variant(%__MODULE__{} = client, variant_id) do
    chosen_variant =
      get_variants(client)
      |> Map.fetch!(variant_id)

    media_playlist = Path.join(client.base_url, chosen_variant.uri) |> Req.get!()

    {deserialized_media_playlist, base_timestamp_ms} =
      ExM3U8.deserialize_media_playlist!(media_playlist.body, [])
      |> skip_to_start_at(client.start_at_ms)

    media_base_url = Path.join(client.base_url, Path.dirname(chosen_variant.uri))

    %{
      client
      | media_playlist: deserialized_media_playlist,
        media_base_url: media_base_url,
        base_timestamp_ms: base_timestamp_ms
    }
  end

  @spec read_video_chunk(client()) :: {ExHLS.Chunk.t() | :end_of_stream, client()}
  def read_video_chunk(%__MODULE__{} = client), do: pop_queue_or_do_read_chunk(client, :video)

  @spec read_audio_chunk(client()) :: {ExHLS.Chunk.t() | :end_of_stream, client()}
  def read_audio_chunk(%__MODULE__{} = client), do: pop_queue_or_do_read_chunk(client, :audio)

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

  @spec do_read_chunk(client(), :audio | :video) ::
          {ExHLS.Chunk.t() | :end_of_stream | {:error, atom()}, client()}
  defp do_read_chunk(client, media_type) do
    client = ensure_media_playlist_loaded(client)

    with impl when impl != nil <- client.demuxing_engine_impl,
         {:ok, track_id} <- get_track_id(client, media_type),
         {:ok, chunk, demuxing_engine} <- client.demuxing_engine |> impl.pop_chunk(track_id) do
      client =
        with %{timestamp_offsets: %{^media_type => nil}} <- client do
          client
          |> put_in([:timestamp_offsets, media_type], chunk.dts_ms)
        end
        |> put_in([:last_timestamps, media_type], chunk.dts_ms)
        |> put_in([:demuxing_engine], demuxing_engine)

      chunk = normalize_timestamps(chunk, client.base_timestamp_ms)
      {chunk, client}
    else
      # returned from the second match
      :error ->
        client = %{client | media_types: client.media_types -- [media_type]}
        {{:error, :no_track_for_media_type}, client}

      # returned from the first or the third match
      other ->
        case other do
          {:error, _reason, demuxing_engine} -> %{client | demuxing_engine: demuxing_engine}
          nil -> client
        end
        |> download_chunk()
        |> case do
          {:ok, client} ->
            do_read_chunk(client, media_type)

          {:error, :no_more_segments, client} when not client.end_stream_executed? ->
            # after calling `end_stream/1` there is a chance that `pop_chunk/2` will flush
            # some remaining data
            %{client | end_stream_executed?: true}
            |> Map.update!(:demuxing_engine, &client.demuxing_engine_impl.end_stream/1)
            |> do_read_chunk(media_type)

          {:error, :no_more_segments, client} when client.end_stream_executed? ->
            {:end_of_stream, client}
        end
    end
  end

  @spec get_tracks_info(client()) ::
          {:ok, %{optional(integer()) => struct()}, client()}
          | {:error, reason :: any(), client()}
  def get_tracks_info(%__MODULE__{} = client) do
    with impl when impl != nil <- client.demuxing_engine_impl,
         {:ok, tracks_info} <- client.demuxing_engine |> impl.get_tracks_info() do
      {:ok, tracks_info, client}
    else
      _other ->
        media_type = media_type_with_lower_ts(client)
        {chunk_eos_or_error, client} = do_read_chunk(client, media_type)

        with %ExHLS.Chunk{} = chunk <- chunk_eos_or_error do
          client
          |> update_in([:queues, media_type], &Qex.push(&1, chunk))
          |> get_tracks_info()
        else
          :end_of_stream ->
            {:error, "end of stream reached, but tracks info is not available", client}

          {:error, :no_track_for_media_type} when client.media_types != [] ->
            client |> get_tracks_info()

          {:error, :no_track_for_media_type} when client.media_types == [] ->
            {:error, "no supported media types in HLS stream", client}
        end
    end
  end

  defp media_type_with_lower_ts(client) do
    cond do
      client.timestamp_offsets.audio == nil and :audio in client.media_types ->
        :audio

      client.timestamp_offsets.video == nil and :video in client.media_types ->
        :video

      true ->
        client.media_types
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

        {:error, :no_more_segments, client}
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

  defp skip_to_start_at(media_playlist, start_at_ms) do
    {discarded, timeline_with_cumulative_duration} =
      Enum.map_reduce(
        media_playlist.timeline,
        0,
        fn
          %ExM3U8.Tags.Segment{} = chunk, cumulative_duration_ms ->
            chunk_end_ms = cumulative_duration_ms + 1000 * chunk.duration
            {{chunk, chunk_end_ms}, chunk_end_ms}

          other_tag, cumulative_duration_ms ->
            {{other_tag, cumulative_duration_ms}, cumulative_duration_ms}
        end
      )
      |> elem(0)
      |> Enum.split_while(fn
        {_chunk, chunk_end_ms} -> chunk_end_ms <= start_at_ms
      end)

    base_timestamp_ms =
      case Enum.at(discarded, -1) do
        nil -> 0
        {_discarded_timeline, cumulative_duration_ms} -> cumulative_duration_ms
      end

    timeline = Enum.map(timeline_with_cumulative_duration, &elem(&1, 0))

    {put_in(media_playlist.timeline, timeline), base_timestamp_ms}
  end

  defp normalize_timestamps(chunk, base_timestamp_ms) do
    %{
      chunk
      | pts_ms: round(chunk.pts_ms + base_timestamp_ms),
        dts_ms: round(chunk.dts_ms + base_timestamp_ms)
    }
  end
end
