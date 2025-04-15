defmodule Client.Test do
  use ExUnit.Case, async: true

  test "if client reads the first video frame of the HLS stream" do
    alias ExHLS.Client
    url = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    {:ok, client} = Client.start(url)
    Client.read_variants(client)
    Client.choose_variant(client, "720")
    pes = Client.read_video_frame(client)
    assert pes.pts == 10033
    assert pes.dts == 10000
    assert byte_size(pes.data) == 1048

    assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 128, 80, 5, 187, 1, 16, 0,
             0, 3, 0, 16, 0, 0, 7, 128, 241, 131, 25, 160, 0, 0, 0, 1>> <> _rest = pes.data
  end
end
