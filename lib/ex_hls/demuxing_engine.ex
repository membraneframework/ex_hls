defmodule ExHLS.DemuxingEngine do
  @moduledoc false

  @type t :: any()

  @callback new() :: t()

  @callback feed!(t(), binary()) :: t()

  @callback get_tracks_info(t()) :: {:ok, %{optional(integer()) => struct()}} | {:error, any()}

  @callback pop_sample(t(), track_id :: any()) ::
              {:ok, ExHLS.Sample.t(), t()} | {:error, :empty_track_data, t()}

  @callback end_stream(t()) :: t()
end
