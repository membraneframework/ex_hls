defmodule ExHLS.DemuxingEngine.CMAF do
  @moduledoc """
  todo: here
  """

  alias Membrane.MP4.Demuxer.CMAF

  @behaviour ExHLS.DemuxingEngine

  @enforce_keys [:demuxer]
  defstruct @enforce_keys ++ [tracks_to_frames: %{}]

  @type t :: %__MODULE__{
          demuxer: CMAF.Engine.t(),
          tracks_to_frames: map()
        }

  @impl true
  def new() do
    %__MODULE__{
      demuxer: CMAF.Engine.new()
    }
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    {:ok, samples, demuxer} =
      demuxing_engine.demuxer
      |> CMAF.Engine.feed!(binary)
      |> CMAF.Engine.pop_samples()

    new_tracks_to_frames =
      samples
      |> Enum.group_by(
        fn sample -> sample.track_id end,
        fn %CMAF.Engine.Sample{} = sample ->
          %ExHLS.Frame{
            payload: sample.payload,
            pts: sample.pts,
            dts: sample.dts,
            track_id: sample.track_id
          }
        end
      )

    tracks_to_frames =
      new_tracks_to_frames
      |> Enum.reduce(demuxing_engine.tracks_to_frames, fn {track_id, frames}, tracks_to_frames ->
        tracks_to_frames
        |> Map.put_new_lazy(track_id, &Qex.new/0)
        |> Map.update!(track_id, fn track_qex ->
          frames |> Enum.reduce(track_qex, &Qex.push(&2, &1))
        end)
      end)

    %__MODULE__{demuxing_engine | demuxer: demuxer, tracks_to_frames: tracks_to_frames}
  end

  @impl true
  @spec get_tracks_info(any()) ::
          {:error, :not_available_yet} | {:ok, %{optional(integer()) => struct()}}
  def get_tracks_info(demuxing_engine) do
    CMAF.Engine.get_tracks_info(demuxing_engine.demuxer)
  end

  @impl true
  def pop_frame(demuxing_engine, track_id) do
    case Qex.pop(demuxing_engine.tracks_to_frames[track_id]) do
      {{:value, frame}, track_qex} ->
        demuxing_engine = put_in(demuxing_engine.tracks_to_frames[track_id], track_qex)
        {:ok, frame, demuxing_engine}

      {:empty, _track_qex} ->
        {:error, :empty_track_data, demuxing_engine}
    end
  end

  @impl true
  def end_stream(demuxing_engine), do: {:ok, demuxing_engine}
end
