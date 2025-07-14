defmodule ExHLS.Parsers.H264 do
  @moduledoc false

  alias Membrane.H264.{
    AUSplitter,
    NALuParser,
    NALuSplitter
  }

  @aud <<0x00, 0x00, 0x00, 0x01, 0x09, 0x16>>

  @enforce_keys [:nalu_splitter, :nalu_parser, :au_splitter]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          nalu_splitter: NALuSplitter.t(),
          nalu_parser: NALuParser.t(),
          au_splitter: AUSplitter.t()
        }

  @doc """
  Returns a new instance of the H264 Parser.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      nalu_splitter: NALuSplitter.new(),
      nalu_parser: NALuParser.new(),
      au_splitter: AUSplitter.new()
    }
  end

  @doc """
  Parses an incoming H264 payload and returns a list of access units
  along the updated state of the parser.
  Please note that the parser is allowed to buffer incoming data.
  You can call: ``#{inspect(__MODULE__)}.flush/1` to flush out the buffers data (e.g.
  when the stream ends)
  """
  @spec parse(binary(), t()) :: {[binary()], t()}
  def parse(payload, %__MODULE__{} = parser) do
    {nalu_payloads, nalu_splitter} = NALuSplitter.split(payload, parser.nalu_splitter)
    {nalus, nalu_parser} = NALuParser.parse_nalus(nalu_payloads, parser.nalu_parser)
    {aus, au_splitter} = AUSplitter.split(nalus, parser.au_splitter)
    aus = join_nalus_in_aus(aus)

    parser = %{
      parser
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {aus, parser}
  end

  @doc """
  Flushes out the data buffered in the internal state of the parser.
  """
  @spec flush(t()) :: {[binary()], t()}
  def flush(parser) do
    {nalu_payloads, nalu_splitter} = NALuSplitter.split(<<>>, true, parser.nalu_splitter)
    {nalus, nalu_parser} = NALuParser.parse_nalus(nalu_payloads, parser.nalu_parser)
    {aus, au_splitter} = AUSplitter.split(nalus, true, parser.au_splitter)
    aus = join_nalus_in_aus(aus)

    parser = %{
      parser
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {aus, parser}
  end

  @doc """
  Adds an Access Unit Delimeter NAL unit if it's not present at
  the beginning of the binary.
  Please note that this function assumes that the provided payload
  is a single Access Unit.
  """
  @spec maybe_add_aud(binary()) :: binary()
  def maybe_add_aud(au) do
    if String.starts_with?(au, @aud), do: au, else: @aud <> au
  end

  @spec get_stream_format() :: struct()
  def get_stream_format() do
    %Membrane.H264{
      alignment: :au,
      stream_structure: :annexb
    }
  end

  defp join_nalus_in_aus(aus) do
    annexb_prefix = <<0, 0, 0, 1>>

    Enum.map(aus, fn au ->
      %{
        payload: Enum.map_join(au, &(annexb_prefix <> &1.payload)),
        is_keyframe: Enum.any?(au, &(&1.type == :idr))
      }
    end)
  end
end
