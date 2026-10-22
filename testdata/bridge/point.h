#ifndef MOONBIND_POINT_H
#define MOONBIND_POINT_H
struct Point { int x; int y; };
static inline struct Point point_add(struct Point a, struct Point b) {
  struct Point result = {a.x + b.x, a.y + b.y};
  return result;
}
static inline int point_sum(struct Point p) { return p.x + p.y; }
static inline int twice(int value) { return value * 2; }
#endif
