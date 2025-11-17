defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  use Bunch.Access
  use Bunch

  require Logger
  alias Membrane.{AAC, H264, RemoteStream}
  alias MPEG.TS.Demuxer

  @enforce_keys [:demuxer, :last_tden_tag, :packets]
  defstruct @enforce_keys ++ [track_timestamps_data: %{}]

  # using it a boundary expressed in nanoseconds, instead of the usual 90kHz clock ticks,
  # generates up to 1/10th of ms error per 26.5 hours of stream which is acceptable in
  # this context
  @timestamp_range_size_ns div(2 ** 33 * 1_000_000_000, 90_000)

  @type t :: %__MODULE__{
          demuxer: Demuxer.t(),
          last_tden_tag: String.t() | nil,
          packets: %{non_neg_integer() => MPEG.TS.Demuxer.Container.t()}
        }

  @impl true
  # timestamp_offset_ms is not used in MPEG-TS demuxing as MPEG-TS packets already contain
  # proper timestamps however we keep this argument to keep the interface consistent between
  # different demuxing engines
  def new(_timestamp_offset_ms) do
    demuxer = Demuxer.new()
    %__MODULE__{demuxer: demuxer, last_tden_tag: nil, packets: %{}}
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    {new_packets, demuxer} = Demuxer.demux(demuxing_engine.demuxer, binary)

    all_packets =
      Enum.reduce(new_packets, demuxing_engine.packets, fn new_packet, all_packets ->
        packets_for_pid = Map.get(all_packets, new_packet.pid, []) ++ [new_packet]
        put_in(all_packets[new_packet.pid], packets_for_pid)
      end)

    %{demuxing_engine | demuxer: demuxer, packets: all_packets}
  end

  @impl true
  def get_tracks_info(%__MODULE__{} = demuxing_engine) do
    with %{streams: streams} <- demuxing_engine.demuxer do
      tracks_info =
        streams
        |> Enum.flat_map(fn
          {id, %{stream_type: :AAC_ADTS}} ->
            [{id, %RemoteStream{content_format: AAC}}]

          {id, %{stream_type: :H264_AVC}} ->
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

  defp take_packets(demuxing_engine, track_id) do
    case Map.get(demuxing_engine.packets, track_id) do
      [packet | rest] ->
        demuxing_engine = put_in(demuxing_engine.packets[track_id], rest)
        {[packet], demuxing_engine}

      _other ->
        {[], demuxing_engine}
    end
  end

  @impl true
  def pop_chunk(%__MODULE__{} = demuxing_engine, track_id) do
    with {[packet], demuxing_engine} <- take_packets(demuxing_engine, track_id) do
      {maybe_tden_tag, demuxing_engine} = maybe_read_tden_tag(demuxing_engine, packet.payload.pts)
      tden_tag = maybe_tden_tag || demuxing_engine.last_tden_tag

      {demuxing_engine, packet} =
        %{demuxing_engine | last_tden_tag: tden_tag}
        |> handle_possible_timestamps_rollover(track_id, packet)

      chunk = %ExHLS.Chunk{
        payload: packet.payload.data,
        pts_ms: packet.payload.pts |> packet_ts_to_millis(),
        dts_ms: packet.payload.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.payload.discontinuity,
          is_aligned: packet.payload.is_aligned,
          tden_tag: tden_tag
        }
      }

      {:ok, chunk, demuxing_engine}
    else
      {[], demuxing_engine} ->
        {:error, :empty_track_data, demuxing_engine}
    end
  end

  defp maybe_read_tden_tag(demuxing_engine, packet_pts) do
    withl no_id3_stream:
            {id3_track_id, _stream_description} <-
              demuxing_engine.demuxer.streams
              |> Enum.find(fn {_pid, stream_description} ->
                stream_description.stream_type == :METADATA_IN_PES
              end),
          # Demuxer.take(demuxer, id3_track_id),
          no_id3_data: {[id3], demuxing_engine} <- nil,
          id3_not_in_timerange: true <- id3.pts <= packet_pts do
      {parse_tden_tag(id3.data), demuxing_engine}
    else
      no_id3_stream: nil -> {nil, demuxing_engine}
      no_id3_data: {[], updated_demuxing_engine} -> {nil, updated_demuxing_engine}
      id3_not_in_timerange: false -> {nil, demuxing_engine}
    end
  end

  defp parse_tden_tag(payload) do
    # UTF-8 encoding
    encoding = 3

    with {pos, _len} <- :binary.match(payload, "TDEN"),
         <<_skip::binary-size(pos), "TDEN", tden::binary>> <- payload,
         <<size::integer-size(4)-unit(8), _flags::16, ^encoding::8, text::binary-size(size - 2),
           0::8, _rest::binary>> <- tden do
      text
    else
      _error -> nil
    end
  end

  # value returned by Demuxer is represented in nanoseconds
  defp packet_ts_to_millis(ts), do: div(ts, 1_000_000)

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    {_flushed, demuxer} = Demuxer.flush(demuxing_engine.demuxer)
    %{demuxing_engine | demuxer: demuxer}
  end

  defp handle_possible_timestamps_rollover(%__MODULE__{} = demuxing_engine, track_id, packet) do
    demuxing_engine = demuxing_engine |> maybe_init_track_timestamp_data(track_id)

    %{rollovers_count: rollovers_count, last_pts: last_pts, last_dts: last_dts} =
      demuxing_engine.track_timestamps_data[track_id]

    rollovers_offset = rollovers_count * @timestamp_range_size_ns

    payload =
      packet.payload
      |> Map.update!(:pts, &add_offset_if_not_nil(&1, rollovers_offset))
      |> Map.update!(:dts, &add_offset_if_not_nil(&1, rollovers_offset))

    {demuxing_engine, payload} =
      with last_ts when last_ts != nil <- last_dts || last_pts,
           true <- last_ts > (payload.dts || payload.pts) do
        demuxing_engine =
          demuxing_engine
          |> update_in([:track_timestamps_data, track_id, :rollovers_count], &(&1 + 1))

        payload =
          payload
          |> Map.update!(:pts, &add_offset_if_not_nil(&1, @timestamp_range_size_ns))
          |> Map.update!(:dts, &add_offset_if_not_nil(&1, @timestamp_range_size_ns))

        {demuxing_engine, payload}
      else
        _other -> {demuxing_engine, payload}
      end

    demuxing_engine =
      demuxing_engine
      |> put_in([:track_timestamps_data, track_id, :last_pts], payload.pts)
      |> put_in([:track_timestamps_data, track_id, :last_dts], payload.dts)

    packet = %{packet | payload: payload}

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
