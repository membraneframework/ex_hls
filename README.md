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
    {:ex_hls, "~> 0.0.1"}
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
ExHLS.Client.choose_variant(<id>)
```
where the id is the `id` field of the entry returned by `ExHLS.Client.get_variants/1`.

Now you can start reading media with the following functions:
```elixir
{video_chunk, client} = ExHLS.Client.read_video_chunk(client)
{audio_chunk, client} = ExHLS.Client.read_audio_chunk(client)
```

## Copyright and License

Copyright 2025, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_hls)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=ex_hls)

Licensed under the [Apache License, Version 2.0](LICENSE)
