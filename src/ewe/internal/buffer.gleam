import gleam/bit_array
import gleam/int

pub type Buffer {
  Buffer(data: BitArray, remaining: Int)
}

pub fn new_sized(initial: BitArray, size: Int) {
  Buffer(initial, size)
}

pub fn new(initial: BitArray) -> Buffer {
  Buffer(initial, 0)
}

pub fn empty() -> Buffer {
  Buffer(<<>>, 0)
}

pub fn sized(buffer: Buffer, size: Int) -> Buffer {
  Buffer(buffer.data, size)
}

pub fn append(buffer: Buffer, data: BitArray) -> Buffer {
  let remaining = int.max(0, buffer.remaining - bit_array.byte_size(data))
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}

pub fn append_size(buffer: Buffer, data: BitArray, size: Int) -> Buffer {
  let remaining = int.max(0, buffer.remaining - size)
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}

pub fn split(buffer: Buffer, bytes: Int) -> #(BitArray, BitArray) {
  case buffer.data {
    <<partition:bytes-size(bytes), rest:bits>> -> #(partition, rest)
    _ -> #(buffer.data, <<>>)
  }
}
