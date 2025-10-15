# ExHLS

[![Hex.pm](https://img.shields.io/hexpm/v/ex_hls.svg)](https://hex.pm/packages/ex_hls)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/ex_hls)
[![CircleCI](https://circleci.com/gh/membraneframework/ex_hls.svg?style=svg)](https://circleci.com/gh/membraneframework/ex_hls)

This repository contains ExHLS - an Elixir package for handling HLS streams.

It's a part of the [Membrane Framework](https://membrane.stream).

## Installation

The package can be installed by adding `ex_hls` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_hls, "~> 0.1.4"}
  ]
end
```

## Usage

To read HLS stream from the `.m3u8 playlist`, start the client with:
```elixir
client = ExHLS.Client.new(<URI of the .m3u8 playlist>)
```

Then you can inspect the variants available in your playlist:
```elixir
ExHLS.Client.get_variants(client)
# Returns:
#   %{
#     0 => %{
#       id: 0,
#       name: "720",
#       uri: "url_0/193039199_mp4_h264_aac_hd_7.m3u8",
#       codecs: "mp4a.40.2,avc1.64001f",
#       bandwidth: 2149280,
#       resolution: {1280, 720},
#       frame_rate: nil
#     },
#     ...
#   }
```

If there are multiple variants available, you need to choose one of them with:
```elixir
ExHLS.Client.choose_variant(client, <id>)
```
where `<id>` is the `id` field of the entry returned by `ExHLS.Client.get_variants/1`.

Now you can get the Elixir stream containing media chunks:
```elixir
stream = ExHLS.Client.generate_stream(client)
Enum.take(stream, 5)
# Returns: 
# [
#   %ExHLS.Chunk{
#     payload: <<220, 0, 76, 97, 118, 99, 54, 49, 46, 51, 46, 49, 48, 48, 0, 66,
#       32, 8, 193, 24, 56>>,
#     pts_ms: 0,
#     dts_ms: 0,
#     track_id: 2,
#     metadata: %{},
#     media_type: :audio
#   },
#   %ExHLS.Chunk{
#     payload: <<0, 0, 2, 171, 6, 5, 255, 255, 167, 220, 69, 233, 189, 230, 217,
#       72, 183, 150, 44, 216, 32, 217, 35, 238, 239, 120, 50, 54, 52, 32, 45, 32,
#       99, 111, 114, 101, 32, 49, 54, 52, 32, 114, 51, 49, 48, 56, 32, ...>>,
#     pts_ms: 0,
#     dts_ms: 0,
#     track_id: 1,
#     metadata: %{},
#     media_type: :video
#   },
#   %ExHLS.Chunk{
#     payload: <<33, 16, 4, 96, 140, 28>>,
#     pts_ms: 23,
#     dts_ms: 23,
#     track_id: 2,
#     metadata: %{},
#     media_type: :audio
#   },
#   %ExHLS.Chunk{
#     payload: <<0, 0, 1, 222, 65, 154, 34, 108, 67, 63, 254, 169, 150, 0, 4, 1,
#       131, 32, 3, 199, 34, 90, 245, 77, 218, 222, 66, 91, 35, 3, 208, 204, 165,
#       117, 149, 218, 168, 161, 173, 73, 104, 105, 159, 56, 151, ...>>,
#     pts_ms: 40,
#     dts_ms: 40,
#     track_id: 1,
#     metadata: %{},
#     media_type: :video
#   },
#   %ExHLS.Chunk{
#     payload: <<33, 16, 4, 96, 140, 28>>,
#     pts_ms: 46,
#     dts_ms: 46,
#     track_id: 2,
#     metadata: %{},
#     media_type: :audio
#   }
# ]
```

To pop only single elements from the stream containing ExHLS Chunks, you can use [`StreamSplit.pop/1`](https://hexdocs.pm/stream_split/StreamSplit.html#pop/1).

Note: If the HLS playlist type is Live (not VoD), you can generate stream from single `ExHLS.Client` instance only once and only from the process, that created that `ExHLS.Client`. If you want to genereate more streams with Live HLS, you have to create a new `ExHLS.Client` each time.

## Copyright and License

Copyright 2025, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_hls)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_hls)

Licensed under the [Apache License, Version 2.0](LICENSE)
