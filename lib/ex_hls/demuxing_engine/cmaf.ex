defmodule ExHLS.DemuxingEngine.CMAF do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  alias Membrane.MP4.Demuxer.CMAF

  @enforce_keys [:demuxer, :timestamp_offset_ms]
  defstruct @enforce_keys ++ [tracks_to_chunks: %{}, last_tden_tag: nil]

  @type t :: %__MODULE__{
          demuxer: CMAF.Engine.t(),
          tracks_to_chunks: map(),
          last_tden_tag: String.t() | nil
        }

  @impl true
  def new(timestamp_offset_ms) do
    %__MODULE__{
      demuxer: CMAF.Engine.new(),
      timestamp_offset_ms: timestamp_offset_ms
    }
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    {:ok, samples, demuxer} =
      demuxing_engine.demuxer
      |> CMAF.Engine.feed!(binary)
      |> CMAF.Engine.pop_samples()

    {tracks_to_chunks, last_tden_tag} =
      Enum.reduce(
        samples,
        {demuxing_engine.tracks_to_chunks, demuxing_engine.last_tden_tag},
        fn %Membrane.MP4.Demuxer.Sample{} = sample, {tracks_to_chunks, last_tden_tag} ->
          last_tden_tag =
            case sample.metadata do
              %{emsg_message_data: data} ->
                ExHLS.DemuxingEngine.ID3.parse_tden_tag(data) || last_tden_tag

              _no_emsg ->
                last_tden_tag
            end

          chunk = %ExHLS.Chunk{
            payload: sample.payload,
            pts_ms: (sample.pts + demuxing_engine.timestamp_offset_ms) |> round(),
            dts_ms: (sample.dts + demuxing_engine.timestamp_offset_ms) |> round(),
            track_id: sample.track_id,
            metadata: %{tden_tag: last_tden_tag}
          }

          tracks_to_chunks =
            tracks_to_chunks
            |> Map.put_new_lazy(sample.track_id, &Qex.new/0)
            |> Map.update!(sample.track_id, &Qex.push(&1, chunk))

          {tracks_to_chunks, last_tden_tag}
        end
      )

    %__MODULE__{
      demuxing_engine
      | demuxer: demuxer,
        tracks_to_chunks: tracks_to_chunks,
        last_tden_tag: last_tden_tag
    }
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
      {:ok, chunk, demuxing_engine}
    else
      _other -> {:error, :empty_track_data, demuxing_engine}
    end
  end

  @impl true
  def end_stream(demuxing_engine), do: demuxing_engine
end
