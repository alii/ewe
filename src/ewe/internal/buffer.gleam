import gleam/bit_array
import gleam/int

pub type Buffer {
  Buffer(data: BitArray, remaining: Int)
}

pub fn new(initial: BitArray) -> Buffer {
  Buffer(initial, 0)
}

pub fn sized(buffer: Buffer, size: Int) -> Buffer {
  Buffer(buffer.data, size)
}

pub fn empty() -> Buffer {
  Buffer(<<>>, 0)
}

pub fn append(buffer: Buffer, data: BitArray) -> Buffer {
  let remaining = int.max(0, buffer.remaining - bit_array.byte_size(data))
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}

pub fn append_size(buffer: Buffer, data: BitArray, size: Int) -> Buffer {
  let remaining = int.max(0, buffer.remaining - size)
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}
