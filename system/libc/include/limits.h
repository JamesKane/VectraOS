// SPDX-License-Identifier: BSD-3-Clause

// <limits.h>'s POSIX part (M6g): clang's own <limits.h> has ISO C's limits
// and includes this one after them. Textual in the module map; the limits
// themselves are <bits/limits.h>'s, which the module owns.

#include <bits/limits.h>
