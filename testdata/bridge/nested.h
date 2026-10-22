#ifndef MOONBIND_NESTED_H
#define MOONBIND_NESTED_H
enum Mode { MODE_IDLE = 0, MODE_ACTIVE = 1 };
struct Inner { short x; unsigned char flag; };
struct Packet { struct Inner point; int samples[3]; enum Mode mode; };
static inline struct Packet packet_step(struct Packet p) {
  p.point.x += 2; p.samples[1] += 5; p.mode = MODE_ACTIVE; return p;
}
static inline int packet_total(struct Packet p) {
  return p.point.x + p.point.flag + p.samples[0] + p.samples[1] + p.samples[2] + p.mode;
}
#endif
