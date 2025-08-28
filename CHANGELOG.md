# Changelog

# Unreleased

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