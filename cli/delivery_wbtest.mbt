///|
test "delivery configuration and CLI preserve contracts exactly" {
  let args = config_args(
    "{\"header\":\"api.h\",\"output_buffers\":{\"copy\":\"dst:cap:src:len:failed:64\"},\"managed_outputs\":{\"open\":\"close:0:retained\"}}",
    ".",
  )
  match parse_args(args) {
    Run(o) => {
      assert_eq(o.output_buffers.get("copy"), Some("dst:cap:src:len:failed:64"))
      assert_eq(o.managed_outputs.get("open"), Some("close:0:retained"))
    }
    _ => abort("delivery flags rejected")
  }
}

///|
test "delivery flags reject missing or malformed assignments" {
  for flag in ["--output-buffer", "--managed-output"] {
    assert_true(parse_args(["api.h", flag]) is Bad(_))
    assert_true(parse_args(["api.h", flag, "missing_assignment"]) is Bad(_))
  }
}
