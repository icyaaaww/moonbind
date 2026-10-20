/* The C side of examples/greet/greet.h. Kept small on purpose: the point of
 * the example is the boundary, not the greetings.
 *
 * Built as a `native-stub` of the bindings package, which is how a real
 * project would ship the library it is binding — as source, compiled into the
 * same binary.
 */

#include <stddef.h>
#include <stdio.h>

#include "greet.h"

struct greet_ctx {
  char name[64];
  int count;
};

static struct greet_ctx the_ctx;

const char *greet_version(void) {
  return "greet 1.0";
}

greet_ctx *greet_open(const char *name) {
  size_t i = 0;
  if (name == NULL) {
    return NULL;
  }
  while (name[i] != '\0' && i + 1 < sizeof the_ctx.name) {
    the_ctx.name[i] = name[i];
    i++;
  }
  the_ctx.name[i] = '\0';
  the_ctx.count = 0;
  return &the_ctx;
}

int greet_hello(greet_ctx *ctx, const char *who) {
  if (ctx == NULL || who == NULL) {
    return -1;
  }
  printf("%s greets %s\n", ctx->name, who);
  return ++ctx->count;
}

/* Never reached from MoonBit: the generator refuses this signature because
 * the struct would arrive as a pointer to a box. It is here so that
 * `moonbind --report` has something to report, and so the header shows what a
 * refusal looks like. */
int greet_point_sum(struct greet_point where) {
  printf("greet_point_sum saw x=%d y=%d\n", where.x, where.y);
  return where.x + where.y;
}

int greet_count(greet_ctx *ctx) {
  return ctx == NULL ? -1 : ctx->count;
}

void greet_close(greet_ctx *ctx) {
  if (ctx != NULL) {
    ctx->count = 0;
  }
}
