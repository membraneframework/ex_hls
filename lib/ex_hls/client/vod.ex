defmodule ExHLS.Client.VOD do
  @moduledoc false
  # Module providing functionality to read and demux HLS VOD streams.
  # It allows reading chunks from the stream, choosing variants, and managing media playlists.

  use Bunch.Access

  require Logger

  alias ExHLS.Client.Utils
  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @enforce_keys [
    :media_playlist,
    :media_base_url,
    :demuxing_engine_impl,
    :demuxing_engine,
    :media_types,
    :queues,
    :last_timestamps,
    :end_stream_executed?,
    :stream_ended_by_media_type
  ]

  defstruct @enforce_keys

  @opaque client :: %__MODULE__{}

  @doc """
  Starts the ExHLS client with the given URL and demuxing engine implementation.

  By default, it uses `DemuxingEngine.MPEGTS` as the demuxing engine implementation.
  """

  @spec new(String.t(), ExM3U8.MediaPlaylist.t()) :: client()
  def new(media_playlist_url, media_playlist) do
    :ok = generate_discontinuity_warnings(media_playlist)

    last_timestamps = %{audio: %{returned: nil, read: nil}, video: %{returned: nil, read: nil}}

    %__MODULE__{
      media_playlist: media_playlist,
      media_base_url: Path.dirname(media_playlist_url),
      demuxing_engine_impl: nil,
      demuxing_engine: nil,
      media_types: [:audio, :video],
      queues: %{audio: Qex.new(), video: Qex.new()},
      last_timestamps: last_timestamps,
      end_stream_executed?: false,
      stream_ended_by_media_type: %{audio: false, video: false}
    }
  end

  defp generate_discontinuity_warnings(media_playlist) do
    media_playlist.timeline
    |> Enum.each(fn
      %ExM3U8.Tags.Discontinuity{} ->
        Logger.warning("""
        [#{inspect(__MODULE__)}] Discontinuity tag found in the M3U8 media playlist. \
        This may cause issues in further handling the stream.
        """)

      _other_tag ->
        :ok
    end)
  end

  @spec read_chunk(client(), :audio | :video) ::
          {ExHLS.Chunk.t() | :end_of_stream | {:error, atom()}, client()}
  defp read_chunk(%__MODULE__{} = client, media_type) when media_type in [:audio, :video] do
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
          {ExHLS.Chunk.t() | :end_of_stream | {:error, :no_track_for_media_type}, client()}
  defp do_read_chunk(client, media_type) do
    with impl when impl != nil <- client.demuxing_engine_impl,
         {:ok, track_id} <- get_track_id(client, media_type),
         {:ok, chunk, demuxing_engine} <- client.demuxing_engine |> impl.pop_chunk(track_id) do
      chunk = %ExHLS.Chunk{chunk | media_type: media_type}

      client =
        client
        # |> put_in([:last_timestamps, media_type], chunk.dts_ms)
        |> put_in([:demuxing_engine], demuxing_engine)

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
            client =
              client
              |> put_in([:stream_ended_by_media_type, media_type], true)

            {:end_of_stream, client}
        end
    end
  end

  @spec generate_stream(client()) :: Enumerable.t(ExHLS.Chunk.t())
  def generate_stream(%__MODULE__{} = client) do
    Stream.unfold(client, &generate_next_stream_chunk/1)
  end

  defp generate_next_stream_chunk(client) do
    media_type = media_type_with_lower_ts(client, :return)

    case read_chunk(client, media_type) do
      {%ExHLS.Chunk{} = chunk, client} ->
        client =
          client
          |> put_in([:last_timestamps, media_type, :returned], chunk.dts_ms)

        {chunk, client}

      {:end_of_stream, client} ->
        halt_stream? =
          client.media_types
          |> Enum.all?(&client.stream_ended_by_media_type[&1])

        if halt_stream?,
          do: nil,
          else: generate_next_stream_chunk(client)
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
      _other -> read_streams_to_resolve_tracks_info(client)
    end
  end

  defp read_streams_to_resolve_tracks_info(client) do
    media_type = media_type_with_lower_ts(client, :read)
    {chunk_eos_or_error, client} = do_read_chunk(client, media_type)

    with %ExHLS.Chunk{} = chunk <- chunk_eos_or_error do
      client
      |> put_in([:last_timestamps, media_type, :read], chunk.dts_ms)
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

  defp media_type_with_lower_ts(client, mode) when mode in [:read, :return] do
    timestamp_type = if mode == :read, do: :read, else: :returned

    client.media_types
    |> Enum.max_by(fn media_type ->
      case client.last_timestamps[media_type][timestamp_type] do
        nil -> :infinity
        ts -> -ts
      end
    end)
  end

  defp download_chunk(client) do
    case client.media_playlist.timeline do
      [%{uri: segment_uri} | rest] ->
        client = ensure_demuxing_engine_resolved(client, segment_uri)

        segment_content =
          client.media_base_url
          |> Path.join(segment_uri)
          |> Utils.req_get_or_open_file!()

        demuxing_engine =
          client.demuxing_engine
          |> client.demuxing_engine_impl.feed!(segment_content)

        media_playlist = client.media_playlist |> Map.put(:timeline, rest)
        {:ok, %{client | demuxing_engine: demuxing_engine, media_playlist: media_playlist}}

      [_other_tag | rest] ->
        playlist = client.media_playlist |> Map.put(:timeline, rest)

        %{client | media_playlist: playlist}
        |> download_chunk()

      [] ->
        demuxing_engine =
          client.demuxing_engine
          |> client.demuxing_engine_impl.end_stream()

        client = %{client | demuxing_engine: demuxing_engine}
        {:error, :no_more_segments, client}
    end
  end

  defp ensure_demuxing_engine_resolved(%{demuxing_engine: nil} = client, segment_uri) do
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

  defp ensure_demuxing_engine_resolved(client, _segment_uri), do: client

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
