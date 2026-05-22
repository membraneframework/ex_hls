defmodule ExHLS.DemuxingEngine.ID3 do
  @moduledoc false

  @spec parse_tden_tag(binary()) :: String.t() | nil
  def parse_tden_tag(payload) do
    # UTF-8 encoding
    encoding = 3

    with {pos, _len} <- :binary.match(payload, "TDEN"),
         <<_skip::binary-size(pos), "TDEN", tden::binary>> <- payload,
         <<size::integer-size(4)-unit(8), _flags::16, ^encoding::8, text::binary-size(size - 2),
           0::8, _rest::binary>> <- tden do
      text
    else
      _error -> nil
    end
  end
end
