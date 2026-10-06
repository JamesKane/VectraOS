// users_test.c: lib/vx-users, users(6): a table read, its groups and
// leaders, who administers (group 0, not none), the default, and malformed
// text refused with the table left as it was.

#include <string.h>

#include "check.h"
#include "../../lib/vx-users/users.c"

static vx_users t;

int main(void) {
  CHECK(vx_users_parse(&t, VX_STR(VX_USERS_DEFAULT)));
  CHECK(t.n == 2 && vx_users_adm(&t, VX_STR("adm")) && !vx_users_adm(&t, VX_STR("none")));
  CHECK(!vx_users_adm(&t, VX_STR("glenda"))); // no such user: none

  vx_str text = VX_STR("# the users\n0:adm:adm:glenda\n1:none::\n100:glenda::\n200:dev:ken:glenda,ken\n"
                       "201:ken\n");
  CHECK(vx_users_parse(&t, text));
  CHECK(t.n == 5 && vx_users_adm(&t, VX_STR("glenda")) && !vx_users_adm(&t, VX_STR("ken")));
  CHECK(vx_users_in_group(&t, 201, 200) && vx_users_leads(&t, 201, 200) && !vx_users_leads(&t, 100, 200));
  CHECK(vx_users_named(&t, VX_STR("nobody")) == t.none && t.user[t.none].id == 1);

  // Malformed: the table stays as it was.
  CHECK(!vx_users_parse(&t, VX_STR("0:adm:adm:\nx:bad::\n"))); // an id that is no number
  CHECK(!vx_users_parse(&t, VX_STR("0:adm:nobody:\n")));       // a leader who is no user
  CHECK(!vx_users_parse(&t, VX_STR("0:adm::ghost\n")));        // a member who is no user
  CHECK(t.n == 5 && vx_users_adm(&t, VX_STR("glenda")));

  // No none in the file: none is added.
  CHECK(vx_users_parse(&t, VX_STR("0:adm:adm:\n")));
  CHECK(t.n == 2 && t.user[t.none].id == VX_USERS_NONE_ID);

  // A merge keeps every user in its place (M6 step 6d5c): one added before
  // them goes after; one removed stays, gone; a table too full is refused.
  static vx_users live, fresh;
  CHECK(vx_users_parse(&fresh, VX_STR("0:adm:adm:\n1:none::\n100:glenda::\n101:ken::\n")) &&
        vx_users_merge(&live, &fresh));
  uint32_t glenda = vx_users_named(&live, VX_STR("glenda")), ken = vx_users_named(&live, VX_STR("ken"));
  CHECK(vx_users_parse(&fresh, VX_STR("300:alice::\n0:adm:adm:\n1:none::\n101:ken::\n")) &&
        vx_users_merge(&live, &fresh));
  CHECK(vx_users_named(&live, VX_STR("ken")) == ken && live.user[ken].id == 101);
  CHECK(live.user[glenda].id == VX_USERS_GONE_ID && !live.user[glenda].nname); // gone, its place kept
  CHECK(vx_users_named(&live, VX_STR("alice")) == 4 && live.n == 5);
  CHECK(vx_users_named(&live, VX_STR("glenda")) == live.none);
  CHECK(vx_users_named(&live, VX_STR("")) ==
        live.none); // not the gone place, whose name is empty (Odin's finding)
  static char many[8192];
  size_t at = 0;
  for (uint32_t i = 0; i < 126; i++) { // 126 new ones, with the 5 places taken: more than 128
    char line[24];
    int n = snprintf(line, sizeof line, "%u:u%u::\n", 1000 + i, i);
    memcpy(many + at, line, (size_t)n), at += (size_t)n;
  }
  CHECK(vx_users_parse(&fresh, (vx_str){many, at}) && !vx_users_merge(&live, &fresh) && live.n == 5);
  return check_result();
}
