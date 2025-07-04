defmodule ExHLS.Sample do
  @moduledoc """
  A struct representing a media sample in the ExHLS demuxing engine.
  """
  @enforce_keys [:payload, :pts_ms, :dts_ms, :track_id]
  defstruct @enforce_keys ++ [metadata: %{}]

  @type t :: %__MODULE__{
          payload: binary(),
          pts_ms: integer(),
          dts_ms: integer(),
          track_id: term(),
          metadata: map()
        }

  # timestamps need to be represented in milliseconds
  @time_base 1000

  def time_base(), do: @time_base
end
