defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc false
  @behaviour ExHLS.DemuxingEngine

  require Logger

  alias ExHLS.Parsers
  alias Membrane.{AAC, H264, RemoteStream}
  alias MPEG.TS.Demuxer

  @enforce_keys [:demuxer]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          demuxer: Demuxer.t(),
          audio: %{track_id: any(), parser: Parsers.AAC.t(), qex: Qex.t()},
          video: %{track_id: any(), parser: Parsers.H264.t(), qex: Qex.t()}
        }

  @impl true
  def new() do
    demuxer = Demuxer.new()

    # we need to explicitly override that `waiting_random_access_indicator` as otherwise Demuxer
    # discards all the input data
    # TODO - figure out how to do it properly
    demuxer = %{demuxer | waiting_random_access_indicator: false}

    %__MODULE__{
      demuxer: demuxer,
      audio: %{
        track_id: nil,
        parser: Parsers.AAC.new(),
        qex: Qex.new()
      },
      video: %{
        track_id: nil,
        parser: Parsers.H264.new(),
        qex: Qex.new()
      }
    }
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
            [{id, Parsers.AAC.get_stream_format()}]

          {id, %{stream_type: :H264}} ->
            [{id, Parsers.H264.get_stream_format()}]

          {id, unsupported_stream_info} ->
            Logger.warning("""
            #{__MODULE__ |> inspect()}: dropping unsupported stream with id #{id |> inspect()}.\
            Stream info: #{unsupported_stream_info |> inspect(pretty: true)}
            """)

            []
        end)
        |> Map.new()

      {:ok, tracks_info}
    else
      nil -> {:error, :tracks_info_not_available}
    end
  end

  defguardp is_known_track_id(track_id, demuxing_engine)
            when track_id in [demuxing_engine.audio.track_id, demuxing_engine.video.track_id]

  @impl true
  def pop_sample(%__MODULE__{} = demuxing_engine, track_id) do
    state = maybe_resolve_tracks_ids(track_id, demuxing_engine)

    with {[packet], demuxer} <- Demuxer.take(demuxing_engine.demuxer, track_id) do
      sample = %ExHLS.Sample{
        payload: packet.data,
        pts_ms: packet.pts |> packet_ts_to_millis(),
        dts_ms: packet.dts |> packet_ts_to_millis(),
        track_id: track_id,
        metadata: %{
          discontinuity: packet.discontinuity,
          is_aligned: packet.is_aligned
        }
      }

      {:ok, sample, %{demuxing_engine | demuxer: demuxer}}
    else
      {[], demuxer} ->
        {:error, :empty_track_data, %{demuxing_engine | demuxer: demuxer}}
    end
  end

  defp do_pop_sample(demuxing_engine, track_id, data_type) do
    case demuxing_engine[data_type].qex |> Qex.pop!() do
      {{:value, frame}, qex} ->
        demuxing_engine = demuxing_engine |> put_in([data_type, :qex], qex)
        {:ok, frame, demuxing_engine}

      {:empty, _qex} ->
        demuxing_engine
        |> take_from_demuxer_and_push_on_qex(track_id, data_type)
        |> do_pop_sample(track_id, data_type)
    end
  end

  defp take_parse_and_push_on_qex(demuxing_engine, track_id, data_type) do
    with {[packet], demuxer} <- Demuxer.take(demuxing_engine.demuxer, track_id) do
    end
  end

  defp maybe_resolve_tracks_ids(track_id, demuxing_engine) do
    with false <- is_known_track_id(track_id, demuxing_engine),
         {:ok, tracks_info} <- get_tracks_info(demuxing_engine) do
      tracks_info
      |> Enum.reduce(state, fn
        {id, %Membrane.AAC{}}, state ->
          state |> put_in([:audio, :track_id], id)

        {id, %Membrane.H264{}}, state ->
          state |> put_in([:video, :track_id], id)
      end)
    else
      _other -> state
    end
  end

  defp track_data_type(track_id, demuxing_engine) do
    case track_id do
      ^demuxing_engine.audio.track_id -> :audio
      ^demuxing_engine.video.track_id -> :video
    end
  end

  @mpegts_clock_rate 90
  defp packet_ts_to_millis(ts), do: div(ts, @mpegts_clock_rate)

  @impl true
  def end_stream(%__MODULE__{} = demuxing_engine) do
    demuxer = Demuxer.end_of_stream(demuxing_engine.demuxer)
    %{demuxing_engine | demuxer: demuxer}
  end
end
