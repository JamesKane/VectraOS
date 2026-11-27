// SPDX-License-Identifier: BSD-3-Clause

// <locale.h> in the "C" locale, the only one (C23 §7.11, POSIX's locale
// objects). In C because the locale uselocale sets is each thread's
// (_Thread_local), which Swift code can't have yet; the rest is the
// handful of constants beside it. A locale object is the one C locale:
// newlocale and duplocale give it, freelocale has nothing to free.

#include <errno.h>
#include <locale.h>
#include <stddef.h>
#include <string.h>

struct td_locale {
  int unused;
};

static struct td_locale c_locale;

// Whether `name` names the C locale: "C", "POSIX", or "" (the
// environment's choice, which can only be the C locale).
static int names_c(const char *name) {
  return name[0] == 0 || strcmp(name, "C") == 0 || strcmp(name, "POSIX") == 0;
}

static char c_name[] = "C";

char *setlocale(int category, const char *name) {
  if (category < LC_CTYPE || category > LC_ALL) return NULL;
  if (name != NULL && !names_c(name)) return NULL;
  return c_name;
}

// CHAR_MAX: "not available in this locale" (tier 0 builds see our
// <limits.h>, which leaves the char limits to the compiler's).
#ifdef __CHAR_UNSIGNED__
#define NO_VALUE 255
#else
#define NO_VALUE 127
#endif

static char empty[] = "";
static char point[] = ".";
static struct lconv c_conventions = {
    .decimal_point = point,
    .thousands_sep = empty,
    .grouping = empty,
    .int_curr_symbol = empty,
    .currency_symbol = empty,
    .mon_decimal_point = empty,
    .mon_thousands_sep = empty,
    .mon_grouping = empty,
    .positive_sign = empty,
    .negative_sign = empty,
    .int_frac_digits = NO_VALUE,
    .frac_digits = NO_VALUE,
    .p_cs_precedes = NO_VALUE,
    .p_sep_by_space = NO_VALUE,
    .n_cs_precedes = NO_VALUE,
    .n_sep_by_space = NO_VALUE,
    .p_sign_posn = NO_VALUE,
    .n_sign_posn = NO_VALUE,
    .int_p_cs_precedes = NO_VALUE,
    .int_p_sep_by_space = NO_VALUE,
    .int_n_cs_precedes = NO_VALUE,
    .int_n_sep_by_space = NO_VALUE,
    .int_p_sign_posn = NO_VALUE,
    .int_n_sign_posn = NO_VALUE,
};

struct lconv *localeconv(void) { return &c_conventions; }

locale_t newlocale(int category_mask, const char *name, locale_t base) {
  (void)base;  // the C locale whatever its categories were
  if ((category_mask & ~LC_ALL_MASK) != 0 || name == NULL) {
    errno = EINVAL;
    return NULL;
  }
  if (!names_c(name)) {
    errno = ENOENT;
    return NULL;
  }
  return &c_locale;
}

locale_t duplocale(locale_t locale) {
  if (locale == NULL) {
    errno = EINVAL;
    return NULL;
  }
  return &c_locale;
}

void freelocale(locale_t locale) { (void)locale; }

// The thread's locale: LC_GLOBAL_LOCALE until uselocale sets another.
static _Thread_local locale_t current = NULL;

locale_t uselocale(locale_t locale) {
  locale_t previous = current == NULL ? LC_GLOBAL_LOCALE : current;
  if (locale != NULL) current = locale;
  return previous;
}
