defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  use Bunch.Access

  require Logger
  alias Membrane.{AAC, H264, RemoteStream}
  alias MPEG.TS.Demuxer

  @enforce_keys [:demuxer]
  defstruct @enforce_keys ++
              [last_packet_ts: %{pts: nil, dts: nil}, ts_rollovers_count: 0]

  # @timestamp_range_size is 2^33
  @timestamp_range_size 8_589_934_592

  @type t :: %__MODULE__{
          demuxer: Demuxer.t()
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

    %__MODULE__{demuxer: demuxer}
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
      {demuxing_engine, packet} =
        %{demuxing_engine | demuxer: demuxer}
        |> handle_possible_timestamps_rollover(packet)

      chunk = %ExHLS.Chunk{
        payload: packet.data,
        pts_ms: packet.pts |> packet_ts_to_millis(),
        dts_ms: packet.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.discontinuity,
          is_aligned: packet.is_aligned
        }
      }

      {:ok, chunk, demuxing_engine}
    else
      {[], demuxer} ->
        {:error, :empty_track_data, %{demuxing_engine | demuxer: demuxer}}
    end
  end

  # value returned by Demuxer is represented in nanoseconds
  defp packet_ts_to_millis(ts), do: div(ts, 1_000_000)

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    demuxer = Demuxer.end_of_stream(demuxing_engine.demuxer)
    %{demuxing_engine | demuxer: demuxer}
  end

  defp handle_possible_timestamps_rollover(%__MODULE__{} = demuxing_engine, packet) do
    last_ts = state.last_packet_ts.dts || state.last_packet_ts.pts
    rollovers_offset = demuxing_engine.ts_rollovers_count * @timestamp_range_size

    packet =
      packet
      |> Map.update!(:pts, &add_offset_if_not_nil(&1, rollovers_offset))
      |> Map.update!(:dts, &add_offset_if_not_nil(&1, rollovers_offset))

    {demuxing_engine, packet} =
      if last_ts != nil and last_ts > (packet.dts || packet.pts) do
        demuxing_engine = demuxing_engine |> Map.update!(:ts_rollovers_count, &(&1 + 1))

        packet =
          packet
          |> Map.update!(:pts, &add_offset_if_not_nil(&1, @timestamp_range_size))
          |> Map.update!(:dts, &add_offset_if_not_nil(&1, @timestamp_range_size))

        {demuxing_engine, packet}
      else
        {demuxing_engine, packet}
      end

    demuxing_engine =
      demuxing_engine
      |> put_in([:last_packet_ts, :pts], packet.pts)
      |> put_in([:last_packet_ts, :dts], packet.dts)

    {demuxing_engine, packet}
  end

  defp add_offset_if_not_nil(nil, _offset), do: nil
  defp add_offset_if_not_nil(value, offset), do: value + offset
end
