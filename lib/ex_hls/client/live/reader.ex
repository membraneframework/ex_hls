defmodule ExHLS.Client.Live.Reader do
  @moduledoc false

  use GenServer

  require Logger

  alias ExHLS.Client.Live.Forwarder
  alias ExHLS.Client.Utils

  alias ExM3U8.Tags.{MediaInit, Segment}

  @spec start_link(String.t(), Forwarder.t()) :: {:ok, pid()} | {:error, any()}
  def start_link(media_playlist_url, forwarder) do
    GenServer.start_link(__MODULE__, %{
      media_playlist_url: media_playlist_url,
      forwarder: forwarder
    })
  end

  @impl true
  def init(%{media_playlist_url: media_playlist_url, forwarder: forwarder}) do
    state = %{
      forwarder: forwarder,
      tracks_data: nil,
      tracks_info_handled?: false,
      media_playlist: nil,
      media_playlist_url: media_playlist_url,
      media_base_url: Path.dirname(media_playlist_url),
      demuxing_engine_impl: nil,
      demuxing_engine: nil,
      end_stream_executed?: false,
      media_init_downloaded?: false,
      max_downloaded_seq_num: nil,
      playlist_check_scheduled?: false,
      timestamp_offset: nil,
      playing_started?: false
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    state = check_media_playlist(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_media_playlist, state) do
    state =
      %{state | playlist_check_scheduled?: false}
      |> check_media_playlist()

    {:noreply, state}
  end

  defp check_media_playlist(state) do
    Logger.debug("[ExHLS.Client] Checking media playlist at #{state.media_playlist_url}")

    media_playlist =
      state.media_playlist_url
      |> Utils.download_or_read_file!()
      |> ExM3U8.deserialize_media_playlist!([])

    state = %{state | media_playlist: media_playlist}

    :ok = generate_discontinuity_warnings(state)

    state
    |> schedule_next_playlist_check()
    |> maybe_download_chunks()
  end

  defp generate_discontinuity_warnings(state) do
    state.media_playlist.timeline
    |> Enum.each(fn
      %ExM3U8.Tags.Discontinuity{} ->
        Logger.warning("""
        [ExHLS.Client] Discontinuity tag found in the M3U8 media playlist. \
        This may cause issues in further handling the stream.
        """)

      _other_tag ->
        :ok
    end)
  end

  defp maybe_download_chunks(state) do
    cond do
      state.playing_started? ->
        download_chunks(state)

      should_start_playing?(state) ->
        %{state | playing_started?: true}
        |> download_chunks()

      true ->
        state
    end
  end

  defp should_start_playing?(state) do
    %ExM3U8.MediaPlaylist.Info{
      media_sequence: media_sequence,
      target_duration: target_duration,
      end_list?: end_list?
    } = state.media_playlist.info

    end_list? or
      (is_number(media_sequence) and media_sequence >= 1) or
      segments_duration_sum(state) >= 2 * target_duration
  end

  defp segments_duration_sum(state) do
    state.media_playlist.timeline
    |> Enum.flat_map(fn
      %Segment{duration: duration} -> [duration]
      _other_tag -> []
    end)
    |> Enum.sum()
  end

  defp download_chunks(state) do
    {maybe_media_init, state} = get_media_inits_to_download(state)

    download_from_seq_num =
      next_segment_to_download_seq_num(state)

    segments_to_download_with_seq_nums =
      state.media_playlist.timeline
      |> Enum.filter(&match?(%Segment{}, &1))
      |> Enum.with_index(state.media_playlist.info.media_sequence)
      |> Enum.filter(fn {_segment, seq_num} -> seq_num >= download_from_seq_num end)

    {segments_to_download, seq_nums} = segments_to_download_with_seq_nums |> Enum.unzip()

    state =
      state
      |> Map.update!(:max_downloaded_seq_num, fn
        nil -> seq_nums |> Enum.max(&>=/2, fn -> nil end)
        number -> [number | seq_nums] |> Enum.max()
      end)

    (maybe_media_init ++ segments_to_download)
    |> Enum.reduce(state, &download_and_consume_segment/2)
    |> maybe_end_stream()
  end

  defp get_media_inits_to_download(%{media_init_downloaded?: true} = state), do: {[], state}

  defp get_media_inits_to_download(state) do
    media_inits =
      state.media_playlist.timeline
      |> Enum.flat_map(fn
        %MediaInit{} = media_init -> [media_init]
        _other_tag -> []
      end)

    {media_inits, %{state | media_init_downloaded?: true}}
  end

  defp next_segment_to_download_seq_num(%{max_downloaded_seq_num: nil} = state) do
    {segments_with_end_times, duration_sum} =
      state.media_playlist.timeline
      |> Enum.flat_map_reduce(0, fn
        %Segment{} = segment, duration_acc ->
          duration_acc = duration_acc + segment.duration
          {[{segment, duration_acc}], duration_acc}

        _other_tag, duration_acc ->
          {[], duration_acc}
      end)

    start_time = duration_sum - 2 * state.media_playlist.info.target_duration

    segment_index =
      segments_with_end_times
      |> Enum.find_index(fn {_segment, segment_end_time} ->
        start_time <= segment_end_time
      end)

    segment_index + state.media_playlist.info.media_sequence
  end

  defp next_segment_to_download_seq_num(%{max_downloaded_seq_num: last_seq_num}) do
    last_seq_num + 1
  end

  defp schedule_next_playlist_check(%{end_stream_executed?: true} = state) do
    Logger.warning("[ExHLS.Client] Not scheduling next playlist check, end of playlist reached")
    state
  end

  defp schedule_next_playlist_check(%{playlist_check_scheduled?: false} = state) do
    # Playlist check interval is 1/4 of target duration, while the RFC says to set it
    # to 1/2 of target duration. We do it this way to reduce the chance of race condition
    # occuring when we check the playlist just before the server updates it.

    playlist_check_timeout_ms =
      (state.media_playlist.info.target_duration * 250) |> round()

    Process.send_after(self(), :check_media_playlist, playlist_check_timeout_ms)

    %{state | playlist_check_scheduled?: true}
  end

  # todo maybe warn / raise?
  defp schedule_next_playlist_check(state) do
    Logger.warning("[ExHLS.Client] Media playlist check already scheduled, weird")
    state
  end

  defp download_and_consume_segment(segment, state) do
    uri =
      case URI.new!(segment.uri).host do
        nil -> Path.join(state.media_base_url, segment.uri)
        _some_host -> segment.uri
      end

    Logger.debug("[ExHLS.Client] Downloading segment: #{uri}")

    segment_content = Utils.download_or_read_file!(uri)

    state = maybe_resolve_demuxing_engine(segment.uri, state)

    consume_segment_content(segment_content, state)
  end

  defp consume_segment_content(segment_content, state) do
    feed_demuxing_engine(segment_content, state)
    |> maybe_read_and_send_chunks()
  end

  defp feed_demuxing_engine(segment_content, state) do
    demuxing_engine =
      state.demuxing_engine
      |> state.demuxing_engine_impl.feed!(segment_content)

    %{state | demuxing_engine: demuxing_engine}
    |> mark_tracks_as_not_empty()
  end

  defp mark_tracks_as_not_empty(%{tracks_data: nil} = state), do: state

  defp mark_tracks_as_not_empty(state) do
    state.tracks_data
    |> Map.keys()
    |> Enum.reduce(state, fn track_id, state ->
      state
      |> put_in([:tracks_data, track_id, :empty?], false)
    end)
  end

  defp maybe_read_and_send_chunks(state) do
    state.demuxing_engine
    |> state.demuxing_engine_impl.get_tracks_info()
    |> case do
      {:ok, tracks_info} ->
        ensure_tracks_info_handled(tracks_info, state)
        |> read_and_send_chunks()

      {:error, _reason} ->
        state
    end
  end

  defp ensure_tracks_info_handled(tracks_info, %{tracks_info_handled?: false} = state) do
    Forwarder.feed_with_tracks_info(state.forwarder, tracks_info)
    state = %{state | tracks_info_handled?: true}
    init_tracks_data(tracks_info, state)
  end

  defp ensure_tracks_info_handled(_tracks_info, state), do: state

  defp read_and_send_chunks(state) do
    with {:ok, track_id} <- track_id_to_read(state) do
      read_and_send_track_chunk(track_id, state)
      |> read_and_send_chunks()
    else
      {:error, :no_track_to_read} -> state
    end
  end

  defp read_and_send_track_chunk(track_id, state) do
    case state.demuxing_engine
         |> state.demuxing_engine_impl.pop_chunk(track_id) do
      {:ok, chunk, demuxing_engine} ->
        media_type = state.tracks_data[track_id].media_type
        chunk = %ExHLS.Chunk{chunk | media_type: media_type}
        Forwarder.feed_with_media_chunk(state.forwarder, media_type, chunk)

        ts = if chunk.dts_ms != nil, do: chunk.dts_ms, else: chunk.pts_ms

        %{
          state
          | demuxing_engine: demuxing_engine,
            timestamp_offset: state.timestamp_offset || ts
        }
        |> put_in([:tracks_data, track_id, :last_ts], ts)

      {:error, :empty_track_data, demuxing_engine} ->
        %{state | demuxing_engine: demuxing_engine}
        |> put_in([:tracks_data, track_id, :empty?], true)
    end
  end

  defp maybe_end_stream(state) do
    if not state.end_stream_executed? and state.media_playlist.info.end_list? and
         last_segment_seq_num(state) <= state.max_downloaded_seq_num do
      demuxing_engine =
        state.demuxing_engine
        |> state.demuxing_engine_impl.end_stream()

      %{state | demuxing_engine: demuxing_engine, end_stream_executed?: true}
      |> mark_tracks_as_not_empty()
      |> read_and_send_chunks()
      |> send_eos()
    else
      state
    end
  end

  defp last_segment_seq_num(state) do
    segments_in_playlist_number =
      state.media_playlist.timeline
      |> Enum.count(&match?(%Segment{}, &1))

    state.media_playlist.info.media_sequence + segments_in_playlist_number - 1
  end

  defp init_tracks_data(tracks_info, %{tracks_data: nil} = state) do
    tracks_data =
      tracks_info
      |> Map.new(fn {track_id, track_info} ->
        track_data = %{
          id: track_id,
          media_type: Utils.stream_format_to_media_type(track_info),
          empty?: false,
          last_ts: nil,
          eos_sent?: false
        }

        {track_id, track_data}
      end)

    %{state | tracks_data: tracks_data}
  end

  defp send_eos(state) do
    state.tracks_data
    |> Enum.reduce(state, fn {track_id, %{eos_sent?: false} = track_data}, state ->
      :ok =
        Forwarder.feed_with_end_of_stream(
          state.forwarder,
          track_data.media_type
        )

      state
      |> put_in([:tracks_data, track_id, :eos_sent?], true)
    end)
  end

  defp track_id_to_read(state) do
    {maybe_audio_track, maybe_video_track} =
      state.tracks_data
      |> Map.values()
      |> Enum.split_with(&(&1.media_type == :audio))

    cond do
      doesnt_exist_or_empty?(maybe_audio_track) and doesnt_exist_or_empty?(maybe_video_track) ->
        {:error, :no_track_to_read}

      doesnt_exist_or_empty?(maybe_audio_track) ->
        [video_track_data] = maybe_video_track
        {:ok, video_track_data.id}

      doesnt_exist_or_empty?(maybe_video_track) ->
        [audio_track_data] = maybe_audio_track
        {:ok, audio_track_data.id}

      true ->
        {track_id, _track_data} =
          state.tracks_data
          |> Enum.max_by(fn
            {_track_id, %{last_ts: nil}} -> :infinity
            {_track_id, track_data} -> -track_data.last_ts
          end)

        {:ok, track_id}
    end
  end

  defp doesnt_exist_or_empty?([]), do: true
  defp doesnt_exist_or_empty?([track_data]), do: track_data.empty?

  defp maybe_resolve_demuxing_engine(segment_uri, %{demuxing_engine: nil} = state) do
    demuxing_engine_impl = Utils.resolve_demuxing_engine_impl(segment_uri)

    %{
      state
      | demuxing_engine_impl: demuxing_engine_impl,
        demuxing_engine: demuxing_engine_impl.new(0)
    }
  end

  defp maybe_resolve_demuxing_engine(_segment_uri, state), do: state
end
