///|
fn main raise {
  // Constructor arguments follow declaration order, depth first.
  let result = @lib.with_mb_Packet_new(-3, 255U, 10, 20, 30, 0, fn(p) {
    assert_eq(@lib.mb_Packet_get_point__x(p), -3)
    let q = @lib.packet_step(p)
    assert_false(q.is_null())
    assert_eq(@lib.mb_Packet_get_samples__1(q), 25)
    assert_eq(@lib.mb_Packet_get_mode(q), 1)
    assert_eq(@lib.packet_total(q), 320)
    @lib.mb_Packet_set_point__x(q, -32768)
    assert_eq(@lib.mb_Packet_get_point__x(q), -32768)
    @lib.mb_Packet_free(q)
    320
  })
  assert_eq(result, Some(320))
  println("PASS nested record, fixed array, enum, signed narrow field, scoped release")
}
