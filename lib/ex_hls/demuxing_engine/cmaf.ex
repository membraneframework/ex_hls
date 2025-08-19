defmodule ExHLS.DemuxingEngine.CMAF do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  alias Membrane.MP4.Demuxer.CMAF
  alias Membrane.MP4.Demuxer.Sample

  @enforce_keys [:demuxer, :timestamps_offset_ms]
  defstruct @enforce_keys ++ [tracks_to_chunks: %{}]

  @type t :: %__MODULE__{
          demuxer: CMAF.Engine.t(),
          tracks_to_chunks: map(),
          timestamps_offset_ms: non_neg_integer()
        }

  @impl true
  def new(timestamps_offset_ms) do
    %__MODULE__{
      demuxer: CMAF.Engine.new(),
      timestamps_offset_ms: timestamps_offset_ms
    }
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    {:ok, chunks, demuxer} =
      demuxing_engine.demuxer
      |> CMAF.Engine.feed!(binary)
      |> CMAF.Engine.pop_samples()

    new_tracks_to_chunks =
      chunks
      |> Enum.group_by(
        fn chunk -> chunk.track_id end,
        fn %Sample{} = chunk ->
          %ExHLS.Chunk{
            payload: chunk.payload,
            pts_ms: chunk.pts,
            dts_ms: chunk.dts,
            track_id: chunk.track_id
          }
        end
      )

    tracks_to_chunks =
      new_tracks_to_chunks
      |> Enum.reduce(
        demuxing_engine.tracks_to_chunks,
        fn {track_id, new_chunks}, tracks_to_chunks ->
          tracks_to_chunks
          |> Map.put_new_lazy(track_id, &Qex.new/0)
          |> Map.update!(track_id, fn track_qex ->
            new_chunks |> Enum.reduce(track_qex, &Qex.push(&2, &1))
          end)
        end
      )

    %__MODULE__{demuxing_engine | demuxer: demuxer, tracks_to_chunks: tracks_to_chunks}
  end

  @impl true
  def get_tracks_info(demuxing_engine) do
    CMAF.Engine.get_tracks_info(demuxing_engine.demuxer)
  end

  @impl true
  def pop_chunk(demuxing_engine, track_id) do
    with qex when qex != nil <- demuxing_engine.tracks_to_chunks[track_id],
         {{:value, chunk}, popped_qex} <- Qex.pop(qex) do
      demuxing_engine = put_in(demuxing_engine.tracks_to_chunks[track_id], popped_qex)
      chunk = normalize_timestamps(chunk, demuxing_engine.timestamps_offset_ms)
      {:ok, chunk, demuxing_engine}
    else
      nil -> {:error, :unknown_track, demuxing_engine}
      {:empty, _qex} -> {:error, :empty_track_data, demuxing_engine}
    end
  end

  @impl true
  def end_stream(demuxing_engine), do: demuxing_engine

  defp normalize_timestamps(chunk, timestamps_offset_ms) do
    %{
      chunk
      | pts_ms: round(chunk.pts_ms + timestamps_offset_ms),
        dts_ms: round(chunk.dts_ms + timestamps_offset_ms)
    }
  end
end
