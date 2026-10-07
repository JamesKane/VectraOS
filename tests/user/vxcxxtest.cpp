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
// standard input to standard output, for rctest; with fs, std::filesystem on
// a vx-fs volume (6e2e2, scenario vxcxxfs). Each check prints a line
// only when it fails; the last line counts them.

#include <chrono>
#include <condition_variable>
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
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

// The fs mode (6e2e2), on a vx-fs volume on /tmp (tests/user/vxcxxfs.ndb): a
// tree with a symbolic link to a directory walked, and the operations on it.
namespace fs = std::filesystem;

bool write_file(const fs::path &p, const char *text) {
  std::ofstream out(p);
  out << text;
  return bool(out);
}

std::string read_file(const fs::path &p) {
  const std::ifstream in(p);
  std::stringstream s;
  s << in.rdbuf();
  return s.str();
}

int files() {
  std::error_code ec;
  const fs::path root = "/tmp/fstest";
  fs::remove_all(root, ec);
  CHECK(fs::create_directories(root / "sub" / "deep", ec) && !ec);
  CHECK(write_file(root / "a.txt", "hello") && write_file(root / "sub" / "b.txt", "world"));
  fs::create_directory_symlink("sub", root / "link", ec);
  CHECK(!ec && fs::is_symlink(fs::symlink_status(root / "link")) && fs::read_symlink(root / "link") == "sub");
  CHECK(fs::is_directory(root / "link") && fs::exists(root / "link" / "b.txt"));
  // The walk: a symbolic link is an entry, not followed.
  std::vector<std::string> seen;
  for (const auto &e : fs::recursive_directory_iterator(root, ec))
    seen.push_back(e.path().lexically_relative(root));
  std::ranges::sort(seen);
  const std::vector<std::string> want = {"a.txt", "link", "sub", "sub/b.txt", "sub/deep"};
  CHECK(!ec && seen == want);
  CHECK(fs::file_size(root / "a.txt") == 5 &&
        fs::canonical(root / "link" / "b.txt") == root / "sub" / "b.txt");
  CHECK(fs::copy_file(root / "a.txt", root / "c.txt", ec) && read_file(root / "c.txt") == "hello");
  fs::rename(root / "c.txt", root / "sub" / "d.txt", ec);
  CHECK(!ec && !fs::exists(root / "c.txt") && read_file(root / "sub" / "d.txt") == "hello");
  // A fixed date: the clock may not have been set from the RTC yet, this early.
  const fs::file_time_type when{std::chrono::seconds(1'700'000'000)};
  fs::last_write_time(root / "a.txt", when, ec);
  const auto secs = [](fs::file_time_type t) {
    return std::chrono::duration_cast<std::chrono::seconds>(t.time_since_epoch()).count();
  };
  CHECK(!ec && secs(fs::last_write_time(root / "a.txt")) == secs(when));
  fs::permissions(root / "a.txt", fs::perms::owner_read, ec);
  CHECK(!ec && (fs::status(root / "a.txt").permissions() & fs::perms::all) == fs::perms::owner_read);
  fs::current_path(root / "sub", ec);
  CHECK(!ec && fs::current_path() == root / "sub" && fs::exists("b.txt"));
  fs::current_path("/", ec);
  fs::create_hard_link(root / "a.txt", root / "hard", ec);
  CHECK(ec == std::errc::not_supported); // no hard links on VectraOS
  fs::space(root, ec);
  CHECK(bool(ec));
  CHECK(fs::temp_directory_path() == "/tmp");
  CHECK(fs::remove_all(root, ec) == 7 && !ec && !fs::exists(root));
  std::printf("vxcxxtest: fs %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
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
  if (argc > 1 && std::string(argv[1]) == "fs") return files();
  std::printf("vxcxxtest: hello from libc++\n");
  rtti();
  threads();
  streams();
  std::printf("vxcxxtest: %d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
