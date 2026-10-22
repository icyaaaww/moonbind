#include "owned.h"
#include <stdlib.h>
struct Resource { int value; };
static int live = 0;
static char text[] = "hello";
struct Resource *resource_new(int fail) {
  if (fail) return NULL;
  struct Resource *p = malloc(sizeof(*p));
  if (p) { p->value = 42; live++; }
  return p;
}
void resource_free(struct Resource *p) { if (p) { live--; free(p); } }
int resource_live(void) { return live; }
int resource_value(struct Resource *p) { return p->value; }
unsigned int checksum(const unsigned char *data, unsigned int length) {
  unsigned int result = 0;
  for (unsigned int i = 0; i < length; i++) result += data[i];
  return result;
}
const char *borrowed_text(int null_result) { return null_result ? NULL : text; }
void mutate_text(void) { text[0] = 'j'; }
