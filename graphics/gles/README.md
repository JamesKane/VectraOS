# graphics/gles

OpenGL ES 2.0 and EGL over the core (D183): gles(3), egl(3).

## The Khronos headers

`include/` holds the Khronos Group's API headers, as published, for the C
programs that use the library and for the generated C entry points:

| Header | Source | License |
|---|---|---|
| `GLES2/gl2.h`, `GLES2/gl2ext.h`, `GLES2/gl2platform.h` | KhronosGroup/OpenGL-Registry, `api/GLES2/` (main, 2026-11-26) | MIT |
| `EGL/egl.h`, `EGL/eglext.h`, `EGL/eglplatform.h` | KhronosGroup/EGL-Registry, `api/EGL/` (main, 2026-11-26) | MIT |
| `KHR/khrplatform.h` | KhronosGroup/EGL-Registry, `api/KHR/` (main, 2026-11-26) | MIT |

They are not lifted from croi, todhchai or NeoVectra, so `IMPORTS.tsv`
doesn't list them. One change: `EGL/eglplatform.h` has a `__vectraos__`
branch, as the header invites adopters to add, including `EGL/vectraos.h`
(ours) and naming its `struct
vectra_egl_window` as `EGLNativeWindowType`.

## Generated files

`c/generate.sh` writes, from those headers, `lib/generated/Constants.swift`
(the GL and EGL constants), `c/libGLESv2.c` and `c/libEGL.c` (the C names,
each calling libGLES.so's `gles_` function) and `c/procs.c`
(eglGetProcAddress's table). Run it from anywhere after a header or its
extension lists change, and commit what it writes.
