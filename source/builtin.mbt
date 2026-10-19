//! Built-in replacements for the C standard headers.
//!
//! A binder is usually pointed at a third-party header that includes
//! `<stdint.h>` and friends. Shipping replacements means a run does not
//! depend on a C toolchain being installed, and it keeps the declaration
//! graph small: the real `<stdio.h>` on glibc pulls in hundreds of internal
//! declarations that no binding uses.
//!
//! The replacements are deliberately conservative. They contain only what a
//! header normally needs to compile, they never define compiler intrinsics,
//! and they are selected by the same predefined macros (`_WIN64`,
//! `__LP64__`, `__wasm32__`) that a real compiler would set, so `long` and
//! `size_t` come out with the right width.

///|
/// | Text of a built-in header, or `None` when the name is not provided.
pub fn builtin_header(name : String) -> String? {
  match normalize_path(name) {
    "stddef.h" => Some(stddef_h)
    "stdint.h" => Some(stdint_h)
    "stdbool.h" => Some(stdbool_h)
    "stdarg.h" => Some(stdarg_h)
    "limits.h" => Some(limits_h)
    "stdint" => Some(stdint_h)
    "stdio.h" => Some(stdio_h)
    "stdlib.h" => Some(stdlib_h)
    "string.h" => Some(string_h)
    "math.h" => Some(math_h)
    "time.h" => Some(time_h)
    "errno.h" => Some(errno_h)
    "assert.h" => Some(assert_h)
    "ctype.h" => Some(ctype_h)
    "float.h" => Some(float_h)
    "stddef" => Some(stddef_h)
    "stdbool" => Some(stdbool_h)
    "stdarg" => Some(stdarg_h)
    "stdio" => Some(stdio_h)
    "stdlib" => Some(stdlib_h)
    "string" => Some(string_h)
    "time" => Some(time_h)
    "errno" => Some(errno_h)
    "assert" => Some(assert_h)
    _ => None
  }
}

///|
/// | Every header name this build provides, in sorted order. The CLI lists
/// these under `moonbind builtins`.
pub fn builtin_names() -> Array[String] {
  [
    "assert.h", "ctype.h", "errno.h", "float.h", "limits.h", "math.h", "stdarg.h",
    "stdbool.h", "stddef.h", "stdint.h", "stdio.h", "stdlib.h", "string.h", "time.h",
  ]
}

// Sizes differ between the Win64 ILP32 `long` and the LP64 Unix model, so
// `long`-based typedefs are conditional. `long long` is 64 bits everywhere.

///|
let stddef_h =
  #|#ifndef __MOONBIND_STDDEF_H
  #|#define __MOONBIND_STDDEF_H
  #|typedef int wchar_t;
  #|#if defined(_WIN64)
  #|typedef unsigned long long size_t;
  #|typedef long long ptrdiff_t;
  #|typedef long long ssize_t;
  #|typedef long long intptr_t;
  #|typedef unsigned long long uintptr_t;
  #|#elif defined(__LP64__) || defined(__aarch64__) || defined(__wasm64__)
  #|typedef unsigned long size_t;
  #|typedef long ptrdiff_t;
  #|typedef long ssize_t;
  #|typedef long intptr_t;
  #|typedef unsigned long uintptr_t;
  #|#else
  #|typedef unsigned int size_t;
  #|typedef int ptrdiff_t;
  #|typedef int ssize_t;
  #|typedef int intptr_t;
  #|typedef unsigned int uintptr_t;
  #|#endif
  #|#define NULL ((void*)0)
  #|#ifndef offsetof
  #|#define offsetof(type, member) ((size_t)0)
  #|#endif
  #|#endif

///|
let stdint_h =
  #|#ifndef __MOONBIND_STDINT_H
  #|#define __MOONBIND_STDINT_H
  #|typedef signed char int8_t;
  #|typedef unsigned char uint8_t;
  #|typedef short int16_t;
  #|typedef unsigned short uint16_t;
  #|typedef int int32_t;
  #|typedef unsigned int uint32_t;
  #|#if defined(_WIN64)
  #|typedef long long int64_t;
  #|typedef unsigned long long uint64_t;
  #|typedef long long int64_t;
  #|#else
  #|typedef long int64_t;
  #|typedef unsigned long uint64_t;
  #|#endif
  #|typedef signed char int_least8_t;
  #|typedef unsigned char uint_least8_t;
  #|typedef short int_least16_t;
  #|typedef unsigned short uint_least16_t;
  #|typedef int int_least32_t;
  #|typedef unsigned int uint_least32_t;
  #|typedef long long int_least64_t;
  #|typedef unsigned long long uint_least64_t;
  #|typedef signed char int_fast8_t;
  #|typedef unsigned char uint_fast8_t;
  #|typedef short int_fast16_t;
  #|typedef unsigned short uint_fast16_t;
  #|typedef int int_fast32_t;
  #|typedef unsigned int uint_fast32_t;
  #|typedef long long int_fast64_t;
  #|typedef unsigned long long uint_fast64_t;
  #|#if defined(_WIN64)
  #|typedef long long intptr_t;
  #|typedef unsigned long long uintptr_t;
  #|#elif defined(__LP64__) || defined(__aarch64__)
  #|typedef long intptr_t;
  #|typedef unsigned long uintptr_t;
  #|#else
  #|typedef int intptr_t;
  #|typedef unsigned int uintptr_t;
  #|#endif
  #|typedef long long intmax_t;
  #|typedef unsigned long long uintmax_t;
  #|#define INT8_MIN (-128)
  #|#define INT8_MAX 127
  #|#define UINT8_MAX 255
  #|#define INT16_MIN (-32768)
  #|#define INT16_MAX 32767
  #|#define UINT16_MAX 65535
  #|#define INT32_MIN (-2147483647 - 1)
  #|#define INT32_MAX 2147483647
  #|#define UINT32_MAX 4294967295U
  #|#define INT64_MIN (-9223372036854775807LL - 1)
  #|#define INT64_MAX 9223372036854775807LL
  #|#define UINT64_MAX 18446744073709551615ULL
  #|#define INTPTR_MIN (-9223372036854775807LL - 1)
  #|#define INTPTR_MAX 9223372036854775807LL
  #|#define UINTPTR_MAX 18446744073709551615ULL
  #|#endif

///|
let stdbool_h =
  #|#ifndef __MOONBIND_STDBOOL_H
  #|#define __MOONBIND_STDBOOL_H
  #|#ifndef __cplusplus
  #|#define bool _Bool
  #|#define true 1
  #|#define false 0
  #|#endif
  #|#define __bool_true_false_are_defined 1
  #|#endif

///|
let stdarg_h =
  #|#ifndef __MOONBIND_STDARG_H
  #|#define __MOONBIND_STDARG_H
  #|typedef struct __va_list_tag {
  #|  unsigned int gp_offset;
  #|  unsigned int fp_offset;
  #|  void *overflow_arg_area;
  #|  void *reg_save_area;
  #|} va_list[1];
  #|typedef va_list __gnuc_va_list;
  #|#endif

///|
let limits_h =
  #|#ifndef __MOONBIND_LIMITS_H
  #|#define __MOONBIND_LIMITS_H
  #|#define CHAR_BIT 8
  #|#define SCHAR_MIN (-128)
  #|#define SCHAR_MAX 127
  #|#define UCHAR_MAX 255
  #|#define CHAR_MIN (-128)
  #|#define CHAR_MAX 127
  #|#define SHRT_MIN (-32768)
  #|#define SHRT_MAX 32767
  #|#define USHRT_MAX 65535
  #|#define INT_MIN (-2147483647 - 1)
  #|#define INT_MAX 2147483647
  #|#define UINT_MAX 4294967295U
  #|#define LONG_MAX 9223372036854775807L
  #|#define ULONG_MAX 18446744073709551615UL
  #|#define LLONG_MIN (-9223372036854775807LL - 1)
  #|#define LLONG_MAX 9223372036854775807LL
  #|#define ULLONG_MAX 18446744073709551615ULL
  #|#endif

///|
let stdio_h =
  #|#ifndef __MOONBIND_STDIO_H
  #|#define __MOONBIND_STDIO_H
  #|#include <stddef.h>
  #|#include <stdarg.h>
  #|typedef struct _IO_FILE FILE;
  #|typedef long long fpos_t;
  #|#define EOF (-1)
  #|#define SEEK_SET 0
  #|#define SEEK_CUR 1
  #|#define SEEK_END 2
  #|extern FILE *stdin;
  #|extern FILE *stdout;
  #|extern FILE *stderr;
  #|int remove(const char *path);
  #|int rename(const char *oldpath, const char *newpath);
  #|FILE *tmpfile(void);
  #|char *tmpnam(char *s);
  #|int fclose(FILE *stream);
  #|int fflush(FILE *stream);
  #|FILE *fopen(const char *path, const char *mode);
  #|FILE *freopen(const char *path, const char *mode, FILE *stream);
  #|void setbuf(FILE *stream, char *buf);
  #|int setvbuf(FILE *stream, char *buf, int mode, size_t size);
  #|int fprintf(FILE *stream, const char *format, ...);
  #|int printf(const char *format, ...);
  #|int sprintf(char *s, const char *format, ...);
  #|int snprintf(char *s, size_t n, const char *format, ...);
  #|int vfprintf(FILE *stream, const char *format, va_list ap);
  #|int vprintf(const char *format, va_list ap);
  #|int vsprintf(char *s, const char *format, va_list ap);
  #|int vsnprintf(char *s, size_t n, const char *format, va_list ap);
  #|int fscanf(FILE *stream, const char *format, ...);
  #|int scanf(const char *format, ...);
  #|int sscanf(const char *s, const char *format, ...);
  #|int fgetc(FILE *stream);
  #|char *fgets(char *s, int n, FILE *stream);
  #|int fputc(int c, FILE *stream);
  #|int fputs(const char *s, FILE *stream);
  #|int getc(FILE *stream);
  #|int getchar(void);
  #|char *gets(char *s);
  #|int putc(int c, FILE *stream);
  #|int putchar(int c);
  #|int puts(const char *s);
  #|int ungetc(int c, FILE *stream);
  #|size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
  #|size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
  #|int fgetpos(FILE *stream, fpos_t *pos);
  #|int fseek(FILE *stream, long offset, int whence);
  #|int fsetpos(FILE *stream, const fpos_t *pos);
  #|long ftell(FILE *stream);
  #|void rewind(FILE *stream);
  #|void clearerr(FILE *stream);
  #|int feof(FILE *stream);
  #|int ferror(FILE *stream);
  #|void perror(const char *s);
  #|#endif

///|
let stdlib_h =
  #|#ifndef __MOONBIND_STDLIB_H
  #|#define __MOONBIND_STDLIB_H
  #|#include <stddef.h>
  #|typedef struct { int quot; int rem; } div_t;
  #|typedef struct { long quot; long rem; } ldiv_t;
  #|typedef struct { long long quot; long long rem; } lldiv_t;
  #|#define EXIT_SUCCESS 0
  #|#define EXIT_FAILURE 1
  #|#define RAND_MAX 2147483647
  #|double atof(const char *s);
  #|int atoi(const char *s);
  #|long atol(const char *s);
  #|long long atoll(const char *s);
  #|double strtod(const char *s, char **endptr);
  #|float strtof(const char *s, char **endptr);
  #|long double strtold(const char *s, char **endptr);
  #|long strtol(const char *s, char **endptr, int base);
  #|unsigned long strtoul(const char *s, char **endptr, int base);
  #|long long strtoll(const char *s, char **endptr, int base);
  #|unsigned long long strtoull(const char *s, char **endptr, int base);
  #|int rand(void);
  #|void srand(unsigned int seed);
  #|void *malloc(size_t size);
  #|void *calloc(size_t nmemb, size_t size);
  #|void *realloc(void *ptr, size_t size);
  #|void free(void *ptr);
  #|void abort(void);
  #|int atexit(void (*func)(void));
  #|void exit(int status);
  #|void _Exit(int status);
  #|char *getenv(const char *name);
  #|int system(const char *command);
  #|void *bsearch(const void *key, const void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *));
  #|void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *));
  #|int abs(int n);
  #|long labs(long n);
  #|long long llabs(long long n);
  #|div_t div(int numerator, int denominator);
  #|ldiv_t ldiv(long numerator, long denominator);
  #|lldiv_t lldiv(long long numerator, long long denominator);
  #|int mblen(const char *s, size_t n);
  #|int mbtowc(wchar_t *pwc, const char *s, size_t n);
  #|int wctomb(char *s, wchar_t wc);
  #|size_t mbstowcs(wchar_t *dest, const char *src, size_t n);
  #|size_t wcstombs(char *dest, const wchar_t *src, size_t n);
  #|#endif

///|
let string_h =
  #|#ifndef __MOONBIND_STRING_H
  #|#define __MOONBIND_STRING_H
  #|#include <stddef.h>
  #|void *memcpy(void *dest, const void *src, size_t n);
  #|void *memmove(void *dest, const void *src, size_t n);
  #|void *memset(void *s, int c, size_t n);
  #|int memcmp(const void *s1, const void *s2, size_t n);
  #|char *strcpy(char *dest, const char *src);
  #|char *strncpy(char *dest, const char *src, size_t n);
  #|char *strcat(char *dest, const char *src);
  #|char *strncat(char *dest, const char *src, size_t n);
  #|int strcmp(const char *s1, const char *s2);
  #|int strncmp(const char *s1, const char *s2, size_t n);
  #|int strcoll(const char *s1, const char *s2);
  #|size_t strxfrm(char *dest, const char *src, size_t n);
  #|char *strchr(const char *s, int c);
  #|char *strrchr(const char *s, int c);
  #|size_t strcspn(const char *s, const char *reject);
  #|size_t strspn(const char *s, const char *accept);
  #|char *strpbrk(const char *s, const char *accept);
  #|char *strstr(const char *haystack, const char *needle);
  #|char *strtok(char *s, const char *delim);
  #|size_t strlen(const char *s);
  #|char *strerror(int errnum);
  #|char *strdup(const char *s);
  #|char *strndup(const char *s, size_t n);
  #|#endif

///|
let math_h =
  #|#ifndef __MOONBIND_MATH_H
  #|#define __MOONBIND_MATH_H
  #|#define M_E 2.7182818284590452354
  #|#define M_LOG2E 1.4426950408889634074
  #|#define M_LOG10E 0.43429448190325182765
  #|#define M_LN2 0.69314718055994530942
  #|#define M_LN10 2.30258509299404568402
  #|#define M_PI 3.14159265358979323846
  #|#define M_PI_2 1.57079632679489661923
  #|#define M_PI_4 0.78539816339744830962
  #|#define M_1_PI 0.31830988618379067154
  #|#define M_2_PI 0.63661977236758134308
  #|#define M_2_SQRTPI 1.12837916709551257390
  #|#define M_SQRT2 1.41421356237309504880
  #|#define M_SQRT1_2 0.70710678118654752440
  #|#define HUGE_VAL 1e308
  #|#define INFINITY 1e308
  #|#define NAN (0.0f / 0.0f)
  #|typedef float float_t;
  #|typedef double double_t;
  #|double acos(double x);
  #|double asin(double x);
  #|double atan(double x);
  #|double atan2(double y, double x);
  #|double cos(double x);
  #|double sin(double x);
  #|double tan(double x);
  #|double acosh(double x);
  #|double asinh(double x);
  #|double atanh(double x);
  #|double cosh(double x);
  #|double sinh(double x);
  #|double tanh(double x);
  #|double exp(double x);
  #|double exp2(double x);
  #|double expm1(double x);
  #|double frexp(double x, int *exp);
  #|double ldexp(double x, int exp);
  #|double log(double x);
  #|double log10(double x);
  #|double log1p(double x);
  #|double log2(double x);
  #|double logb(double x);
  #|double modf(double x, double *iptr);
  #|double scalbn(double x, int n);
  #|double cbrt(double x);
  #|double fabs(double x);
  #|double hypot(double x, double y);
  #|double pow(double x, double y);
  #|double sqrt(double x);
  #|double erf(double x);
  #|double erfc(double x);
  #|double lgamma(double x);
  #|double tgamma(double x);
  #|double ceil(double x);
  #|double floor(double x);
  #|double nearbyint(double x);
  #|double rint(double x);
  #|long lrint(double x);
  #|long long llrint(double x);
  #|double round(double x);
  #|long lround(double x);
  #|long long llround(double x);
  #|double trunc(double x);
  #|double fmod(double x, double y);
  #|double remainder(double x, double y);
  #|double copysign(double x, double y);
  #|double nextafter(double x, double y);
  #|double fdim(double x, double y);
  #|double fmax(double x, double y);
  #|double fmin(double x, double y);
  #|double fma(double x, double y, double z);
  #|#endif

///|
let time_h =
  #|#ifndef __MOONBIND_TIME_H
  #|#define __MOONBIND_TIME_H
  #|#include <stddef.h>
  #|typedef long long time_t;
  #|typedef long long clock_t;
  #|typedef int clockid_t;
  #|struct tm {
  #|  int tm_sec;
  #|  int tm_min;
  #|  int tm_hour;
  #|  int tm_mday;
  #|  int tm_mon;
  #|  int tm_year;
  #|  int tm_wday;
  #|  int tm_yday;
  #|  int tm_isdst;
  #|};
  #|struct timespec {
  #|  time_t tv_sec;
  #|  long tv_nsec;
  #|};
  #|#define CLOCKS_PER_SEC 1000000
  #|clock_t clock(void);
  #|double difftime(time_t time1, time_t time0);
  #|time_t mktime(struct tm *timeptr);
  #|time_t time(time_t *timer);
  #|char *asctime(const struct tm *timeptr);
  #|char *ctime(const time_t *timer);
  #|struct tm *gmtime(const time_t *timer);
  #|struct tm *localtime(const time_t *timer);
  #|size_t strftime(char *s, size_t maxsize, const char *format, const struct tm *timeptr);
  #|#endif

///|
let errno_h =
  #|#ifndef __MOONBIND_ERRNO_H
  #|#define __MOONBIND_ERRNO_H
  #|int *__errno_location(void);
  #|#define errno (*__errno_location())
  #|#define EPERM 1
  #|#define ENOENT 2
  #|#define ESRCH 3
  #|#define EINTR 4
  #|#define EIO 5
  #|#define ENXIO 6
  #|#define E2BIG 7
  #|#define ENOEXEC 8
  #|#define EBADF 9
  #|#define ECHILD 10
  #|#define EAGAIN 11
  #|#define ENOMEM 12
  #|#define EACCES 13
  #|#define EFAULT 14
  #|#define EBUSY 16
  #|#define EEXIST 17
  #|#define EXDEV 18
  #|#define ENODEV 19
  #|#define ENOTDIR 20
  #|#define EISDIR 21
  #|#define EINVAL 22
  #|#define ENFILE 23
  #|#define EMFILE 24
  #|#define ENOTTY 25
  #|#define EFBIG 27
  #|#define ENOSPC 28
  #|#define ESPIPE 29
  #|#define EROFS 30
  #|#define EMLINK 31
  #|#define EPIPE 32
  #|#define EDOM 33
  #|#define ERANGE 34
  #|#endif

///|
let assert_h =
  #|#ifndef __MOONBIND_ASSERT_H
  #|#define __MOONBIND_ASSERT_H
  #|void __assert_fail(const char *assertion, const char *file, unsigned int line, const char *function);
  #|#ifndef NDEBUG
  #|#define assert(expr) ((expr) ? (void)0 : __assert_fail("assertion failed", "", 0, ""))
  #|#else
  #|#define assert(expr) ((void)0)
  #|#endif
  #|#endif

///|
let ctype_h =
  #|#ifndef __MOONBIND_CTYPE_H
  #|#define __MOONBIND_CTYPE_H
  #|int isalnum(int c);
  #|int isalpha(int c);
  #|int isblank(int c);
  #|int iscntrl(int c);
  #|int isdigit(int c);
  #|int isgraph(int c);
  #|int islower(int c);
  #|int isprint(int c);
  #|int ispunct(int c);
  #|int isspace(int c);
  #|int isupper(int c);
  #|int isxdigit(int c);
  #|int tolower(int c);
  #|int toupper(int c);
  #|#endif

///|
let float_h =
  #|#ifndef __MOONBIND_FLOAT_H
  #|#define __MOONBIND_FLOAT_H
  #|#define FLT_RADIX 2
  #|#define FLT_MANT_DIG 24
  #|#define DBL_MANT_DIG 53
  #|#define FLT_DIG 6
  #|#define DBL_DIG 15
  #|#define FLT_MIN_EXP (-125)
  #|#define DBL_MIN_EXP (-1021)
  #|#define FLT_MAX_EXP 128
  #|#define DBL_MAX_EXP 1024
  #|#define FLT_EPSILON 1.19209290e-07F
  #|#define DBL_EPSILON 2.2204460492503131e-16
  #|#define FLT_MAX 3.40282347e+38F
  #|#define DBL_MAX 1.7976931348623157e+308
  #|#define FLT_MIN 1.17549435e-38F
  #|#define DBL_MIN 2.2250738585072014e-308
  #|#endif
