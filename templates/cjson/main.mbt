///|
fn main raise {
  let count = @lib.with_cJSON_CreateArray(fn(array) {
    assert_eq(@lib.cJSON_GetArraySize(array), 0)
    0
  })
  assert_eq(count, Some(0))
  assert_eq(@lib.cJSON_Version_bytes(), Some(b"1.7.19"))
  println("PASS cJSON 1.7.19: owned array, size and copied version")
}
