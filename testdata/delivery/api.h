#include <stddef.h>
struct Resource;
size_t transform(void *dst, size_t capacity, const void *src, size_t length, int mode);
unsigned int transform32(void *dst, unsigned int capacity, const void *src, unsigned int length);
unsigned int failed(size_t code);
int failed32(unsigned int code);
int resource_open(int mode, struct Resource **out);
int resource_close(struct Resource *value);
int resource_release(struct Resource *value);
int resource_value(struct Resource *value);
int live_count(void);
int close_count(void);
