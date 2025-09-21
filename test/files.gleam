import ewe/internal/file

pub fn main() {
  file.open("test/test.txt")
  |> echo
}
