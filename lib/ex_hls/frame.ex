defmodule ExHLS.Frame do
  @enforce_keys [:payload, :pts, :dts, :discontinuity, :is_aligned]
  defstruct @enforce_keys


  @time_base 1000 # timestamps need to be represented in milliseconds

  def time_base(), do: @time_base
end
