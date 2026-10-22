#include "api.h"
#include <stdlib.h>
struct Item { int mode; };
static int live;
struct Item *item_new(int mode) { struct Item *p = malloc(sizeof *p); if(p) { p->mode=mode; live++; } return p; }
int item_open(int mode, struct Item **out) { *out = mode==2 ? NULL : item_new(mode); return mode ? 7 : 0; }
int item_close(struct Item *p) { if(!p) return 0; int mode=p->mode; free(p); live--; return mode==3 ? 9 : 0; }
int item_live(void) { return live; }
int optional_tail(int value, char **tail) { return tail == NULL ? value : -1; }
int visit(int count, int (*callback)(void *, int), void *context) { for(int i=0;i<count;i++) { int code=callback(context,i); if(code) return code; } return 0; }
long long_value(long value) { return value; }
