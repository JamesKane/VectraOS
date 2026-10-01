// cs QUERY: asks the connection server (/net/cs) what to dial for
// "NET!HOST!SERVICE", and prints its answer, a line for each address.
// cs -d NAME: asks /net/dns for NAME's addresses instead.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

int vx_main(void) {
  bool dns = vx_spawn.argc == 2 && vx_spawn.args[0].len == 2 && memcmp(vx_spawn.args[0].ptr, "-d", 2) == 0;
  if (vx_spawn.argc != (dns ? 2u : 1u) || vx_spawn.args[dns].len > 250) {
    vx_print(VX_STR("usage: cs NET!HOST!SERVICE, or cs -d NAME\n"));
    return 1;
  }
  vx_str q = vx_spawn.args[dns];
  static vx_ns ns;
  vx_ns_file f;
  vx_status st = vx_ns_from_spawn(&ns);
  if (st == VX_OK) st = vx_ns_open(&ns, dns ? VX_STR("/net/dns") : VX_STR("/net/cs"), P9_ORDWR, &f);
  if (st == VX_OK) {
    char text[256];
    size_t len = q.len;
    memcpy(text, q.ptr, len);
    for (size_t i = 0; dns && i < 3; i++) text[len++] = " ip"[i];
    int64_t w = vx_ns_write(&f, text, (uint32_t)len); // waits while the name is looked up
    st = w < 0 ? (vx_status)w : VX_OK;
  }
  if (st != VX_OK) {
    vx_print(VX_STR("cs: "));
    vx_print(q);
    vx_print(VX_STR(": "));
    vx_print(st == VX_ERR_NOT_FOUND ? VX_STR("no such name") : p9_error_text(st));
    vx_print(VX_STR("\n"));
    return 1;
  }
  // Each read is a line, from the start of the answer.
  f.offset = 0;
  char line[256];
  for (int64_t n; (n = vx_ns_read(&f, line, sizeof line)) > 0;) vx_print((vx_str){line, (size_t)n});
  vx_ns_close(&f);
  return 0;
}
