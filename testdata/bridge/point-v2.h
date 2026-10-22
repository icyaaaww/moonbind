#ifndef MOONBIND_POINT_H
#define MOONBIND_POINT_H
struct Point { long x; int y; int z; };
static inline struct Point point_add(struct Point a, struct Point b) {
  struct Point result = {a.x + b.x, a.y + b.y, a.z + b.z};
  return result;
}
static inline int point_sum(struct Point p) { return (int)p.x + p.y + p.z; }
static inline int twice(int value) { return value * 2; }
#endif
