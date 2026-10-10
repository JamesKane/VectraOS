// textgen: N MiB of text on standard output, 80-column lines, for the
// terminal's throughput (00 §8: cat of 1 GiB; tests/qemu/termrate.ndb). Its
// time, from its first write to its last one taken, on the console.

#include "../../lib/vx-rt/rt.c"

const char *vx_main(void) {
  uint64_t mib = 1;
  if (vx_args().len > 1) {
    vx_str a = vx_arg(1);
    mib = 0;
    for (size_t i = 0; i < a.len && a.ptr[i] >= '0' && a.ptr[i] <= '9'; i++)
      mib = mib * 10 + (uint64_t)(a.ptr[i] - '0');
  }
  static char block[4096];
  for (size_t i = 0; i < sizeof block; i++)
    block[i] = i % 81 == 80 ? '\n' : (char)('!' + (i * 7 + i / 81) % 94);
  vx_instant t0 = vx_now();
  for (uint64_t n = mib * 256; n--;) vx_print((vx_str){block, sizeof block});
  char line[64]; // on the console, not the terminal it writes to
  size_t n = vx_bfmt((vx_bytes){(uint8_t *)line, sizeof line}, "textgen: %llu MiB in %lld ms\n",
                     (unsigned long long)mib, (long long)((vx_now() - t0) / 1'000'000));
  vx_console_print((vx_str){line, n});
  return nullptr;
}
