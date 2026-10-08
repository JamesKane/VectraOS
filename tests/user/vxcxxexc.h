// vxcxxexc.h: what libvxcxxexc.so gives vxcxxexc (M6 step 6f2a, ADR-0033
// section 2a stage 3): exceptions thrown in a shared library, and through it.

#pragma once

#include <stdexcept>

class lib_error : public std::runtime_error {
public:
  lib_error(const char *what, int depth) : std::runtime_error(what), depth_(depth) {}
  [[nodiscard]] int depth() const { return depth_; }

private:
  int depth_;
};

extern int lib_unwound; // the library's destructors run by an unwind

// Throws a lib_error from depth frames down, each frame holding an object
// whose destructor counts in lib_unwound.
int lib_throw(int depth);

// Calls fn(x) under a frame of the library's own, which holds an object too:
// what fn throws unwinds through the library.
int lib_call(int (*fn)(int), int x);
