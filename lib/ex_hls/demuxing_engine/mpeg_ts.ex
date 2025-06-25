defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false

  alias MPEG.TS.Demuxer

  @behaviour ExHLS.DemuxingEngine

  @enforce_keys [:demuxer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          demuxer: Demuxer.t()
        }

  @impl true
  def new() do
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
        |> Map.new(fn {id, %{stream_type: stream_type}} ->
          content_format =
            case stream_type do
              :AAC -> Membrane.AAC
              :H264 -> Membrane.H264
            end

          # todo: maybe change remote stream on exact stream format
          {id, %Membrane.RemoteStream{content_format: content_format}}
        end)

      {:ok, tracks_info}
    else
      nil -> {:error, :tracks_info_not_available}
    end
  end

  @impl true
  def pop_frame(%__MODULE__{} = demuxing_engine, track_id) do
    with {[packet], demuxer} <- Demuxer.take(demuxing_engine.demuxer, track_id) do
      frame = %ExHLS.Frame{
        payload: packet.data,
        pts: packet.pts |> packet_ts_to_millis(),
        dts: packet.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.discontinuity,
          is_aligned: packet.is_aligned
        }
      }

      {:ok, frame, %{demuxing_engine | demuxer: demuxer}}
    else
      {[], demuxer} ->
        {:error, :empty_track_data, %{demuxing_engine | demuxer: demuxer}}
    end
  end

  defp packet_ts_to_millis(ts), do: div(ts, 90)

  @impl true
  @spec end_stream(ExHLS.DemuxingEngine.MPEGTS.t()) :: {:ok, ExHLS.DemuxingEngine.MPEGTS.t()}
  def end_stream(%__MODULE__{} = demuxing_engine) do
    {:ok, %{demuxing_engine | demuxer: Demuxer.end_of_stream(demuxing_engine.demuxer)}}
  end
end
