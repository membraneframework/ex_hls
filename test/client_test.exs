defmodule Client.Test do
  use ExUnit.Case, async: true

  alias ExHLS.Client

  @mpegts_url "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
  @fmp4_url "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"

  describe "if client reads first video and audio frames of the HLS" do
    test "(MPEGTS) stream" do
      {:ok, client} = Client.start(@mpegts_url, ExHLS.DemuxingEngine.MPEGTS)
      Client.read_variants(client)
      Client.choose_variant(client, "720")

      video_frame = Client.read_video_frame(client)

      assert video_frame.pts == 10033
      assert video_frame.dts == 10000
      assert byte_size(video_frame.payload) == 1048

      assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 128, 80, 5, 187, 1, 16,
               0, 0, 3, 0, 16, 0, 0, 7, 128, 241, 131, 25, 160, 0, 0, 0,
               1>> <> _rest = video_frame.payload

      audio_frame = Client.read_audio_frame(client)

      assert audio_frame.pts == 10010
      assert audio_frame.dts == 10010
      assert byte_size(audio_frame.payload) == 6154

      assert <<255, 241, 80, 128, 4, 63, 252, 222, 4, 0, 0, 108, 105, 98, 102, 97, 97, 99, 32, 49,
               46, 50, 56, 0, 0, 66, 64, 147, 32, 4, 50, 0, 71, 255, 241, 80, 128, 10, 255, 252,
               33, 70, 254, 208, 221, 101, 200, 21, 97, 0>> <> _rest = audio_frame.payload
    end

    test "(fMP4) stream" do
      {:ok, client} = Client.start(@fmp4_url, ExHLS.DemuxingEngine.CMAF)
      Client.read_variants(client)
      Client.choose_variant(client, "720")

      video_frame = Client.read_video_frame(client)
      video_frame |> dbg("video_frame")

      audio_frame = Client.read_audio_frame(client)
      audio_frame |> dbg("audio_frame")

      # assert video_frame.pts == 10033
      # assert video_frame.dts == 10000
      # assert byte_size(video_frame.payload) == 1048

      # assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 128, 80, 5, 187, 1, 16,
      #          0, 0, 3, 0, 16, 0, 0, 7, 128, 241, 131, 25, 160, 0, 0, 0,
      #          1>> <> _rest = video_frame.payload

      # audio_frame = Client.read_audio_frame(client)

      # assert audio_frame.pts == 10010
      # assert audio_frame.dts == 10010
      # assert byte_size(audio_frame.payload) == 6154

      # assert <<255, 241, 80, 128, 4, 63, 252, 222, 4, 0, 0, 108, 105, 98, 102, 97, 97, 99, 32, 49,
      #          46, 50, 56, 0, 0, 66, 64, 147, 32, 4, 50, 0, 71, 255, 241, 80, 128, 10, 255, 252,
      #          33, 70, 254, 208, 221, 101, 200, 21, 97, 0>> <> _rest = audio_frame.payload
    end
  end
end
