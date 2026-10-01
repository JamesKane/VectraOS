// sha256_test.c: lib/vx-sha256 against the FIPS 180 test vectors, and the
// same digest whatever pieces the input arrives in.

#include <string.h>

#include "check.h"
#include "../../lib/vx-sha256/sha256.c"

static bool digest_is(const void *data, size_t len, const char *want_hex) {
  vx_sha256 h = vx_sha256_begin();
  vx_sha256_add(&h, data, len);
  uint8_t d[32];
  vx_sha256_end(&h, d);
  char hex[65];
  for (size_t i = 0; i < 32; i++) snprintf(hex + 2 * i, 3, "%02x", d[i]);
  return strcmp(hex, want_hex) == 0;
}

int main(void) {
  CHECK(digest_is("", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
  CHECK(digest_is("abc", 3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
  const char *two_blocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  CHECK(digest_is(two_blocks, strlen(two_blocks),
                  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));

  static char million[1000000];
  memset(million, 'a', sizeof million);
  CHECK(
      digest_is(million, sizeof million, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));

  // Split at every point around the block boundaries: the digest must not change.
  uint8_t whole[32];
  vx_sha256 h = vx_sha256_begin();
  vx_sha256_add(&h, million, 200);
  vx_sha256_end(&h, whole);
  for (size_t cut = 0; cut <= 200; cut++) {
    uint8_t pieces[32];
    h = vx_sha256_begin();
    vx_sha256_add(&h, million, cut);
    vx_sha256_add(&h, million + cut, 200 - cut);
    vx_sha256_end(&h, pieces);
    CHECK(memcmp(whole, pieces, 32) == 0);
  }
  return check_result();
}
