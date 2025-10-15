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
        timestamp = (i * timestamp_granularity) |> div(timestamp_range)
        %{pts: timestamp, dts: timestamp, data: <<>>, discontinuity: false, is_aligned: true}
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
      engine = ExHLS.DemuxingEngine.MPEGTS.new(0)

      [1, 2]
      |> Enum.reduce(engine, fn track_id, engine ->
        {chunks, engine} =
          1..200
          |> Enum.map_reduce(engine, fn _i, engine ->
            {:ok, chunk, engine} = ExHLS.DemuxingEngine.MPEGTS.pop_chunk(engine, track_id)
            {chunk, engine}
          end)

        Enum.zip(chunks, packets)
        |> Enum.each(fn {chunk, packet} ->
          assert chunk.pts_ms == div(packet.pts, 1_000_000)
          assert chunk.dts_ms == div(packet.dts, 1_000_000)
        end)

        engine
      end)
    end
  end
end
