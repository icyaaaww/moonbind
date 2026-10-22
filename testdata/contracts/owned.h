#ifndef MOONBIND_OWNED_H
#define MOONBIND_OWNED_H
struct Resource;
struct Resource *resource_new(int fail);
void resource_free(struct Resource *p);
int resource_live(void);
int resource_value(struct Resource *p);
unsigned int checksum(const unsigned char *data, unsigned int length);
const char *borrowed_text(int null_result);
void mutate_text(void);
#endif
