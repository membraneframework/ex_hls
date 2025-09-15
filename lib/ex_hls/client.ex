defmodule ExHLS.Client do
  @moduledoc """
  Module providing functionality to read and demux HLS streams.
  It allows reading chunks from the stream, choosing variants, and managing media playlists.
  """

  use Bunch.Access

  require Logger

  alias __MODULE__.{Live, Utils, VOD}

  @enforce_keys [
    :parent_process,
    :hls_mode,
    :media_playlist,
    :media_playlist_url,
    :multivariant_playlist,
    :root_playlist_url,
    :root_playlist_string,
    :base_url,
    :vod_client,
    :live_reader,
    :live_forwarder,
    :how_much_to_skip_ms
  ]

  defstruct @enforce_keys

  @opaque client :: %__MODULE__{}

  @type variant_description :: %{
          id: integer(),
          name: String.t() | nil,
          frame_rate: number() | nil,
          resolution: {integer(), integer()} | nil,
          codecs: String.t() | nil,
          bandwidth: integer() | nil,
          uri: String.t() | nil
        }

  @doc """
  Starts the ExHLS client with the given URL.

  As options, you can pass `:parent_process` to specify the parent process that will be
  allowed to read media chunks when the HLS stream is in the Live mode.
  Parent process defaults to the process that created the client.

  You can also pass `:how_much_to_skip_ms` option to specify how many milliseconds
  of the beginning of the stream should be skipped. This option is only supported
  when the HLS stream is in the VoD mode. Defaults to `0`.

  Note that there is no guarantee that exactly the specified amount of time will be skipped.
  The actual skipped duration may be slightly shorter, depending on the HLS segments durations.
  To get the actual skipped duration, you can use `get_skipped_segments_cumulative_duration_ms/1`
  function.
  """
  @spec new(String.t(), parent_process: pid(), how_much_to_skip_ms: non_neg_integer()) :: client()
  def new(url, opts \\ []) do
    %{parent_process: parent_process, how_much_to_skip_ms: how_much_to_skip_ms} =
      opts
      |> Keyword.validate!(parent_process: self(), how_much_to_skip_ms: 0)
      |> Map.new()

    root_playlist_string = Utils.download_or_read_file!(url)
    multivariant_playlist = root_playlist_string |> ExM3U8.deserialize_multivariant_playlist!([])

    %__MODULE__{
      parent_process: parent_process,
      hls_mode: nil,
      media_playlist: nil,
      media_playlist_url: nil,
      multivariant_playlist: multivariant_playlist,
      root_playlist_url: url,
      root_playlist_string: root_playlist_string,
      base_url: Path.dirname(url),
      vod_client: nil,
      live_reader: nil,
      live_forwarder: nil,
      how_much_to_skip_ms: how_much_to_skip_ms
    }
    |> maybe_resolve_media_playlist()
  end

  defp maybe_resolve_media_playlist(client) do
    case get_variants(client) |> Map.to_list() do
      [] ->
        client
        |> treat_root_playlist_as_media_playlist()
        |> resolve_hls_mode()

      [{variant_id, _variant}] ->
        client
        |> do_choose_variant(variant_id)
        |> resolve_hls_mode()

      _many_variants ->
        client
    end
  end

  defp resolve_hls_mode(%{hls_mode: nil} = client) do
    if client.media_playlist.info.end_list? do
      Logger.info("[#{inspect(__MODULE__)}] #{client.media_playlist_url} HLS stream type is VoD.")

      vod_client =
        ExHLS.Client.VOD.new(
          client.media_playlist_url,
          client.media_playlist,
          client.how_much_to_skip_ms
        )

      %{client | vod_client: vod_client, hls_mode: :vod}
    else
      Logger.info("""
      [#{inspect(__MODULE__)}] #{client.media_playlist_url} HLS stream type is Live. Reading \
      multimedia chunks will be available only from the parent process \
      (#{inspect(client.parent_process)}).
      """)

      if client.how_much_to_skip_ms > 0 do
        raise """
        `how_much_to_skip_ms` option was set to #{inspect(client.how_much_to_skip_ms)},
        but using it is not supported when HLS in the Live mode.
        """
      end

      {:ok, forwarder} = ExHLS.Client.Live.Forwarder.start_link(client.parent_process)
      {:ok, reader} = ExHLS.Client.Live.Reader.start_link(client.media_playlist_url, forwarder)
      %{client | live_reader: reader, live_forwarder: forwarder, hls_mode: :live}
    end
  end

  defp ensure_hls_mode_resolved!(%__MODULE__{hls_mode: nil} = client) do
    # the error message is about choosing a variant, while the function name is
    # about resolving the HLS mode, but it is done this way because the HLS mode
    # might be unresolved only due to not resolving the variant

    raise """
    If there are available variants, you have to choose one of them using \
    `choose_variant/2` function before reading chunks. Available variants: \
    #{get_variants(client) |> inspect(limit: :infinity, pretty: true)}
    """
  end

  defp ensure_hls_mode_resolved!(%__MODULE__{}), do: :ok

  defp treat_root_playlist_as_media_playlist(%__MODULE__{media_playlist: nil} = client) do
    media_playlist =
      client.root_playlist_string
      |> ExM3U8.deserialize_media_playlist!([])

    %{
      client
      | media_playlist: media_playlist,
        media_playlist_url: client.root_playlist_url
    }
  end

  @spec get_variants(client()) :: %{optional(integer()) => variant_description()}
  def get_variants(%__MODULE__{} = client) do
    client.multivariant_playlist.items
    |> Enum.filter(&match?(%ExM3U8.Tags.Stream{}, &1))
    |> Enum.with_index(fn variant, index ->
      variant_description =
        variant
        |> Map.take([:name, :frame_rate, :resolution, :codecs, :bandwidth, :uri])
        |> Map.put(:id, index)

      {index, variant_description}
    end)
    |> Map.new()
  end

  @spec choose_variant(client(), String.t()) :: client()
  def choose_variant(%__MODULE__{} = client, variant_id) do
    client
    |> do_choose_variant(variant_id)
    |> resolve_hls_mode()
  end

  defp do_choose_variant(%__MODULE__{} = client, variant_id) do
    chosen_variant = get_variants(client) |> Map.fetch!(variant_id)
    media_playlist_url = Path.join(client.base_url, chosen_variant.uri)

    media_playlist =
      media_playlist_url
      |> Utils.download_or_read_file!()
      |> ExM3U8.deserialize_media_playlist!([])

    %{
      client
      | media_playlist: media_playlist,
        media_playlist_url: media_playlist_url
    }
  end

  @spec generate_stream(client()) :: Enumerable.t(ExHLS.Chunk.t())
  def generate_stream(%__MODULE__{} = client) do
    :ok = ensure_hls_mode_resolved!(client)

    case client.hls_mode do
      :vod -> VOD.generate_stream(client.vod_client)
      :live -> Live.Forwarder.generate_stream(client.live_forwarder)
    end
  end

  @spec get_tracks_info(client()) ::
          {:ok, %{optional(integer()) => struct()}, client()}
          | {:error, reason :: any(), client()}
  def get_tracks_info(%__MODULE__{} = client) do
    :ok = ensure_hls_mode_resolved!(client)

    case client.hls_mode do
      :vod ->
        {ok_or_error, value_or_reason, vod_client} =
          VOD.get_tracks_info(client.vod_client)

        {ok_or_error, value_or_reason, %{client | vod_client: vod_client}}

      :live ->
        tracks_info = Live.Forwarder.request_tracks_info(client.live_forwarder)
        {:ok, tracks_info, client}
    end
  end

  @spec get_skipped_segments_cumulative_duration_ms(client()) ::
          {:ok, non_neg_integer()} | {:error, reason :: any()} | no_return()
  def get_skipped_segments_cumulative_duration_ms(client) do
    :ok = ensure_hls_mode_resolved!(client)

    case client.hls_mode do
      :vod -> VOD.get_skipped_segments_cumulative_duration_ms(client.vod_client)
      :live -> raise "Skipping segments is not supported in HLS Live mode"
    end
  end
end
