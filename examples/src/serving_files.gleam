import ewe.{type Response}
import gleam/erlang/process
import gleam/http/response
import gleam/option.{None}
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Start a simple file server that serves files from the "public" directory.
  //
  let assert Ok(_) =
    ewe.new(fn(req) { serve_file(req.path) })
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn serve_file(path: String) -> Response {
  // Load file from disk using ewe.file(). This efficiently streams the file
  // content without loading it entirely into memory.
  //
  // In production, make sure to validate paths to prevent directory traversal
  // attacks! (e.g., requests to "../../../etc/passwd")
  //
  case ewe.file("public/" <> path, offset: None, limit: None) {
    Ok(file) -> {
      // Using "application/octet-stream" is safe for any file type, but you
      // may want to specify content-type based on file extension in production.
      //
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(file)
    }
    Error(_) -> {
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("File not found"))
    }
  }
}
