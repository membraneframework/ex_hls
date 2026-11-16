defmodule ExHLS.DemuxingEngine.MPEGTS.Test do
  use ExUnit.Case, async: false

  alias ExHLS.DemuxingEngine.MPEGTS
  alias MPEG.TS.Demuxer

  test "handling timestamp rollovers" do
    timestamp_range = (2 ** 33 * 1_000_000_000) |> div(90_000)
    timestamp_granularity = div(timestamp_range, 33) - 5

    packets =
      1..200
      |> Enum.map(fn i ->
        og_timestamp = i * timestamp_granularity
        rolled_timestamp = og_timestamp |> rem(timestamp_range)

        %{
          og_timestamp: og_timestamp,
          payload: %{
            pts: rolled_timestamp,
            dts: rolled_timestamp,
            data: <<>>,
            discontinuity: false,
            is_aligned: true
          }
        }
      end)

    entries = Enum.map(packets, &{&1, 0})
    demuxing_engine = ExHLS.DemuxingEngine.MPEGTS.new(0)

    demuxing_engine = %{
      demuxing_engine
      | packets_map: %{1 => Qex.new(entries), 2 => Qex.new(entries)}
    }

    [1, 2]
    |> Enum.reduce(demuxing_engine, fn track_id, demuxing_engine ->
      {chunks, demuxing_engine} =
        1..200
        |> Enum.map_reduce(demuxing_engine, fn _i, demuxing_engine ->
          {:ok, chunk, demuxing_engine} =
            ExHLS.DemuxingEngine.MPEGTS.pop_chunk(demuxing_engine, track_id)

          {chunk, demuxing_engine}
        end)

      Enum.zip(chunks, packets)
      |> Enum.each(fn {chunk, packet} ->
        assert chunk.pts_ms == div(packet.og_timestamp, 1_000_000)
        assert chunk.dts_ms == div(packet.og_timestamp, 1_000_000)
      end)

      demuxing_engine
    end)
  end

  test "chunks carry the sequence number of the segment their PES started in" do
    segment_paths =
      Path.wildcard("test/fixtures/mpeg_ts_with_tden/output_playlist*.ts") |> Enum.sort()

    segments = Enum.zip(segment_paths, 5..10)

    demuxing_engine =
      Enum.reduce(segments, MPEGTS.new(0), fn {path, segment_sequence_number}, engine ->
        MPEGTS.feed!(engine, File.read!(path), segment_sequence_number)
      end)

    expected =
      Map.new(
        for {path, segment_sequence_number} <- segments,
            {packets, demuxer} = Demuxer.demux(Demuxer.new(), File.read!(path)),
            {flushed_packets, _demuxer} = Demuxer.flush(demuxer),
            %{pid: pid, payload: %MPEG.TS.PES{pts: pts}} <- packets ++ flushed_packets,
            do: {{pid, div(pts, 1_000_000)}, segment_sequence_number}
      )

    {:ok, tracks_info} = MPEGTS.get_tracks_info(demuxing_engine)
    chunks = Enum.flat_map(Map.keys(tracks_info), &pop_all_chunks(demuxing_engine, &1))

    assert length(chunks) > length(segments)

    for chunk <- chunks do
      assert chunk.metadata.hls_segment_number ==
               Map.fetch!(expected, {chunk.track_id, chunk.pts_ms})
    end
  end

  defp pop_all_chunks(demuxing_engine, track_id) do
    case MPEGTS.pop_chunk(demuxing_engine, track_id) do
      {:ok, chunk, demuxing_engine} -> [chunk | pop_all_chunks(demuxing_engine, track_id)]
      {:error, :empty_track_data, _demuxing_engine} -> []
    end
  end
end
