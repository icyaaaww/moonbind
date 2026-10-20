//! The smallest complete program that uses generated bindings.
//!
//! Every line below is an ordinary MoonBit line. There is no `extern`, no
//! offset and no size in this file — those live in `../greet/bindings.mbt`,
//! which `moonbind` wrote from `../greet/greet.h`. When the header changes,
//! only that file is regenerated.
//!
//! Run it with `moon run examples/greet-demo --target native`.

///|
fn main raise {
  // A string that comes back from C is C's memory, so it crosses as a
  // `VoidPtr`; `copy_cstr` copies it into `Bytes` that MoonBit owns. Doing
  // the copy immediately is the point: the pointer is only good until the
  // next call into the library.
  let version = @utf8.decode(@greet.copy_cstr(@greet.greet_version()))
  println("library says: \{version}")

  let ctx = @greet.greet_open(@utf8.encode("moonbind"))
  // `greet_open` returns a pointer, and C's failure value for a pointer is
  // NULL. The generated `is_null` answers that question directly; there is no
  // `Option` in between to blur it.
  if ctx.is_null() {
    println("could not open a context")
    return
  }

  println(
    "greet_hello returned \{@greet.greet_hello(ctx, @utf8.encode("Tycho"))}",
  )
  println(
    "greet_hello returned \{@greet.greet_hello(ctx, @utf8.encode("Kepler"))}",
  )

  // `greet_count` takes the context and answers an `int`, which is `Int32`
  // here — the same 32 bits the header promised, not a MoonBit `Int` that
  // happens to be the same width on today's backend.
  println("count: \{@greet.greet_count(ctx)}")

  // Passing NULL where a context is expected is a C mistake, and the
  // generated handle can say it out loud instead of pretending.
  println("null count: \{@greet.greet_count(@greet.GreetCtxPtr::null())}")

  @greet.greet_close(ctx)
}
