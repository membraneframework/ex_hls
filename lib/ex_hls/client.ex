defmodule ExHLS.Client do
  @moduledoc "HLS Client"

  use GenServer

  alias MPEG.TS.Demuxer

  @type state :: map()
  @type frame :: any()
  @opaque client :: pid()

  @h264_time_base 90_000

  def start(url) do
    GenServer.start(__MODULE__, url: url)
  end

  @impl true
  def init(url: url) do
    playlist_content = Req.get!(url).body

    state = %{
      multivariant_playlist: ExM3U8.deserialize_multivariant_playlist!(playlist_content, []),
      base_url: Path.dirname(url),
      audio_frames: [],
      video_frames: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:read_variants, _from, state) do
    variants =
      state.multivariant_playlist.items
      |> Enum.map(fn variant -> {variant.name, variant_description(variant)} end)
      |> Map.new()

    {:reply, variants, state}
  end

  @impl true
  def handle_call({:choose_variant, variant_name}, _from, state) do
    chosen_variant =
      Enum.find(state.multivariant_playlist.items, fn variant -> variant.name == variant_name end)

    media_playlist = Path.join(state.base_url, chosen_variant.uri) |> Req.get!()

    state =
      Map.put(state, :media_playlist, ExM3U8.deserialize_media_playlist!(media_playlist.body, []))

    media_base_url = Path.join(state.base_url, Path.dirname(chosen_variant.uri))
    state = Map.put(state, :media_base_url, media_base_url)

    demuxer = Demuxer.new()
    # we need to explicitly override that `waiting_random_access_indicator` as otherwise Demuxer
    # discards all the input data
    # TODO - figure out how to do it properly
    demuxer = %{demuxer | waiting_random_access_indicator: false}
    state = Map.put(state, :demuxer, demuxer)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:read_video_frame, _from, state) do
    {result, state} = do_read_frame(state, :video)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:read_audio_frame, _from, state) do
    {result, state} = do_read_frame(state, :audio)
    {:reply, result, state}
  end

  @spec read_variants(client()) :: map()
  def read_variants(pid) do
    GenServer.call(pid, :read_variants)
  end

  @spec choose_variant(client(), String.t()) :: :ok
  def choose_variant(pid, variant_name) do
    GenServer.call(pid, {:choose_variant, variant_name})
  end

  def read_video_frame(pid) do
    GenServer.call(pid, :read_video_frame)
  end

  def read_audio_frame(pid) do
    GenServer.call(pid, :read_audio_frame)
  end

  @spec do_read_frame(state(), :audio | :video) :: {frame() | :end_of_stream, state()}
  defp do_read_frame(state, track) do
    stream_ids = resolve_stream_ids(state.demuxer)

    case Demuxer.take(state.demuxer, stream_ids[:video]) do
      {[], demuxer} ->
        case put_in(state.demuxer, demuxer) |> download_chunk() do
          {:ok, state} -> do_read_frame(state, track)
          {:end_of_stream, state} -> {:end_of_stream, state}
        end

      {[pes], demuxer} ->
        state = put_in(state.demuxer, demuxer)
        frame = %ExHLS.Frame{payload: pes.data, pts: convert_h264_ts(pes.pts), dts: convert_h264_ts(pes.dts),
          discontinuity: pes.discontinuity, is_aligned: pes.is_aligned}
        {frame, state}
    end
  end

  defp variant_description(variant) do
    %{
      framerate: variant.frame_rate,
      resolution: variant.resolution,
      codecs: variant.codecs,
      bandwidth: variant.bandwidth
    }
  end

  defp download_chunk(state) do
    case List.pop_at(state.media_playlist.timeline, 0) do
      {nil, []} ->
        state = put_in(state.demuxer, Demuxer.end_of_stream(state.demuxer))
        {:end_of_stream, state}

      {segment_info, rest} ->
        state = put_in(state.media_playlist.timeline, rest)

        demuxer =
          Path.join(state.media_base_url, segment_info.uri)
          |> Req.get!()
          |> then(&Demuxer.push_buffer(state.demuxer, &1.body))

        state = put_in(state.demuxer, demuxer)
        {:ok, state}
    end
  end

  defp resolve_stream_ids(demuxer) do
    with {:ok, pmt} when pmt != nil <- Map.fetch(demuxer, :pmt),
         {:ok, streams} <- Map.fetch(pmt, :streams) do
      Enum.map(streams, fn
        {id, %{stream_type: :AAC}} ->
          {:audio, id}

        {id, %{stream_type: :H264}} ->
          {:video, id}
      end)
      |> Map.new()
    else
      _error ->
        %{}
    end
  end

  defp convert_h264_ts(nil), do: nil

  defp convert_h264_ts(ts) do
    (ts * ExHLS.Frame.time_base() / @h264_time_base)
    |> trunc()
  end
end
