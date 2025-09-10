defmodule ExHLS.Chunk do
  @moduledoc """
  A struct representing a media chunk in the ExHLS demuxing engine.
  """
  @enforce_keys [:payload, :pts_ms, :dts_ms, :track_id]
  defstruct @enforce_keys ++ [metadata: %{}, media_type: nil]

  @type t :: %__MODULE__{
          payload: binary(),
          pts_ms: integer(),
          dts_ms: integer(),
          track_id: term(),
          metadata: map(),
          media_type: :audio | :video | nil
        }
end
