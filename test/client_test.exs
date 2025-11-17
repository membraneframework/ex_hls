defmodule ExHLS.Client.Test do
  use ExUnit.Case, async: true

  alias ExHLS.Client
  alias Membrane.{AAC, H264, RemoteStream}

  @fixtures "https://raw.githubusercontent.com/membraneframework/ex_hls/refs/heads/master/test/fixtures/"
  @fmp4_url @fixtures <> "fmp4/output.m3u8"
  @fmp4_only_video_url @fixtures <> "fmp4_only_video/output.m3u8"
  @mpegts_only_video_url @fixtures <> "mpeg_ts_only_video/output_playlist.m3u8"
  @mpegts_with_tden_url "test/fixtures/mpeg_ts_with_tden/output_playlist.m3u8"
  @mpegts_url "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
  @mpegts_live_url "./test/fixtures/mpeg_ts_live/output_playlist.m3u8"

  describe "if client reads video and audio chunks of the HLS" do
    test "(MPEGTS) stream" do
      client = Client.new(@mpegts_url)

      variant_720 =
        Client.get_variants(client)
        |> Map.values()
        |> Enum.find(&(&1.resolution == {1280, 720}))

      assert variant_720 != nil

      client = client |> Client.choose_variant(variant_720.id)
      {:ok, tracks_info, client} = Client.get_tracks_info(client)

      tracks_info = tracks_info |> Map.values()

      assert tracks_info |> length() == 2
      assert %RemoteStream{content_format: AAC, type: :bytestream} in tracks_info
      assert %RemoteStream{content_format: H264, type: :bytestream} in tracks_info

      chunks = Client.generate_stream(client) |> Enum.take(10)
      assert_chunks_are_in_proper_order(chunks)

      %{video: video_chunks, audio: audio_chunks} =
        chunks |> Enum.group_by(& &1.media_type)

      [video_chunk | _rest_video_chunks] = video_chunks

      assert %{pts_ms: 10_033, dts_ms: 10_000} = video_chunk
      assert byte_size(video_chunk.payload) == 1048

      assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 128, 80, 5, 187, 1, 16,
               0, 0, 3, 0, 16, 0, 0, 7, 128, 241, 131, 25, 160, 0, 0, 0,
               1>> <> _rest = video_chunk.payload

      [audio_chunk | _rest_audio_chunks] = audio_chunks
      assert %{pts_ms: 10_010, dts_ms: 10_010} = audio_chunk
      assert byte_size(audio_chunk.payload) == 6154

      assert <<255, 241, 80, 128, 4, 63, 252, 222, 4, 0, 0, 108, 105, 98, 102, 97, 97, 99, 32, 49,
               46, 50, 56, 0, 0, 66, 64, 147, 32, 4, 50, 0, 71, 255, 241, 80, 128, 10, 255, 252,
               33, 70, 254, 208, 221, 101, 200, 21, 97, 0>> <> _rest = audio_chunk.payload
    end

    test "(fMP4) stream" do
      client = Client.new(@fmp4_url)

      assert Client.get_variants(client) == %{}
      assert {:ok, tracks_info, client} = Client.get_tracks_info(client)
      tracks_info = tracks_info |> Map.values()

      assert tracks_info |> length() == 2

      assert %H264{
               width: 480,
               height: 270,
               alignment: :au,
               nalu_in_metadata?: false,
               stream_structure: {:avc1, _binary}
             } = tracks_info |> Enum.find(&match?(%H264{}, &1))

      assert %Membrane.AAC{
               sample_rate: 44_100,
               channels: 2,
               mpeg_version: 2,
               samples_per_frame: 1024,
               frames_per_buffer: 1,
               encapsulation: :none,
               config: {:esds, _binary}
             } = tracks_info |> Enum.find(&match?(%AAC{}, &1))

      chunks = Client.generate_stream(client) |> Enum.take(10)
      assert_chunks_are_in_proper_order(chunks)

      %{video: video_chunks, audio: audio_chunks} =
        chunks |> Enum.group_by(& &1.media_type)

      [video_chunk | _rest_video_chunks] = video_chunks

      assert %{pts_ms: 0, dts_ms: 0} = video_chunk
      assert byte_size(video_chunk.payload) == 775

      assert <<0, 0, 2, 171, 6, 5, 255, 255, 167, 220, 69, 233, 189, 230, 217, 72, 183, 150, 44,
               216, 32, 217, 35, 238, 239, 120, 50, 54, 52, 32, 45, 32, 99, 111, 114, 101, 32, 49,
               54, 52, 32, 114, 51, 49, 48, 56, 32, 51, 49, 101>> <> _rest = video_chunk.payload

      [first_audio_chunk, second_audio_chunk | _rest_audio_chunks] = audio_chunks

      assert %{pts_ms: 0, dts_ms: 0} = first_audio_chunk

      assert first_audio_chunk.payload ==
               <<220, 0, 76, 97, 118, 99, 54, 49, 46, 51, 46, 49, 48, 48, 0, 66, 32, 8, 193, 24,
                 56>>

      assert %{pts_ms: 23, dts_ms: 23} = second_audio_chunk
      assert second_audio_chunk.payload == <<33, 16, 4, 96, 140, 28>>
    end
  end

  test "(MPEGTS) stream with only video" do
    client = Client.new(@mpegts_only_video_url)

    assert Client.get_variants(client) == %{}
    assert {:ok, tracks_info, client} = Client.get_tracks_info(client)

    assert [%Membrane.RemoteStream{content_format: Membrane.H264, type: :bytestream}] =
             tracks_info |> Map.values()

    chunks = Client.generate_stream(client) |> Enum.take(10)
    [video_chunk | _rest_video_chunks] = chunks

    assert %{pts_ms: 1480, dts_ms: 1400} = video_chunk
    assert byte_size(video_chunk.payload) == 822

    assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 6, 5, 255, 255, 167, 220, 69, 233, 189, 230, 217, 72,
             183, 150, 44, 216, 32, 217, 35, 238, 239, 120, 50, 54, 52, 32, 45, 32, 99, 111, 114,
             101, 32, 49, 54, 52, 32, 114>> <> _rest = video_chunk.payload

    assert video_chunk.metadata == %{discontinuity: false, is_aligned: false, tden_tag: nil}
  end

  @tag :sometag
  test "(MPEGTS) stream with ID3v2.4 TDEN tag" do
    client = Client.new(@mpegts_with_tden_url)

    assert Client.get_variants(client) == %{}

    chunks = Client.generate_stream(client) |> Enum.take(381)

    first_audio_chunk_after_tden =
      Enum.find(
        chunks,
        &(&1.metadata.tden_tag != nil and &1.media_type == :audio)
      )

    first_video_chunk_after_tden =
      Enum.find(
        chunks,
        &(&1.metadata.tden_tag != nil and &1.media_type == :video)
      )

    assert first_audio_chunk_after_tden.pts_ms == 3328
    assert first_audio_chunk_after_tden.dts_ms == 3328
    assert first_audio_chunk_after_tden.metadata.tden_tag == "2025-10-21T08:07:50"

    assert first_video_chunk_after_tden.pts_ms == 3233
    assert first_video_chunk_after_tden.dts_ms == 3233
    assert first_video_chunk_after_tden.metadata.tden_tag == "2025-10-21T08:07:50"
  end

  test "(fMP4) stream with only video" do
    client = Client.new(@fmp4_only_video_url)

    assert Client.get_variants(client) == %{}
    assert {:ok, tracks_info, client} = Client.get_tracks_info(client)

    assert [
             %H264{
               width: 480,
               height: 270,
               alignment: :au,
               nalu_in_metadata?: false,
               stream_structure: {:avc1, _binary}
             }
           ] = tracks_info |> Map.values()

    chunks = Client.generate_stream(client) |> Enum.take(10)
    [video_chunk | _rest_video_chunks] = chunks

    assert %{pts_ms: 0, dts_ms: 0} = video_chunk
    assert byte_size(video_chunk.payload) == 823

    assert <<0, 0, 0, 2, 9, 240, 0, 0, 2, 171, 6, 5, 255, 255, 167, 220, 69, 233, 189, 230, 217,
             72, 183, 150, 44, 216, 32, 217, 35, 238, 239, 120, 50, 54, 52, 32, 45, 32, 99, 111,
             114, 101, 32, 49, 54, 52, 32, 114>> <> _rest = video_chunk.payload
  end

  test "(MPEGTS) stream with how_much_to_skip_ms" do
    how_much_to_skip_ms = 44_000
    client = Client.new(@mpegts_url, how_much_to_skip_ms: how_much_to_skip_ms)

    variant_720 =
      Client.get_variants(client)
      |> Map.values()
      |> Enum.find(&(&1.resolution == {1280, 720}))

    assert variant_720 != nil

    client = client |> Client.choose_variant(variant_720.id)
    {:ok, tracks_info, client} = Client.get_tracks_info(client)

    tracks_info = tracks_info |> Map.values()

    assert tracks_info |> length() == 2
    assert %RemoteStream{content_format: AAC, type: :bytestream} in tracks_info
    assert %RemoteStream{content_format: H264, type: :bytestream} in tracks_info

    chunks = Client.generate_stream(client) |> Enum.take(10)
    assert_chunks_are_in_proper_order(chunks)

    video_chunk = chunks |> Enum.find(&(&1.media_type == :video))

    # segments in the fixture are 10s long and
    # the timestamps offset is 10s, so the first
    # video pts after skipping initial 44 seconds should be div(10+44, 10) = 50s
    assert %{pts_ms: 50_033, dts_ms: 50_000} = video_chunk
    assert byte_size(video_chunk.payload) == 135_298

    assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 128, 80, 5, 187, 1, 16, 0,
             0, 3, 0, 16, 0, 0, 7, 128, 241, 131, 25, 160, 0, 0, 0, 1, 104, 233, 121, 203, 34,
             192, 0, 0, 1, 101, 136>> <> _rest = video_chunk.payload

    audio_chunk = chunks |> Enum.find(&(&1.media_type == :audio))

    assert %{pts_ms: 50_018, dts_ms: 50_018} = audio_chunk
    assert byte_size(audio_chunk.payload) == 6020

    assert <<255, 241, 80, 128, 47, 63, 252, 33, 10, 204, 43, 253, 251, 213, 30, 152, 129, 48, 80,
             38, 22, 18, 5, 130, 129, 113, 34, 92, 36, 20, 25, 9, 2, 193, 64, 144, 68, 36, 17, 75,
             215, 198, 77, 184, 229, 170, 157, 115, 169, 223>> <> _rest = audio_chunk.payload
  end

  test "(MPEGTS) stream with live edge mode" do
    client = Client.new(@mpegts_live_url, live_edge_mode?: true)

    assert Client.get_variants(client) == %{}
    assert {:ok, tracks_info, client} = Client.get_tracks_info(client)

    assert [%Membrane.RemoteStream{content_format: Membrane.H264, type: :bytestream}] =
             tracks_info |> Map.values()

    chunks = Client.generate_stream(client) |> Enum.take(1)
    [video_chunk | _rest_video_chunks] = chunks

    assert %{pts_ms: 11_081, dts_ms: 11_001} = video_chunk
    assert byte_size(video_chunk.payload) == 28_699

    assert <<0, 0, 0, 1, 9, 240, 0, 0, 0, 1, 103, 100, 0, 21, 172, 217, 65, 224, 143, 235, 1, 106,
             12, 2, 13, 110, 0, 0, 9, 154, 0, 1, 224, 0, 30, 44, 91, 44, 0, 0, 0, 1, 104, 234,
             225, 178, 200, 176, 0, 0>> <> _rest = video_chunk.payload

    assert video_chunk.metadata == %{discontinuity: false, is_aligned: false, tden_tag: nil}
  end

  defp assert_chunks_are_in_proper_order(chunks) do
    iteration_state = %{
      last_dts: %{audio: nil, video: nil},
      should_end: %{audio: false, video: false}
    }

    _final_iteration_state =
      chunks
      |> Enum.reduce(iteration_state, fn chunk, iteration_state ->
        assert not iteration_state.should_end[chunk.media_type]

        expected_media_types =
          case iteration_state.last_dts do
            %{audio: nil, video: nil} -> [:audio, :video]
            %{audio: nil, video: _video_dts} -> [:audio]
            %{audio: _audio_dts, video: nil} -> [:video]
            %{audio: audio_dts, video: video_dts} when audio_dts < video_dts -> [:audio]
            %{audio: audio_dts, video: video_dts} when audio_dts > video_dts -> [:video]
            %{audio: audio_dts, video: video_dts} when audio_dts == video_dts -> [:audio, :video]
          end

        iteration_state
        |> put_in([:last_dts, chunk.media_type], chunk.dts_ms)
        |> put_in([:should_end, chunk.media_type], chunk.media_type not in expected_media_types)
      end)

    :ok
  end
end
