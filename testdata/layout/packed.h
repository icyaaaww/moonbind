// Packing waives the unit check rather than shrinking the unit, and a packed
// record takes no alignment from the declared types of its bitfields.
//
// Expected output from
//   clang -cc1 -triple x86_64-unknown-linux-gnu -fdump-record-layouts-complete
// in declaration order:
//
//   struct P1   0:0-25 a   3:2-8 b   [sizeof=5, align=1]
//   struct P7   0:0-3 a    0:4-9 b   [sizeof=2, align=1]
//   struct P2   0:0-25 a   3:2-8 b   [sizeof=6, align=2]
//   struct P3   0:0-25 a   3:2-8 b   [sizeof=8, align=4]
//   struct P4   0:0-25 a   3:2-8 b   [sizeof=8, align=4]
//   struct P5   0:0-25 a   3:2-8 b   [sizeof=5, align=1]
//   struct P6   0:0-2 a              [sizeof=1, align=1]
//   struct P8   0:0-3 a    0:4-9 b   [sizeof=2, align=1]
//   union  P9   0 c        0:0-19 a   [sizeof=4, align=4]
//   union  P10  0 c        0:0-19 a   [sizeof=3, align=1]
//
// P1 through P5 all put `b` at bit 26 — packing removes the unit check, so
// nothing pushes it to bit 32 — and differ only in how far the size is
// rounded up: 5 bytes at pack(1), 6 at pack(2), 8 from pack(4) on.
// P6 shows that a packed record takes no alignment from a bitfield's declared
// type: one bit of a 4-byte type costs one byte. P7 and P8 show that two
// `unsigned char` bitfields pack into a single byte whether the packing came
// from the pragma or from the attribute.

#pragma pack(1)
struct P1 { unsigned a : 26; unsigned b : 7; };
struct P7 { unsigned char a : 4; unsigned char b : 6; };
#pragma pack(2)
struct P2 { unsigned a : 26; unsigned b : 7; };
#pragma pack(4)
struct P3 { unsigned a : 26; unsigned b : 7; };
#pragma pack(8)
struct P4 { unsigned a : 26; unsigned b : 7; };
#pragma pack()
struct __attribute__((packed)) P5 { unsigned a : 26; unsigned b : 7; };
struct __attribute__((packed)) P6 { unsigned a : 3; };
struct __attribute__((packed)) P8 { unsigned char a : 4; unsigned char b : 6; };
union P9 { char c; unsigned a : 20; };
union __attribute__((packed)) P10 { char c; unsigned a : 20; };
