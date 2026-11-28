# ports/glmark2: glmark2 for VectraOS

glmark2, the OpenGL ES 2.0 benchmark, ported as a tier 1 C++ program
(D183) to measure our GLES library (graphics/gles) against AbyssBSD's
Panfrost on the Orange Pi 6 Plus. glmark2 is GPLv3: none of its files are
in this tree. Its pinned release is fetched into `.cache/ports/glmark2` and
our patches, kept here as a series, are applied to it there, as the
toolchain's are (tools/toolchain, D47).

```sh
ports/glmark2/fetch.sh            # 2023.01, pinned at 42e3d8fe3aa8, tagged vectraos-base
ports/glmark2/apply-patches.sh    # patches/*.patch onto it with git am (--reset to start over)
```

With the patched source present, tier 1's build (cmake/Tier1.cmake)
includes `cmake/Glmark2.cmake`, which compiles glmark2's GLESv2 + EGL
flavour (meson's list of sources, `src/meson.build`) with the tier 1
clang and clang++ into `bin/glmark2-es2-vectraos`, linked against FDIO,
dlopen (Ld) and the shared Swift runtime, and its data into bootfs's
`lib/glmark2` (`GLMARK_DATA_PATH`) in the board's desktop image, with
`glmark2.manifest` to start it. glmark2(8) is its page.

## The series

| Patch | What |
|---|---|
| 0001 | A native state for VectraOS (`GLMARK2_USE_VECTRAOS`, `native-state-vectraos.{h,cpp}`): EGL's default display and a `struct vectra_egl_window` (a size and a title) that our EGL makes a window of Radharc's from; no full screen, no window events; main.cpp picks it |
| 0002 | Our budgets for the default run (`budgets-vectraos.{h,cpp}`): after each scene a budget line, `gl.glmark2.<scene>`, its frame time against a frame at 98% of the reference's rate (docs/boards/orangepi-6-plus/gl.md), then `gl.glmark2.score` and the run's verdict, `glmark2: budgets met` or `glmark2: <n> budget(s) over:`; a budget missed exits with 1 (glmark2(8), BUDGETS) |

To change a patch: commit in `.cache/ports/glmark2` (amend, or reset to
`vectraos-base` and re-apply), then write the series again with
`git -C .cache/ports/glmark2 format-patch --keep-subject -o ports/glmark2/patches vectraos-base`,
and review its diff. A checkout patched before the series grew is left
alone by `apply-patches.sh`: run it with `--reset`, then configure again
(cmake/Glmark2.cmake warns when the checkout predates patch 0002, and
builds glmark2 without its budgets).

## Third-party code it carries

glmark2 2023.01 bundles libpng 1.2.46, libjpeg-turbo 1.4.2 and zlib 1.2.11
(`src/libpng`, `src/libjpeg-turbo`, `src/zlib`). They are compiled into
glmark2 alone, never installed as libraries (D4, D183). zlib is
glmark2's own 1.2.11, not a newer release fetched beside it (the owner,
2026-11-26): it only inflates glmark2's own PNG textures from bootfs.
1.2.11 has known vulnerabilities, CVE-2018-25032 (deflate's memory
corruption on some inputs, which glmark2 never deflates) and CVE-2022-37434
(inflate's heap overflow through a large gzip extra field, through
`inflateGetHeader`, which libpng doesn't call); neither is reached by data
we don't ship. Fetch a fixed zlib before glmark2 ever reads a file from
outside its image.
