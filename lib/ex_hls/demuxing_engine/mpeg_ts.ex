defmodule ExHLS.DemuxingEngine.MPEGTS do
  @moduledoc """
  todo: here
  """

  alias MPEG.TS.Demuxer

  @behaviour ExHLS.DemuxingEngine

  @enforce_keys [:demuxer, :tracks_info]
  defstruct @enforce_keys

  @impl true
  def new() do
    %__MODULE__{
      demuxer: Demuxer.new(),
      tracks_info: nil
    }
  end

  @impl true
  def feed!(%__MODULE__{} = demuxing_engine, binary) do
    demuxer = Demuxer.push_buffer(demuxing_engine.demuxer, binary)
    %{demuxing_engine | demuxer: demuxer}
  end

  @impl true
  def get_tracks_info(%__MODULE__{} = demuxing_engine) do
    demuxing_engine = maybe_resolve_tracks_info(demuxing_engine)

    case demuxing_engine.tracks_info do
      nil -> {:error, :tracks_info_not_available}
      tracks_info -> {:ok, tracks_info}
    end
  end

  # todo: kontunuuj tutaj :)
  # milego dnia

  # defp maybe_resolve_tracks_info(%__MODULE__{tracks_info: nil} = demuxing_engine) do
  #   tracks_info = Demuxer.get_tracks_info(demuxing_engine.demuxer)
  #   %{demuxing_engine | tracks_info: tracks_info}
  # end
end
