// vxcxxexc_lib: libvxcxxexc.so, the C++ library vxcxxexc links (M6 step
// 6f2a): its exceptions are caught in the program, and the program's unwind
// through its frames, running its destructors.

#include "vxcxxexc.h"

int lib_unwound;

namespace {
struct lib_counted {
  lib_counted() = default;
  lib_counted(const lib_counted &) = delete;
  lib_counted &operator=(const lib_counted &) = delete;
  ~lib_counted() { lib_unwound++; }
};
} // namespace

// Recursive by design: a frame for each level for the throw to unwind.
int lib_throw(int depth) { // NOLINT(misc-no-recursion)
  const lib_counted c;
  if (depth == 0) throw lib_error("thrown in libvxcxxexc.so", 0);
  return lib_throw(depth - 1) + 1;
}

int lib_call(int (*fn)(int), int x) {
  const lib_counted c;
  return fn(x) + 1;
}
