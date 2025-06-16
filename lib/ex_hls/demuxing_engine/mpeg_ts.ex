defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc """
  todo: here
  """

  alias MPEG.TS.Demuxer

  @behaviour ExHLS.DemuxingEngine

  @enforce_keys [:demuxer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          demuxer: Demuxer.t()
        }

  @impl true
  def new() do
    %__MODULE__{demuxer: Demuxer.new()}
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    demuxing_engine
    |> Map.update!(:demuxer, &Demuxer.push_buffer(&1, binary))
  end

  @impl true
  def get_tracks_info(%__MODULE__{} = demuxing_engine) do
    case demuxing_engine.demuxer.pmt do
      nil -> {:error, :tracks_info_not_available}
      pmt -> {:ok, pmt}
    end
  end

  @impl true
  def pop_frame(%__MODULE__{} = demuxing_engine, track_id) do
    case Demuxer.take(demuxing_engine.demuxer, track_id) do
      {[packet], demuxer} ->
        frame = %ExHLS.Frame{
          payload: packet.data,
          pts: packet.pts |> nanos_to_millis(),
          dts: packet.dts |> nanos_to_millis(),
          track_id: track_id,
          metadata: %{
            discontinuity: packet.discontinuity,
            is_aligned: packet.is_aligned
          }
        }

        {:ok, frame, %{demuxing_engine | demuxer: demuxer}}

      {[], _demuxer} ->
        {:error, :empty_track_data}
    end
  end

  defp nanos_to_millis(nanos) when is_integer(nanos) do
    div(nanos, 1_0000_000_000)
  end

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    {:ok, %{demuxing_engine | demuxer: Demuxer.end_of_stream(demuxing_engine.demuxer)}}
  end
end
