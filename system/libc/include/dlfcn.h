// SPDX-License-Identifier: BSD-3-Clause

// <dlfcn.h> (POSIX XBD <dlfcn.h>, XSH dlopen, dlsym, dlclose, dlerror),
// natively (M5k, system/ld): a name is bootfs's lib/NAME (or a path in
// bootfs). Every symbol is bound at load (RTLD_NOW's behaviour, whichever
// flag), into the global scope (RTLD_GLOBAL's), and nothing is unloaded:
// dlclose only counts. A program that loads libraries is linked to export
// its symbols (croi_user_program's EXPORT_DYNAMIC).

#ifndef TD_DLFCN_H
#define TD_DLFCN_H

#ifdef __cplusplus
extern "C" {
#endif

#define RTLD_LAZY 1
#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL 0
#define RTLD_DEFAULT ((void *)0)

void *dlopen(const char *file, int mode);
void *dlsym(void *handle, const char *name);
int dlclose(void *handle);
char *dlerror(void);

#ifdef __cplusplus
}
#endif

#endif
