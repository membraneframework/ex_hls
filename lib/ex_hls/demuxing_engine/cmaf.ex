defmodule ExHLS.DemuxingEngine.CMAF do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  alias Membrane.MP4.Demuxer.CMAF

  @enforce_keys [:demuxer]
  defstruct @enforce_keys ++ [tracks_to_samples: %{}]

  @type t :: %__MODULE__{
          demuxer: CMAF.Engine.t(),
          tracks_to_samples: map()
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

    new_tracks_to_samples =
      samples
      |> Enum.group_by(
        fn sample -> sample.track_id end,
        fn %CMAF.Engine.Sample{} = sample ->
          %ExHLS.Sample{
            payload: sample.payload,
            pts_ms: sample.pts,
            dts_ms: sample.dts,
            track_id: sample.track_id
          }
        end
      )

    tracks_to_samples =
      new_tracks_to_samples
      |> Enum.reduce(
        demuxing_engine.tracks_to_samples,
        fn {track_id, new_samples}, tracks_to_samples ->
          tracks_to_samples
          |> Map.put_new_lazy(track_id, &Qex.new/0)
          |> Map.update!(track_id, fn track_qex ->
            new_samples |> Enum.reduce(track_qex, &Qex.push(&2, &1))
          end)
        end
      )

    %__MODULE__{demuxing_engine | demuxer: demuxer, tracks_to_samples: tracks_to_samples}
  end

  @impl true
  def get_tracks_info(demuxing_engine) do
    CMAF.Engine.get_tracks_info(demuxing_engine.demuxer)
  end

  @impl true
  def pop_sample(demuxing_engine, track_id) do
    with qex when qex != nil <- demuxing_engine.tracks_to_samples[track_id],
         {{:value, sample}, popped_qex} <- Qex.pop(qex) do
      demuxing_engine = put_in(demuxing_engine.tracks_to_samples[track_id], popped_qex)
      {:ok, sample, demuxing_engine}
    else
      nil -> {:error, :unknown_track, demuxing_engine}
      {:empty, _qex} -> {:error, :empty_track_data, demuxing_engine}
    end
  end

  @impl true
  def end_stream(demuxing_engine), do: demuxing_engine
end
