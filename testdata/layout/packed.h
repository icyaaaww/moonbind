// Packing waives the unit check rather than shrinking the unit, and a packed
// record takes no alignment from the declared types of its bitfields.
//
// Expected output from
//   clang -cc1 -triple x86_64-unknown-linux-gnu -fdump-record-layouts-complete
//
//   struct P1   0:0-25 a   3:2-8 b   [sizeof=5, align=1]   #pragma pack(1)
//   struct P2   0:0-25 a   3:2-8 b   [sizeof=6, align=2]   #pragma pack(2)
//   struct P3   0:0-25 a   3:2-8 b   [sizeof=8, align=4]   #pragma pack(4)
//   struct P4   0:0-25 a   3:2-8 b   [sizeof=8, align=4]   #pragma pack(8)
//   struct P5   0:0-25 a   3:2-8 b   [sizeof=5, align=1]   __attribute__((packed))
//   struct P6                        [sizeof=1, align=1]   __attribute__((packed))
//   struct P7   0:0-3 a    0:4-9 b   [sizeof=2, align=1]   #pragma pack(1)
//   struct P8   0:0-3 a    0:4-9 b   [sizeof=2, align=1]   __attribute__((packed))
//   union  P9                        [sizeof=4, align=4]
//   union  P10                       [sizeof=3, align=1]   __attribute__((packed))

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
