defmodule ExHLS.DemuxingEngine.CMAF.Test do
  use ExUnit.Case, async: true

  test "reads TDEN tag from emsg box embedded in ID3 message data" do
    fixture = File.read!("test/fixtures/cmaf_with_emsg/fixture.mp4")

    engine = ExHLS.DemuxingEngine.CMAF.new(0)
    engine = ExHLS.DemuxingEngine.CMAF.feed!(engine, fixture)

    {:ok, tracks_info} = ExHLS.DemuxingEngine.CMAF.get_tracks_info(engine)
    track_ids = Map.keys(tracks_info)

    chunks =
      Enum.flat_map(track_ids, fn track_id ->
        Stream.unfold(engine, fn engine ->
          case ExHLS.DemuxingEngine.CMAF.pop_chunk(engine, track_id) do
            {:ok, chunk, engine} -> {chunk, engine}
            {:error, :empty_track_data, _engine} -> nil
          end
        end)
        |> Enum.to_list()
      end)

    assert chunks != []

    assert Enum.all?(chunks, fn chunk ->
             chunk.metadata.tden_tag == "2026-05-20T14:33:58"
           end)
  end
end
