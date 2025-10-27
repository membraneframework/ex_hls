defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  require Logger
  alias Membrane.{AAC, H264, RemoteStream}
  alias MPEG.TS.Demuxer

  @enforce_keys [:demuxer, :last_tden]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          demuxer: Demuxer.t(),
          last_tden: String.t() | nil
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

    %__MODULE__{demuxer: demuxer, last_tden: nil}
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
    {id3_track_id, _stream_description} =
      demuxing_engine.demuxer.pmt.streams
      |> Enum.find(fn {_pid, stream_description} ->
        stream_description.stream_type ==
          :METADATA_IN_PES
      end)

    with {[packet], demuxer} <- Demuxer.take(demuxing_engine.demuxer, track_id) do
      {last_tden, demuxer} =
        case Demuxer.take(demuxer, id3_track_id) do
          {[], demuxer} ->
            {demuxing_engine.last_tden, demuxer}

          {[id3], new_demuxer} ->
            if id3.pts <= packet.pts do
              {parse_tden(id3.data), new_demuxer}
            else
              {nil, demuxer}
            end
        end

      chunk = %ExHLS.Chunk{
        payload: packet.data,
        pts_ms: packet.pts |> packet_ts_to_millis(),
        dts_ms: packet.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.discontinuity,
          is_aligned: packet.is_aligned,
          tden: last_tden
        }
      }

      {:ok, chunk, %{demuxing_engine | demuxer: demuxer, last_tden: last_tden}}
    else
      {[], demuxer} ->
        {:error, :empty_track_data, %{demuxing_engine | demuxer: demuxer}}
    end
  end

  defp parse_tden(payload) do
    case :binary.match(payload, "TDEN") do
      {pos, len} ->
        trailing_bytes = :binary.part(payload, pos + len, byte_size(payload) - (pos + len))
        <<size::integer-size(4)-unit(8), _flags::16, rest::binary>> = trailing_bytes
        <<_3, text::binary-size(size - 2), 0, _rest::binary>> = rest
        text

      :nomatch ->
        nil
    end
  end

  # value returned by Demuxer is represented in nanoseconds
  defp packet_ts_to_millis(ts), do: div(ts, 1_000_000)

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    demuxer = Demuxer.end_of_stream(demuxing_engine.demuxer)
    %{demuxing_engine | demuxer: demuxer}
  end
end
