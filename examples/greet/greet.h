/* A header written small enough to read in one screen.
 *
 * It exists to show what `moonbind` does with the awkward parts of a C
 * interface: a type that is only ever named, never defined; a string going
 * in; a string coming back; a status code that is an `int` in the header and
 * `Int32` here; and one function that the generator deliberately refuses.
 *
 * The implementation is greet.c, next to this file.
 */

typedef struct greet_ctx greet_ctx;

struct greet_point {
  int x;
  int y;
};

/* A version string. `moonbind` gives this back as an opaque `VoidPtr`
 * because the memory belongs to C; `copy_cstr` in the generated package
 * copies it into a `Bytes` MoonBit owns before the next call. */
const char *greet_version(void);

/* Open a context. The caller owns it until `greet_close`. */
greet_ctx *greet_open(const char *name);

/* Greet `who` through `ctx` and return how many greetings have gone through
 * it. The `const char *` goes in as `Bytes`. */
int greet_hello(greet_ctx *ctx, const char *who);

/* Sum a point's coordinates. This one is deliberately passed by value, and
 * deliberately left out of the bindings: MoonBit hands every record to C by
 * reference, so `where` would arrive as a pointer to a box and the addition
 * would read a tag and a length instead of `x` and `y`. `moonbind` refuses
 * the function and reports why, rather than write a call that returns
 * nonsense. */
int greet_point_sum(struct greet_point where);

/* How many greetings went through `ctx`, or -1 if it is NULL. */
int greet_count(greet_ctx *ctx);

void greet_close(greet_ctx *ctx);
