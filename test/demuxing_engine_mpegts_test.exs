defmodule ExHLS.DemuxingEngine.MPEGTS.Test do
  use ExUnit.Case, async: false
  import Mock

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
          pts: rolled_timestamp,
          dts: rolled_timestamp,
          data: <<>>,
          discontinuity: false,
          is_aligned: true
        }
      end)

    demuxer = %{
      waiting_random_access_indicator: nil,
      packet_buffers: %{1 => packets, 2 => packets}
    }

    new = fn -> demuxer end

    take = fn demuxer, track_id ->
      demuxer
      |> get_and_update_in(
        [:packet_buffers, track_id],
        fn [head | tail] -> {[head], tail} end
      )
    end

    with_mock Demuxer, new: new, take: take do
      demuxing_engine = ExHLS.DemuxingEngine.MPEGTS.new(0)

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
  end
end
