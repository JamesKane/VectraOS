// vxcxxexc: C++ exceptions on the native target (M6 step 6f2a, ADR-0033
// section 2a stage 3), the vxcxxexc scenario's (tests/qemu/vxcxxexc.ndb):
// libc++abi with LLVM's libunwind, which finds the unwind tables through
// libvx (LLVM patch 0021). Thrown and caught across frames, with
// destructors run; libc++'s own throws; a throw in a shared library caught
// here, and one from here unwinding through that library's frames; an
// exception carried to another thread and thrown again there. With the
// argument uncaught it throws and catches nothing; with thread, a C11
// thread's start function throws, which unwinds into libvx's frames: both
// end in std::terminate. vxcxxexcs is the same, linked statically, the
// library's code compiled in. Each check prints a line only when it fails;
// the last line counts them.

#include <cstdio>
#include <cstring>
#include <exception>
#include <stdexcept>
#include <string>
#include <thread>
#include <threads.h>
#include <typeinfo>
#include <vector>

#include "vxcxxexc.h"
#ifdef VXCXXEXC_STATIC
#include "vxcxxexc_lib.cpp" // vxcxxexcs: one static program, the library's code its own
#endif

namespace {

int checks, failures;

void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  std::printf("vxcxxexc: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

int unwound; // the program's destructors run by an unwind

struct counted {
  counted() = default;
  counted(const counted &) = delete;
  counted &operator=(const counted &) = delete;
  ~counted() { unwound++; }
};

// Recursive by design: a frame for each level for the throw to unwind.
[[gnu::noinline]] int deep(int depth) { // NOLINT(misc-no-recursion)
  const counted c;
  if (depth == 0) throw std::runtime_error("deep");
  return deep(depth - 1) + 1;
}

int throws_here(int x) {
  const counted c;
  if (x > 0) throw std::invalid_argument("from the program, through the library");
  return x;
}

int starts_and_throws(void * /*arg*/) { throw std::runtime_error("vxcxxexc: thrown from a thread's start"); }

} // namespace

// An exception out of main is what the uncaught and thread cases are for, and
// a failure anywhere else: std::terminate ends the test either way.
int main(int argc, char **argv) { // NOLINT(bugprone-exception-escape)
  if (argc > 1 && std::strcmp(argv[1], "uncaught") == 0) {
    std::printf("vxcxxexc: throwing, uncaught\n");
    std::fflush(stdout);
    throw std::runtime_error("vxcxxexc: boom");
  }
  if (argc > 1 && std::strcmp(argv[1], "thread") == 0) {
    std::printf("vxcxxexc: a thread's start throws\n");
    std::fflush(stdout);
    thrd_t t;
    try {
      if (thrd_create(&t, starts_and_throws, nullptr) == thrd_success) thrd_join(t, nullptr);
    } catch (...) {
      std::printf("vxcxxexc: FAILED: caught on the joining thread\n");
    }
    return 1;
  }

  std::printf("vxcxxexc: hello\n");
  // Across the program's own frames, destructors run on the way.
  try {
    deep(3);
    CHECK(false);
  } catch (const std::runtime_error &e) {
    CHECK(std::strcmp(e.what(), "deep") == 0);
  }
  CHECK(unwound == 4);
  // Caught by a base class, and thrown again.
  try {
    try {
      deep(0);
    } catch (const std::exception &) {
      throw;
    }
  } catch (const std::runtime_error &e) {
    CHECK(typeid(e) == typeid(std::runtime_error));
  }
  // libc++'s own throws.
  try {
    const std::vector<int> v;
    CHECK(v.at(1) == 0 && false);
  } catch (const std::out_of_range &) {
    CHECK(true);
  }
  try {
    CHECK(std::stoi("not a number") == 0 && false);
  } catch (const std::invalid_argument &) {
    CHECK(true);
  }
  // Thrown in a shared library, caught here, its destructors run.
  try {
    lib_throw(2);
    CHECK(false);
  } catch (const lib_error &e) {
    CHECK(e.depth() == 0 && std::strcmp(e.what(), "thrown in libvxcxxexc.so") == 0);
  }
  CHECK(lib_unwound == 3);
  // Thrown here, through the library's frame, caught here again.
  unwound = lib_unwound = 0;
  try {
    lib_call(throws_here, 1);
    CHECK(false);
  } catch (const std::invalid_argument &) {
    CHECK(unwound == 1 && lib_unwound == 1);
  }
  // An exception carried to another thread and thrown there.
  std::exception_ptr carried;
  try {
    deep(1);
  } catch (...) {
    carried = std::current_exception();
  }
  bool rethrown = false;
  std::thread t([&] {
    try {
      std::rethrow_exception(carried);
    } catch (const std::runtime_error &e) {
      rethrown = std::strcmp(e.what(), "deep") == 0;
    }
  });
  t.join();
  CHECK(rethrown);
  // Each thread unwinds on its own: four at once.
  int caught[4] = {};
  std::vector<std::thread> ts;
  ts.reserve(4);
  for (int i = 0; i < 4; i++)
    ts.emplace_back([i, &caught] {
      for (int k = 0; k < 50; k++) try {
          lib_throw(i);
        } catch (const lib_error &) {
          caught[i]++;
        }
    });
  for (auto &th : ts) th.join();
  CHECK(caught[0] == 50 && caught[1] == 50 && caught[2] == 50 && caught[3] == 50);

  std::printf("vxcxxexc: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
