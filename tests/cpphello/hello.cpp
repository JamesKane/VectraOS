/*
cpphello -- the first C++ program, `docs/DEVTOOLS.md` step 0's boot line.

A global object's constructor runs before `main`, because `crt0` walks
`.init_array` first. The constructor writes a line and sets a flag, `main`
writes a line and exits with a word that says whether the flag was set. So
the self-test's word proves the constructor ran, and a person sees both
lines. Built `-fno-exceptions -fno-rtti`: the two halves of C++ that need
a runtime are section 8's, and nothing here throws.
*/
#include "vlibc.h"

static int ctor_ran = 0;

struct Greeter {
	Greeter()
	{
		print("hello from a C++ constructor\n");
		ctor_ran = 1;
	}
};

static Greeter greeter;

// Freestanding C++ leaves `main`'s name implementation-defined, and clang
// mangles it without a hosted runtime, so `crt0` would not find it. The
// convention here, as in every freestanding C++, is `extern "C" int main`.
extern "C" int main(int, char **)
{
	print("hello from C++ main\n");
	exits(ctor_ran ? "cpp ok" : "cpp no ctor");
	return 0;
}
