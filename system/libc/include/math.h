// SPDX-License-Identifier: BSD-3-Clause

// <math.h> for C programs on croi (M6c, system/libc/math): what our libm
// has, from C23 §7.12. The exact functions round correctly; exp, exp2,
// log, log2, log10, sin and cos are within an ulp of the true value; the
// float versions are the double ones rounded. No long double functions yet.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define M_PI 3.14159265358979323846
#define M_E 2.7182818284590452354
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x) __builtin_signbit(x)
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4
#define fpclassify(x) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x)
#define isnormal(x) __builtin_isnormal(x)
#define isgreater(x, y) __builtin_isgreater(x, y)
#define isgreaterequal(x, y) __builtin_isgreaterequal(x, y)
#define isless(x, y) __builtin_isless(x, y)
#define islessequal(x, y) __builtin_islessequal(x, y)
#define islessgreater(x, y) __builtin_islessgreater(x, y)
#define isunordered(x, y) __builtin_isunordered(x, y)
typedef float float_t;
typedef double double_t;

double floor(double x);
double ceil(double x);
double trunc(double x);
double round(double x);
double roundeven(double x);
double rint(double x);
double nearbyint(double x);
double fabs(double x);
double sqrt(double x);
double exp(double x);
double exp2(double x);
double log(double x);
double log2(double x);
double log10(double x);
double sin(double x);
double cos(double x);
float floorf(float x);
float ceilf(float x);
float truncf(float x);
float roundf(float x);
float roundevenf(float x);
float rintf(float x);
float nearbyintf(float x);
float fabsf(float x);
float sqrtf(float x);
float expf(float x);
float exp2f(float x);
float logf(float x);
float log2f(float x);
float log10f(float x);
float sinf(float x);
float cosf(float x);
double copysign(double x, double y);
double fmod(double x, double y);
double remainder(double x, double y);
float copysignf(float x, float y);
float fmodf(float x, float y);
float remainderf(float x, float y);
double fma(double x, double y, double z);
float fmaf(float x, float y, float z);
double ldexp(double x, int n);
double scalbn(double x, int n);
double frexp(double x, int *e);
double modf(double x, double *i);

#ifdef __cplusplus
}
#endif
