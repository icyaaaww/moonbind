///|
fn main raise {
  assert_eq(@lib.zstd_version_number(), 10507U)
  for input in [b"", b"MoonBind\x00\xff\x01", Bytes::makei(1048576, i => (i % 251).to_byte())] {
    let bound = @lib.zstd_compress_bound(input.length().to_uint64())
    assert_eq(@lib.zstd_is_error(bound), 0U)
    assert_true(bound <= 67108864UL)
    let packed = match @lib.zstd_compress_bytes(input, bound.to_int(), 3) { Ok(b) => b; Err(_) => abort("compression failed") }
    let restored = @lib.zstd_decompress_bytes(packed, input.length())
    assert_eq(restored, Ok(input))
    if input.length() > 0 { assert_true(@lib.zstd_decompress_bytes(packed, 0) is Err(@lib.BufferCallFailed(_))) }
    let truncated = Bytes::makei(packed.length() - 1, i => packed[i])
    assert_true(@lib.zstd_decompress_bytes(truncated, input.length()) is Err(@lib.BufferCallFailed(_)))
  }
  assert_true(@lib.zstd_compress_bytes(b"abc", 0, 3) is Err(@lib.BufferCallFailed(_)))
  assert_eq(@lib.zstd_compress_bytes(b"abc", -1, 3), Err(@lib.InvalidCapacity(-1)))
  assert_eq(@lib.zstd_decompress_bytes(b"", 67108865), Err(@lib.InvalidCapacity(67108865)))
  assert_eq(@lib.zstd_decompress_bytes(b"", 2147483647), Err(@lib.InvalidCapacity(2147483647)))
  assert_true(@lib.zstd_decompress_bytes(b"not zstd", 100) is Err(@lib.BufferCallFailed(_)))
  println("PASS Zstandard binary/empty/1MiB roundtrip, allocation cap, insufficient capacity and corrupt/truncated input")
}
