# Changelog

# Unreleased

- Response body must now be of type `ResponseBody`. To set the response body, use the following functions: `ewe.text`, `ewe.bytes`, `ewe.bits`, `ewe.string_tree`, `ewe.empty`, `ewe.json`.
- HTTP parser now handles `Expect: 100-continue`.
- Optimize formatting of popular HTTP fields without wasting time on transforming from `BitArray` to `String`.
- Duplicate request headers are now being combined (except `set-cookie`).

# v0.4.0

- Implement WebSocket protocol; request can be upgraded in handler using `ewe.upgrade_websocket`.
- Every message received in WebSocket handler is of `WebsocketMessage` type.
- Handler must return a `Next` type, which can be created using `ewe.continue`, `ewe.stop` and `ewe.stop_abnormal`.
- Add `ewe.bits` for setting response body from `BitArray` type.
- Add experimental `ewe.use_expression`.
- Rename internal file from `response.gleam` to `encoder.gleam`, matching `decoder.gleam` file.

# v0.3.0

- Remove atom values from ffi's `decode_packet`.
- Request handler is now rescued during crashes, thanks to ffi's `rescue` function.
- Add new `on_crash` option that sends a custom response when the handler is rescued. Use `ewe.on_crash` to configure this option.
- Glisten server is now part of a supervision tree along with an information actor for managing server state. Server information can be extracted using `ewe.get_server_info`.
- Add new `info_worker_name` option for naming the information worker's subject. Use `ewe.with_name` to configure this option.
- `ewe.client_stats` is now named `ewe.get_client_info` for consistency with the server getter pattern.
- Add `ewe.with_random_port` that sets `port` to `0`.
- Add `ewe.with_read_body` that allows reading the body before passing the request to the handler.
- Add `ewe.json`, `ewe.text`, `ewe.bytes` for different response body.
- Fill documentation