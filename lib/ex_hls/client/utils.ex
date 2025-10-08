defmodule ExHLS.Client.Utils do
  @moduledoc false

  require Logger

  alias ExHLS.DemuxingEngine
  alias Membrane.{AAC, H264, RemoteStream}

  @spec download_or_read_file!(String.t()) :: binary()
  def download_or_read_file!(uri_or_path) do
    case URI.parse(uri_or_path).host do
      nil ->
        :ok = await_until_file_exists!(uri_or_path)
        Logger.debug("[ExHLS.Client] opening #{uri_or_path}")
        File.read!(uri_or_path)

      _host ->
        Logger.debug("[ExHLS.Client] downloading #{uri_or_path}")
        %{status: 200, body: body} = Req.get!(uri_or_path)
        body
    end
  end

  defp await_until_file_exists!(file_path) do
    cond do
      File.exists?(file_path) -> :ok
      file_exists_after_waiting?(file_path, 20) -> :ok
      file_exists_after_waiting?(file_path, 60) -> :ok
      file_exists_after_waiting?(file_path, 120) -> :ok
      true -> raise "File #{file_path} does not exist"
    end
  end

  defp file_exists_after_waiting?(file_path, ms) do
    Process.sleep(ms)
    File.exists?(file_path)
  end

  @spec stream_format_to_media_type(struct()) :: :audio | :video
  def stream_format_to_media_type(%H264{}), do: :video
  def stream_format_to_media_type(%AAC{}), do: :audio
  def stream_format_to_media_type(%RemoteStream{content_format: H264}), do: :video
  def stream_format_to_media_type(%RemoteStream{content_format: AAC}), do: :audio

  @spec resolve_demuxing_engine_impl(String.t(), :ts | :cmaf | nil) :: atom()
  def resolve_demuxing_engine_impl(segment_uri, nil) do
    case Path.extname(segment_uri) do
      ".ts" <> _id ->
        DemuxingEngine.MPEGTS

      ".m4s" <> _id ->
        DemuxingEngine.CMAF

      ".mp4" <> _id ->
        DemuxingEngine.CMAF

      _other ->
        Logger.warning("""
        Unsupported segment URI extension: #{segment_uri |> inspect()}
        Falling back to recognizing segment as MPEG-TS container file.
        You can force recognizing segment as CMAF container file
        by providing `segment_format: :cmaf` to `ExHLS.Client/2`.
        """)
    end
  end

  def resolve_demuxing_engine_impl(_segment_uri, :ts), do: DemuxingEngine.MPEGTS
  def resolve_demuxing_engine_impl(_segment_uri, :cmaf), do: DemuxingEngine.CMAF
end
