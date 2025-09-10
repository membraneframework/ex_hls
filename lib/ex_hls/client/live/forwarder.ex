defmodule ExHLS.Client.Live.Forwarder do
  @moduledoc false
  # This module:
  #  - buffers media chunks arriving from the ExHLS.Client.Live.Reader
  #  - forwards them to the parent process
  # The goal of introducing this module is to allow popping chunks while the ExHLS.Client.Live.Reader
  # is downloading or parsing media playlist or segments.

  use GenServer
  require Logger
  alias ExHLS.Client.Utils

  @type t :: pid()

  @spec start_link(pid()) :: {:ok, t()} | {:error, any()}
  def start_link(parent_process) do
    GenServer.start_link(__MODULE__, parent_process: parent_process)
  end

  @spec feed_with_media_chunk(t(), :audio | :video, ExHLS.Chunk.t()) :: :ok
  def feed_with_media_chunk(forwarder, media_type, chunk) when media_type in [:audio, :video] do
    send(forwarder, {:chunk, media_type, chunk})
    :ok
  end

  @spec feed_with_tracks_info(t(), map()) :: :ok
  def feed_with_tracks_info(forwarder, tracks_info) do
    send(forwarder, {:tracks_info, tracks_info})
    :ok
  end

  @spec feed_with_end_of_stream(t(), :audio | :video) :: :ok
  def feed_with_end_of_stream(forwarder, media_type) when media_type in [:audio, :video] do
    send(forwarder, {:end_of_stream, media_type})
    :ok
  end

  @spec request_chunk(t(), :audio | :video) ::
          ExHLS.Chunk.t() | :end_of_stream | {:error, atom()}
  def request_chunk(forwarder, media_type) when media_type in [:audio, :video] do
    send(forwarder, {:request, media_type, self()})

    receive do
      {:chunk, ^media_type, chunk} ->
        chunk

      {:end_of_stream, ^media_type} ->
        :end_of_stream
    end
  end

  @spec request_tracks_info(t()) :: :ok
  def request_tracks_info(forwarder) do
    send(forwarder, {:request, :tracks_info, self()})

    # todo: handle tracks info error
    receive do
      {:tracks_info, tracks_info} -> tracks_info
    end
  end

  @spec generate_stream(t()) :: Enumerable.t(ExHLS.Chunk.t())
  def generate_stream(forwarder) do
    GenServer.call(forwarder, :lock_stream)

    media_types =
      request_tracks_info(forwarder)
      |> Enum.map(fn {_track_id, format} ->
        Utils.stream_format_to_media_type(format)
      end)

    last_timestamps = media_types |> Map.new(&{&1, nil})

    Stream.unfold(last_timestamps, &generate_next_stream_chunk(forwarder, &1))
  end

  defp generate_next_stream_chunk(_forwarder, last_timestamps)
       when map_size(last_timestamps) == 0 do
    nil
  end

  defp generate_next_stream_chunk(forwarder, last_timestamps) do
    {media_type, _ts} =
      last_timestamps
      |> Enum.max_by(fn
        {_media_type, nil} -> :infinity
        {_media_type, ts} -> -ts
      end)

    case request_chunk(forwarder, media_type) do
      :end_of_stream ->
        last_timestamps = last_timestamps |> Map.delete(media_type)
        generate_next_stream_chunk(forwarder, last_timestamps)

      chunk ->
        last_timestamps =
          last_timestamps
          |> Map.put(media_type, chunk.dts_ms || chunk.pts_ms)

        {chunk, last_timestamps}
    end
  end

  @impl true
  def init(parent_process: parent_process) do
    media_type_init_state = %{
      qex: Qex.new(),
      qex_size: 0,
      chunks_requested: 0,
      end_of_stream?: false
    }

    state = %{
      parent_process: parent_process,
      audio: media_type_init_state,
      video: media_type_init_state,
      tracks_info: nil,
      tracks_info_requested?: false,
      locked?: false
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:chunk, media_type, chunk}, state) when media_type in [:audio, :video] do
    state =
      state
      |> update_in([media_type, :qex], &Qex.push(&1, chunk))
      |> update_in([media_type, :qex_size], &(&1 + 1))
      |> response_on_chunk_requests(media_type)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tracks_info, tracks_info}, state) do
    state =
      %{state | tracks_info: tracks_info}
      |> response_on_tracks_info_request()

    {:noreply, state}
  end

  @impl true
  def handle_info({:end_of_stream, media_type}, state) when media_type in [:audio, :video] do
    state =
      state
      |> put_in([media_type, :end_of_stream?], true)
      |> response_on_chunk_requests(media_type)

    {:noreply, state}
  end

  @impl true
  def handle_info({:request, media_type, requester}, state) when media_type in [:audio, :video] do
    if state.parent_process != requester do
      raise "Requester #{inspect(requester)} is not the parent process #{inspect(state.parent_process)}"
    end

    state =
      state
      |> update_in([media_type, :chunks_requested], &(&1 + 1))
      |> response_on_chunk_requests(media_type)

    {:noreply, state}
  end

  @impl true
  def handle_info({:request, :tracks_info, requester}, state) do
    if state.parent_process != requester do
      raise "Requester #{inspect(requester)} is not the parent process #{inspect(state.parent_process)}"
    end

    if state.tracks_info_requested? do
      raise "Tracks info already requested"
    end

    state =
      %{state | tracks_info_requested?: true}
      |> response_on_tracks_info_request()

    {:noreply, state}
  end

  @impl true
  def handle_call(:lock_stream, _from, state) do
    if state.locked?, do: raise("Cannot call generate_stream/1 twice on the same Live HLS Client")
    state = %{state | locked?: true}
    {:reply, :ok, state}
  end

  defp response_on_chunk_requests(state, media_type) do
    cond do
      state[media_type].chunks_requested == 0 ->
        state

      state[media_type].qex_size > 0 ->
        {chunk, qex} = Qex.pop!(state[media_type].qex)
        send(state.parent_process, {:chunk, media_type, chunk})

        state
        |> put_in([media_type, :qex], qex)
        |> update_in([media_type, :qex_size], &(&1 - 1))
        |> update_in([media_type, :chunks_requested], &(&1 - 1))
        |> response_on_chunk_requests(media_type)

      state[media_type].end_of_stream? ->
        send(state.parent_process, {:end_of_stream, media_type})

        state
        |> update_in([media_type, :chunks_requested], &(&1 - 1))
        |> response_on_chunk_requests(media_type)

      true ->
        state
    end
  end

  defp response_on_tracks_info_request(state) do
    if state.tracks_info_requested? and state.tracks_info != nil do
      send(state.parent_process, {:tracks_info, state.tracks_info})
      %{state | tracks_info_requested?: false}
    else
      state
    end
  end
end
