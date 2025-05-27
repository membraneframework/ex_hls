defmodule ExHLS.Frame do
  @enforce_keys [:payload, :pts, :dts, :track_id]
  defstruct @enforce_keys ++ [metadata: %{}]
  # discontinuity, :is_aligned


  @type t :: %__MODULE__{
          payload: binary(),
          pts: integer(),
          dts: integer(),
          track_id: term(),
          metadata: map()
        }

  @time_base 1000 # timestamps need to be represented in milliseconds

  def time_base(), do: @time_base
end
