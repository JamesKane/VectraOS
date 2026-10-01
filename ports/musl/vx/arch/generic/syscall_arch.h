// syscall_arch.h: VectraOS's, replacing musl's arch/<arch>/syscall_arch.h
// (ADR-0007). It is first on musl's include path; musl's tree is unchanged.
//
// musl asks for kernel services by Linux system-call number, through these
// seven functions. Here each is a call into the vx back end, which carries
// the request out with VectraOS's own calls and servers (docs/01 §9).
// Numbers and results are Linux's: a result in [-4095, -1] is -errno.
//
// This file is compiled as part of musl, so it keeps to musl's C99.

#define __SYSCALL_LL_E(x) (x)
#define __SYSCALL_LL_O(x) (x)

hidden long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);

static __inline long __syscall0(long n) { return __vx_syscall(n, 0, 0, 0, 0, 0, 0); }
static __inline long __syscall1(long n, long a1) { return __vx_syscall(n, a1, 0, 0, 0, 0, 0); }
static __inline long __syscall2(long n, long a1, long a2) { return __vx_syscall(n, a1, a2, 0, 0, 0, 0); }
static __inline long __syscall3(long n, long a1, long a2, long a3) {
  return __vx_syscall(n, a1, a2, a3, 0, 0, 0);
}
static __inline long __syscall4(long n, long a1, long a2, long a3, long a4) {
  return __vx_syscall(n, a1, a2, a3, a4, 0, 0);
}
static __inline long __syscall5(long n, long a1, long a2, long a3, long a4, long a5) {
  return __vx_syscall(n, a1, a2, a3, a4, a5, 0);
}
static __inline long __syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
  return __vx_syscall(n, a1, a2, a3, a4, a5, a6);
}

// No vDSO: clock_gettime is a call like any other.
#define IPC_64 0
