#include "api.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
struct Resource { int mode; int failed_once; };
static int live, closes;
size_t transform(void *dst, size_t cap, const void *src, size_t len, int mode) {
  if(mode == 1) return cap + 1; /* malformed length without writing out of bounds */
  if(mode == 2) return ((size_t)1 << 40); /* wider than MoonBit Int */
  if(len > cap || mode == 3) return (size_t)-1;
  if(len) memcpy(dst, src, len);
  return len;
}
unsigned int failed(size_t code) { return code == (size_t)-1; }
unsigned int transform32(void *dst, unsigned int cap, const void *src, unsigned int len) {
  if(len > cap) return UINT_MAX;
  if(len) memcpy(dst, src, len);
  return len;
}
int failed32(unsigned int code) { return code == UINT_MAX; }
int resource_open(int mode, struct Resource **out) {
  *out = NULL;
  if(mode == 3) return 7;
  struct Resource *p = malloc(sizeof *p);
  if(!p) return 8;
  p->mode=mode; p->failed_once=0; live++; *out=p;
  return mode == 2 ? 7 : 0;
}
int resource_close(struct Resource *p) {
  closes++;
  if(p->mode == 1 && !p->failed_once) { p->failed_once=1; return 9; }
  free(p); live--; return 0;
}
int resource_release(struct Resource *p) { closes++; free(p); live--; return 9; }
int resource_value(struct Resource *p) { return p->mode; }
int live_count(void) { return live; }
int close_count(void) { return closes; }
