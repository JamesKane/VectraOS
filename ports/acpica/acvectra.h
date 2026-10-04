// ports/acpica/acvectra.h: ACPICA's environment on VectraOS, force-included
// before every ACPICA file and every file that includes acpi.h (ADR-0030). It
// stands in for the tree's platform/acenv.h, whose list of known systems
// ends in #error: it takes acenv.h's include guard, so acenv.h is skipped,
// and defines what acenv.h and a platform header would.
//
// bus-acpi is a native VectraOS program: freestanding, 64-bit, one thread.
// ACPICA is told the C library is the system's (ACPI_USE_SYSTEM_CLIBRARY),
// so its utclib.c defines nothing; bus-acpi's OS layer gives the string and
// character functions it calls, and vx-mem the memory ones. Its object
// caches are ACPICA's own (ACPI_USE_LOCAL_CACHE). No debugger, no
// disassembler, no debug output.

#ifndef __ACENV_H__
#define __ACENV_H__

#define ACPI_BINARY_SEMAPHORE 0
#define ACPI_OSL_MUTEX 1
#define DEBUGGER_SINGLE_THREADED 0
#define DEBUGGER_MULTI_THREADED 1
#define ACPI_SRC_OS_LF_ONLY 0

#include "acgcc.h" // ACPICA's for GCC and clang: va_list, inline, packing

#define ACPI_MACHINE_WIDTH 64
#define COMPILER_DEPENDENT_INT64 long long
#define COMPILER_DEPENDENT_UINT64 unsigned long long
#define ACPI_USE_SYSTEM_CLIBRARY
#define ACPI_USE_LOCAL_CACHE
#define ACPI_USE_DO_WHILE_0
#define ACPI_MUTEX_TYPE ACPI_BINARY_SEMAPHORE
#define DEBUGGER_THREADING DEBUGGER_SINGLE_THREADED

#define ACPI_ACQUIRE_GLOBAL_LOCK(GLptr, Acquired) Acquired = 1 // no FACS: no lock shared with firmware
#define ACPI_RELEASE_GLOBAL_LOCK(GLptr, Pending) Pending = 0
#define ACPI_SEMAPHORE_NULL NULL
#define ACPI_FLUSH_CPU_CACHE()
#define ACPI_STRUCT_INIT(field, value) value
#define ACPI_SYSTEM_XFACE
#define ACPI_EXTERNAL_XFACE
#define ACPI_INTERNAL_XFACE
#define ACPI_INTERNAL_VAR_XFACE
#define ACPI_INIT_FUNCTION

#define ACPI_FILE void *
#define ACPI_FILE_OUT NULL
#define ACPI_FILE_ERR NULL

// The C library functions ACPICA calls, as a system library's headers would
// declare them (acclib.h declares them only for ACPICA's own): bus-acpi and
// vx-mem define them.
#include <stddef.h>
#include "../../lib/vx-mem/mem.h" // memset, memcpy, memmove, memcmp
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strcpy(char *restrict dst, const char *restrict src);
char *strncpy(char *restrict dst, const char *restrict src, size_t n);
char *strcat(char *restrict dst, const char *restrict src);
char *strncat(char *restrict dst, const char *restrict src, size_t n);
char *strchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
unsigned long strtoul(const char *restrict s, char **restrict end, int base);
int toupper(int c);
int tolower(int c);
int isdigit(int c);
int isspace(int c);
int isxdigit(int c);
int isupper(int c);
int islower(int c);
int isprint(int c);
int isalpha(int c);

#endif // __ACENV_H__
