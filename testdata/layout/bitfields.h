// Bitfields that fit or do not fit inside the unit of their own declared type.
//
// Expected output from
//   clang -cc1 -triple x86_64-unknown-linux-gnu -fdump-record-layouts-complete
// (identical on aarch64-unknown-linux-gnu and on wasm32-unknown-unknown):
//
//   struct F1   0:0-25 a   4:0-6 b   [sizeof=8, align=4]
//   struct F2   0:0-25 a   0:26-29 b [sizeof=4, align=4]
//   struct F3   0:0-3 a    1:0-5 b   [sizeof=2, align=1]
//   struct F4   0:0-3 a    0:4-9 b   [sizeof=4, align=4]
//   struct F5   0:0-3 a    2:0-13 b  [sizeof=4, align=2]
//   struct F6   0:0-3 a    0:4-10 b  [sizeof=2, align=2]
//   struct F7   0:0-7 a    1:0-8 b   2:1-15 c [sizeof=4, align=4]
//   struct F8   0:0-2 a    0:3-42 b  [sizeof=8, align=8]
//   struct F9   0:0-3 a    4:0-29 b  [sizeof=8, align=4]
//   struct F10  0:0-8 a    2:0-8 b   [sizeof=4, align=2]

struct F1 { unsigned a : 26; unsigned b : 7; };
struct F2 { unsigned a : 26; unsigned b : 4; };
struct F3 { unsigned char a : 4; unsigned char b : 6; };
struct F4 { unsigned char a : 4; unsigned b : 6; };
struct F5 { unsigned char a : 4; unsigned short b : 14; };
struct F6 { unsigned char a : 4; unsigned short b : 7; };
struct F7 { unsigned a : 8; unsigned b : 9; unsigned c : 15; };
struct F8 { int a : 3; long long b : 40; };
struct F9 { unsigned char a : 4; unsigned b : 30; };
struct F10 { unsigned short a : 9; unsigned short b : 9; };
