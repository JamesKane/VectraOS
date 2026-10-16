// SPDX-License-Identifier: BSD-3-Clause

// Tier 1's C++ floor (M6d): a program built by the *-vectraos clang++
// against libc++, libc++abi and libunwind in tier 1's sysroot, on croi.
// What the Swift runtime takes from them (operator new and delete, guarded
// statics, std::string, hash maps and trees, std::function, pure virtuals,
// hardware_concurrency, __cxa_demangle) and what C++ programs do besides:
// static constructors and destructors, RTTI, threads, a mutex and a
// condition variable, clocks, and exceptions thrown through frames,
// caught by type, rethrown, and std::stoi's out_of_range (strtol's ERANGE).
// Exits 0 if all held.

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cxxabi.h>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <unordered_map>
#include <vector>

static int failures;
static void check(bool ok, const char *what) {
  if (!ok) {
    std::printf("cxx-hello: FAILED: %s\n", what);
    failures++;
  }
}

// A static object: constructed before main, destroyed after it.
struct Global {
  int value;
  Global() : value(42) {}
  ~Global() { std::printf("cxx-hello: static destructor\n"); }
};
static Global global;

// A function-local static: __cxa_guard_acquire and release.
static int &counter() {
  static int c = 7;
  return c;
}

struct Shape {
  virtual ~Shape() = default;
  virtual double area() const = 0;  // __cxa_pure_virtual in the vtable
};
struct Square : Shape {
  double side;
  explicit Square(double s) : side(s) {}
  double area() const override { return side * side; }
};

struct Oops : std::runtime_error {
  int code;
  Oops(const char *what, int c) : std::runtime_error(what), code(c) {}
};

// Exceptions through several frames, with an object to destroy on the way.
static int destroyed;
struct Guard {
  ~Guard() { destroyed++; }
};
[[gnu::noinline]] static void deep(int n) {
  Guard g;
  if (n == 0) throw Oops("deep", 99);
  deep(n - 1);
}

int main() {
  std::printf("cxx-hello: hello from C++\n");
  check(global.value == 42, "a static constructor");
  check(counter()++ == 7 && counter() == 8, "a guarded static");

  // The heap, strings, containers, std::function.
  auto p = std::make_unique<std::vector<int>>();
  for (int i = 0; i < 1000; i++) p->push_back(i * i);
  check(p->size() == 1000 && (*p)[999] == 998001, "a vector");
  std::string s = "croi";
  s += ", ";
  s.append("VectraOS");
  s.insert(0, "hello ");
  check(s == "hello croi, VectraOS" && s.find("croi") == 6, "a string");
  std::unordered_map<std::string, int> h;
  for (int i = 0; i < 200; i++) h["k" + std::to_string(i)] = i;
  check(h.size() == 200 && h["k137"] == 137, "an unordered_map");
  std::map<int, std::string> m{{3, "c"}, {1, "a"}, {2, "b"}};
  check(m.begin()->second == "a" && m.rbegin()->second == "c", "a map");
  std::function<int(int)> f = [k = 3](int x) { return x * k; };
  check(f(14) == 42, "std::function");
  check(std::to_string(2.5) == "2.500000" && std::stod("1e-3") == 0.001, "to_string and stod");

  // Virtual calls and RTTI.
  std::unique_ptr<Shape> shape = std::make_unique<Square>(3);
  check(shape->area() == 9, "a virtual call");
  check(dynamic_cast<Square *>(shape.get()) != nullptr && typeid(*shape) == typeid(Square), "RTTI");
  int status = 1;
  char *name = abi::__cxa_demangle(typeid(Square).name(), nullptr, nullptr, &status);
  check(status == 0 && name && std::string(name) == "Square", "__cxa_demangle");
  std::free(name);

  // Exceptions.
  try {
    deep(5);
    check(false, "an exception thrown");
  } catch (const Oops &e) {
    check(e.code == 99 && std::string(e.what()) == "deep", "an exception caught by type");
  }
  check(destroyed == 6, "the frames' objects destroyed while unwinding");
  try {
    try {
      throw std::out_of_range("inner");
    } catch (const std::exception &) {
      throw;  // rethrown
    }
  } catch (const std::out_of_range &e) {
    check(std::string(e.what()) == "inner", "an exception rethrown");
  }
  bool range = false;
  try {
    (void)std::stoi("99999999999999999999");
  } catch (const std::out_of_range &) {
    range = true;
  }
  check(range, "stoi's out_of_range");
  bool bad = false;
  try {
    std::vector<int> v(3);
    (void)v.at(10);
  } catch (const std::out_of_range &) {
    bad = true;
  }
  check(bad, "vector::at's out_of_range");

  // Threads, a mutex and a condition variable, clocks.
  unsigned cpus = std::thread::hardware_concurrency();
  check(cpus >= 1, "hardware_concurrency");
  std::mutex mutex;
  std::condition_variable ready;
  long total = 0;
  int done = 0;
  std::vector<std::thread> threads;
  auto start = std::chrono::steady_clock::now();
  for (int t = 0; t < 4; t++) {
    threads.emplace_back([&, t] {
      for (int i = 0; i < 10000; i++) {
        std::lock_guard<std::mutex> lock(mutex);
        total += t + 1;
      }
      std::lock_guard<std::mutex> lock(mutex);
      done++;
      ready.notify_one();
    });
  }
  {
    std::unique_lock<std::mutex> lock(mutex);
    ready.wait(lock, [&] { return done == 4; });
  }
  for (auto &t : threads) t.join();
  check(total == 100000, "threads over a mutex");
  std::this_thread::sleep_for(std::chrono::milliseconds(2));
  auto elapsed = std::chrono::steady_clock::now() - start;
  check(elapsed >= std::chrono::milliseconds(2), "sleep_for and steady_clock");

  std::printf("cxx-hello: %u CPUs, %s\n", cpus, failures ? "FAILED" : "passed");
  return failures ? 1 : 0;
}
