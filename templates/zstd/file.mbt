///|
fn main raise {
  let args = @env.args()
  if args.length() != 4 || (args[1] != "compress" && args[1] != "decompress") {
    raise Failure("Usage: moon run file --target native -- compress|decompress INPUT OUTPUT (new output path required)")
  }
  if @fs.path_exists(args[3]) { raise Failure("Output already exists; choose a new path") }
  // This example buffers the input file in memory; use streaming for large files.
  let input = @fs.read_file_to_bytes(args[2])
  if input.length() > 67108864 { raise Failure("Input exceeds 64 MiB; use a streaming implementation") }
  let result = if args[1] == "compress" {
    let bound = @lib.zstd_compress_bound(input.length().to_uint64())
    if @lib.zstd_is_error(bound) != 0U || bound > 67108864UL { raise Failure("Compression output bound exceeds 64 MiB") }
    @lib.zstd_compress_bytes(input, bound.to_int(), 3)
  } else {
    @lib.zstd_decompress_bytes(input, 67108864)
  }
  let output = match result { Ok(b) => b; Err(_) => raise Failure("Codec failed: input corrupt/truncated or output capacity exceeded") }
  @fs.write_bytes_to_file(args[3], output)
  println("Wrote " + output.length().to_string() + " bytes")
}
