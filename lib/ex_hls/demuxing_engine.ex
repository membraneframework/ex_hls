defmodule ExHLS.DemuxingEngine do
  @moduledoc """
  A behaviour todo: finish doc
  """

  @type t :: any()

  @callback new() :: t()

  @callback feed!(t(), binary()) :: t()

  @callback get_tracks_info(t()) :: {:ok, %{optional(integer()) => struct()}} | {:error, any()}

  # a moze trzeba pop_frame :: {:ok, frame, t} | {:error, :end_of_stream}

  @callback pop_frame(t(), track_id :: any()) ::
              {:ok, ExHLS.Frame.t(), t()} | {:error, :empty_track_data, t()}

  @callback end_stream(t()) :: {:ok, t()}
end
