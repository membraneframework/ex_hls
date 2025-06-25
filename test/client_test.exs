defmodule Client.Test do
  use ExUnit.Case, async: true

  alias ExHLS.Client

  @mpegts_url "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
  @fmp4_url "https://raw.githubusercontent.com/membraneframework-labs/ex_hls/refs/heads/plug-demuxing-engine-into-client/fixture/output.m3u8"

  describe "if client reads video and audio frames of the HLS" do
    @tag :a
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

    @tag :b
    test "(fMP4) stream" do
      {:ok, client} = Client.start(@fmp4_url, ExHLS.DemuxingEngine.CMAF)

      video_frame = Client.read_video_frame(client)

      assert %{pts: 0, dts: 0} = video_frame
      assert byte_size(video_frame.payload) == 775

      assert <<0, 0, 2, 171, 6, 5, 255, 255, 167, 220, 69, 233, 189, 230, 217, 72, 183, 150, 44,
               216, 32, 217, 35, 238, 239, 120, 50, 54, 52, 32, 45, 32, 99, 111, 114, 101, 32, 49,
               54, 52, 32, 114, 51, 49, 48, 56, 32, 51, 49, 101>> <> _rest = video_frame.payload

      first_audio_frame = Client.read_audio_frame(client)

      assert %{pts: 0, dts: 0} = first_audio_frame

      assert first_audio_frame.payload ==
               <<220, 0, 76, 97, 118, 99, 54, 49, 46, 51, 46, 49, 48, 48, 0, 66, 32, 8, 193, 24,
                 56>>

      second_audio_frame = Client.read_audio_frame(client)

      assert %{pts: 23, dts: 23} = second_audio_frame
      assert second_audio_frame.payload == <<33, 16, 4, 96, 140, 28>>
    end
  end
end
