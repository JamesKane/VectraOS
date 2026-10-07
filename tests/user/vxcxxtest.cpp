// vxcxxtest: C++ on the native target (M6 step 6e2d2, ADR-0033 section 2a
// stages 1 and 2), the vxc scenario's (tests/qemu/vxc.ndb). Built with only
// the target: Fedora's clang++ with the sysroot's configuration file, ld.lld
// with its C++ response files, against libc++ and libc++abi over llvm-libc
// and libvx. RTTI: virtual calls, dynamic_cast and typeid. Threads, through
// libc++'s external threading API over the C library's <threads.h>:
// std::thread, a mutex, a condition variable, call_once, a function-local
// static made once whichever thread asks first (__cxa_guard_*),
// thread_local, and a sleep on steady_clock. iostreams in the C locale and
// random_device (6e2e1); with the argument cin, it sums the numbers on its
// standard input to standard output, for rctest. Each check prints a line
// only when it fails; the last line counts them.

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <iostream>
#include <locale>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <typeinfo>
#include <vector>

#define CHECK(cond) check((cond), #cond, __LINE__)

namespace {

int checks, failures;

void check(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  std::printf("vxcxxtest: FAILED line %d: %s\n", line, what);
}

struct Shape {
  virtual ~Shape() = default;
  virtual int sides() const = 0;
};
struct Square : Shape {
  int sides() const override { return 4; }
};
struct Triangle : Shape {
  int sides() const override { return 3; }
};

int made;
struct Once {
  Once() { made++; }
};

// A function-local static: constructed once, by whichever thread comes first.
Once &shared_once() {
  static Once o;
  return o;
}

thread_local int per_thread = 7;

void rtti() {
  std::vector<std::unique_ptr<Shape>> shapes;
  shapes.push_back(std::make_unique<Square>());
  shapes.push_back(std::unique_ptr<Shape>(new Triangle));
  int sum = 0;
  for (const auto &s : shapes) sum += s->sides();
  CHECK(sum == 7);
  Shape *p = shapes[0].get();
  CHECK(dynamic_cast<Square *>(p) != nullptr && dynamic_cast<Triangle *>(p) == nullptr);
  const Shape *q = shapes[1].get();
  CHECK(typeid(*p) == typeid(Square) && typeid(*q) != typeid(Square));
  CHECK(std::string(typeid(Square).name()).contains("Square"));
}

void threads() {
  std::mutex m;
  std::condition_variable cv;
  std::once_flag flag;
  int ready = 0, calls = 0;
  long counter = 0;
  std::vector<std::thread> workers;
  workers.reserve(4);
  for (int i = 0; i < 4; i++)
    workers.emplace_back([&] {
      shared_once();
      std::call_once(flag, [&] { calls++; });
      for (int k = 0; k < 1000; k++) {
        const std::lock_guard<std::mutex> g(m);
        counter++;
      }
      per_thread += 1; // this thread's own
      {
        const std::lock_guard<std::mutex> g(m);
        ready++;
      }
      cv.notify_one();
    });
  {
    std::unique_lock<std::mutex> lk(m);
    cv.wait(lk, [&] { return ready == 4; });
  }
  for (auto &t : workers) t.join();
  CHECK(counter == 4000 && made == 1 && calls == 1 && per_thread == 7);
  CHECK(std::this_thread::get_id() != std::thread::id() && workers[0].get_id() == std::thread::id());
  auto start = std::chrono::steady_clock::now();
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  CHECK(std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(19));
}

// iostreams in the C locale, and random_device (6e2e1).
void streams() {
  std::cout << "vxcxxtest: cout " << 42 << ' ' << 2.5 << '\n' << std::flush;
  std::stringstream ss;
  ss << 12 << ' ' << 2.25 << " word";
  int i = 0;
  double d = 0;
  std::string w;
  ss >> i >> d >> w;
  CHECK(i == 12 && d == 2.25 && w == "word");
  CHECK(std::locale().name() == "C" && std::locale("C").name() == "C");
  std::random_device rd;
  const unsigned a = rd(), b = rd(), c = rd();
  CHECK((a != b || b != c) && rd.entropy() == 32);
}

// The cin mode, which rctest runs with numbers on standard input: their sum.
int sum_cin() {
  long sum = 0, n = 0;
  while (std::cin >> n) sum += n;
  std::cout << sum << '\n';
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc > 1 && std::string(argv[1]) == "cin") return sum_cin();
  std::printf("vxcxxtest: hello from libc++\n");
  rtti();
  threads();
  streams();
  std::printf("vxcxxtest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
