import gleam/bit_array
import gleam/int

/// Represents a buffer of data.
/// 
pub type Buffer {
  Buffer(data: BitArray, remaining: Int)
}

/// Creates a new buffer with the given initial data.
/// 
pub fn new(initial: BitArray) -> Buffer {
  Buffer(initial, 0)
}

/// Creates a new buffer with the given initial data and remaining bytes to be 
/// read.
/// 
pub fn new_sized(initial: BitArray, size: Int) {
  Buffer(initial, size)
}

/// Creates a new empty buffer.
/// 
pub fn empty() -> Buffer {
  Buffer(<<>>, 0)
}

/// Adjusts remaining bytes to be read.
/// 
pub fn sized(buffer: Buffer, size: Int) -> Buffer {
  Buffer(buffer.data, size)
}

/// Appends the given data to the buffer.
/// 
pub fn append(buffer: Buffer, data: BitArray) -> Buffer {
  let remaining = int.max(0, buffer.remaining - bit_array.byte_size(data))
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}

/// Appends the given data to the buffer with calculated data size.
/// 
pub fn append_size(buffer: Buffer, data: BitArray, size: Int) -> Buffer {
  let remaining = int.max(0, buffer.remaining - size)
  Buffer(<<buffer.data:bits, data:bits>>, remaining)
}

/// Splits the buffer into two parts, the first part is the given number of 
/// bytes and the second part is the remaining bytes.
/// 
pub fn split(buffer: Buffer, bytes: Int) -> #(BitArray, BitArray) {
  case buffer.data {
    <<partition:bytes-size(bytes), rest:bits>> -> #(partition, rest)
    _ -> #(buffer.data, <<>>)
  }
}
