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

  @spec resolve_demuxing_engine_impl(String.t()) :: atom()
  def resolve_demuxing_engine_impl(segment_uri) do
    URI.parse(segment_uri).path
    |> Path.extname()
    |> case do
      ".ts" -> DemuxingEngine.MPEGTS
      ".m4s" -> DemuxingEngine.CMAF
      ".mp4" -> DemuxingEngine.CMAF
      _other -> raise "Unsupported segment URI extension: #{segment_uri |> inspect()}"
    end
  end
end
