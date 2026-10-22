struct Item;
int item_open(int mode, struct Item **out);
struct Item *item_new(int mode);
int item_close(struct Item *item);
int item_live(void);
int optional_tail(int value, char **tail);
int visit(int count, int (*callback)(void *ctx, int value), void *context);
long long_value(long value);
struct Model { char tag; long value; void *pointer; };
