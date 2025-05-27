defmodule ExHLS.DemuxingEngine do
  @moduledoc """
  A behaviour todo: finish doc
  """

  @type t :: any()

  @callback new() :: t()

  @callback feed!(t(), binary()) :: t()

  @callback get_tracks_info(t()) :: {:ok, map()} | {:error, any()}

  @callback pop_frames(t()) ::
              {:ok, [ExHLS.Frame.t()], t()} | {:end_of_stream, t()}

  @callback end_stream(t()) :: {:ok, t()}
end
