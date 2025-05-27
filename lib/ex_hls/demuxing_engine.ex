defmodule ExHLS.DemuxingEngine do
  @moduledoc """
  A behaviour todo: finish doc
  """

  @type t :: any()

  @callback new() :: t()

  @callback feed!(t(), binary()) :: t()

  @callback get_tracks_info(t()) :: {:ok, map()} | {:error, any()}

  # a moze trzeba pop_frame :: {:ok, frame, t} | {:error, :end_of_stream}

  @callback pop_frame(t(), track_id :: any()) ::
              {:ok, ExHLS.Frame.t(), t()} | {:error, reson :: any()}

  @callback end_stream(t()) :: {:ok, t()}
end
