defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  use Bunch.Access
  use Bunch

  require Logger
  alias Membrane.{AAC, H264, RemoteStream}
  alias MPEG.TS.Demuxer

  @enforce_keys [:demuxer, :last_tden_tag]
  defstruct @enforce_keys ++ [track_timestamps_data: %{}]

  # using it a boundary expressed in nanoseconds, instead of the usual 90kHz clock ticks,
  # generates up to 1/10th of ms error per 26.5 hours of stream which is acceptable in
  # this context
  @timestamp_range_size_ns div(2 ** 33 * 1_000_000_000, 90_000)

  @type t :: %__MODULE__{
          demuxer: Demuxer.t(),
          last_tden_tag: String.t() | nil
        }

  @impl true
  # timestamp_offset_ms is not used in MPEG-TS demuxing as MPEG-TS packets already contain
  # proper timestamps however we keep this argument to keep the interface consistent between
  # different demuxing engines
  def new(_timestamp_offset_ms) do
    demuxer = Demuxer.new()

    # we need to explicitly override that `waiting_random_access_indicator` as otherwise Demuxer
    # discards all the input data
    # TODO - figure out how to do it properly
    demuxer = %{demuxer | waiting_random_access_indicator: false}

    %__MODULE__{demuxer: demuxer, last_tden_tag: nil}
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    demuxing_engine
    |> Map.update!(:demuxer, &Demuxer.push_buffer(&1, binary))
  end

  @impl true
  def get_tracks_info(%__MODULE__{} = demuxing_engine) do
    with %{streams: streams} <- demuxing_engine.demuxer.pmt do
      tracks_info =
        streams
        |> Enum.flat_map(fn
          {id, %{stream_type: :AAC}} ->
            [{id, %RemoteStream{content_format: AAC}}]

          {id, %{stream_type: :H264}} ->
            [{id, %RemoteStream{content_format: H264}}]

          {id, unsupported_stream_info} ->
            known_unsupported_streams = Process.get(:known_unsupported_streams) || MapSet.new()

            if not MapSet.member?(known_unsupported_streams, id) do
              Logger.debug("""
              #{__MODULE__ |> inspect()}: dropping unsupported stream with id #{id |> inspect()}.\
              Stream info: #{unsupported_stream_info |> inspect(pretty: true)}
              """)

              known_unsupported_streams = known_unsupported_streams |> MapSet.put(id)
              Process.put(:known_unsupported_streams, known_unsupported_streams)
            end

            []
        end)
        |> Map.new()

      {:ok, tracks_info}
    else
      nil -> {:error, :tracks_info_not_available}
    end
  end

  @impl true
  def pop_chunk(%__MODULE__{} = demuxing_engine, track_id) do
    with {[packet], demuxer} <- Demuxer.take(demuxing_engine.demuxer, track_id) do
      {maybe_tden_tag, demuxer} = maybe_read_tden_tag(demuxer, packet.pts)
      tden_tag = maybe_tden_tag || demuxing_engine.last_tden_tag

      {demuxing_engine, packet} =
        %{demuxing_engine | demuxer: demuxer, last_tden_tag: tden_tag}
        |> handle_possible_timestamps_rollover(track_id, packet)

      chunk = %ExHLS.Chunk{
        payload: packet.data,
        pts_ms: packet.pts |> packet_ts_to_millis(),
        dts_ms: packet.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.discontinuity,
          is_aligned: packet.is_aligned,
          tden_tag: tden_tag
        }
      }

      {:ok, chunk, demuxing_engine}
    else
      {[], demuxer} ->
        {:error, :empty_track_data, %{demuxing_engine | demuxer: demuxer}}
    end
  end

  defp maybe_read_tden_tag(demuxer, packet_pts) do
    withl no_id3_stream:
            {id3_track_id, _stream_description} <-
              demuxer.pmt.streams
              |> Enum.find(fn {_pid, stream_description} ->
                stream_description.stream_type == :METADATA_IN_PES
              end),
          no_id3_data: {[id3], demuxer} <- Demuxer.take(demuxer, id3_track_id),
          id3_not_in_timerange: true <- id3.pts <= packet_pts do
      {parse_tden_tag(id3.data), demuxer}
    else
      no_id3_stream: nil -> {nil, demuxer}
      no_id3_data: {[], updated_demuxer} -> {nil, updated_demuxer}
      id3_not_in_timerange: false -> {nil, demuxer}
    end
  end

  defp parse_tden_tag(payload) do
    # UTF-8 encoding
    encoding = 3

    with {pos, _len} <- :binary.match(payload, "TDEN"),
         <<_skip::binary-size(pos), "TDEN", tden::binary>> <- payload,
         <<size::integer-size(4)-unit(8), _flags::16, ^encoding::8, text::binary-size(size - 2),
           0, _rest::binary>> <- tden do
      text
    else
      _error -> nil
    end
  end

  # value returned by Demuxer is represented in nanoseconds
  defp packet_ts_to_millis(ts), do: div(ts, 1_000_000)

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    demuxer = Demuxer.end_of_stream(demuxing_engine.demuxer)
    %{demuxing_engine | demuxer: demuxer}
  end

  defp handle_possible_timestamps_rollover(%__MODULE__{} = demuxing_engine, track_id, packet) do
    demuxing_engine = demuxing_engine |> maybe_init_track_timestamp_data(track_id)

    %{rollovers_count: rollovers_count, last_pts: last_pts, last_dts: last_dts} =
      demuxing_engine.track_timestamps_data[track_id]

    rollovers_offset = rollovers_count * @timestamp_range_size_ns

    packet =
      packet
      |> Map.update!(:pts, &add_offset_if_not_nil(&1, rollovers_offset))
      |> Map.update!(:dts, &add_offset_if_not_nil(&1, rollovers_offset))

    {demuxing_engine, packet} =
      with last_ts when last_ts != nil <- last_dts || last_pts,
           true <- last_ts > (packet.dts || packet.pts) do
        demuxing_engine =
          demuxing_engine
          |> update_in([:track_timestamps_data, track_id, :rollovers_count], &(&1 + 1))

        packet =
          packet
          |> Map.update!(:pts, &add_offset_if_not_nil(&1, @timestamp_range_size_ns))
          |> Map.update!(:dts, &add_offset_if_not_nil(&1, @timestamp_range_size_ns))

        {demuxing_engine, packet}
      else
        _other -> {demuxing_engine, packet}
      end

    demuxing_engine =
      demuxing_engine
      |> put_in([:track_timestamps_data, track_id, :last_pts], packet.pts)
      |> put_in([:track_timestamps_data, track_id, :last_dts], packet.dts)

    {demuxing_engine, packet}
  end

  defp add_offset_if_not_nil(nil, _offset), do: nil
  defp add_offset_if_not_nil(value, offset), do: value + offset

  defp maybe_init_track_timestamp_data(%__MODULE__{} = demuxing_engine, track_id) do
    demuxing_engine
    |> Map.update!(
      :track_timestamps_data,
      &Map.put_new_lazy(&1, track_id, fn -> default_track_timestamp_data() end)
    )
  end

  defp default_track_timestamp_data() do
    %{
      rollovers_count: 0,
      last_pts: nil,
      last_dts: nil
    }
  end
end
