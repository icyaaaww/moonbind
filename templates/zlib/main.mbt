///|
fn main raise {
  assert_eq(@lib.adler32_buffer(1UL, b"ABC"), 26017991UL)
  assert_eq(@lib.adler32_buffer(1UL, b""), 1UL)
  println("PASS zlib: checksum and empty buffer with derived length")
}
