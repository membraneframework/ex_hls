defmodule ExHLS.DemuxingEngine.CMAF do
  @moduledoc """
  todo: here
  """

  alias Membrane.MP4.Demuxer.CMAF

  @behaviour ExHLS.DemuxingEngine

  @impl true
  defdelegate new(), to: CMAF.Engine

  @impl true
  defdelegate feed!(demuxer, binary), to: CMAF.Engine

  @impl true
  defdelegate get_tracks_info(demuxer), to: CMAF.Engine

  @impl true
  def pop_frames(demuxer) do
    {:ok, cmaf_samples, demuxer} = CMAF.Engine.pop_samples(demuxer)

    frames =
      cmaf_samples
      |> Enum.map(fn %CMAF.Engine.Sample{} = sample ->
        %ExHLS.Frame{
          payload: sample.payload,
          pts: sample.pts,
          dts: sample.dts,
          track_id: sample.track_id
        }
      end)

    {:ok, frames, demuxer}
  end

  @impl true
  def end_stream(demuxer), do: {:ok, demuxer}
end
