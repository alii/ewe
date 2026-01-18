# Ewe Examples

This directory contains practical examples demonstrating various features of ewe.

To run an example, use the following command:
```sh
gleam run -m <example name>
```

For example, to run the getting started example:
```sh
gleam run -m getting_started
```

## Examples

Here is a list of all the examples:

- [getting_started](./src/getting_started.gleam) - Basic HTTP server with "Hello, World!" response
- [sending_response](./src/sending_response.gleam) - Different response body types (text, binary, empty)
- [reading_body](./src/reading_body.gleam) - Reading and echoing request bodies with size limits
- [streaming_body](./src/streaming_body.gleam) - Streaming large request/response bodies in chunks
- [serving_files](./src/serving_files.gleam) - Serving static files from disk
- [websocket](./src/websocket.gleam) - WebSocket connections with topic-based pubsub
- [sse](./src/sse.gleam) - Server-Sent Events for real-time server-to-client updates
