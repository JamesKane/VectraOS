// srv: posts a 9P server over TCP in /srv, and mounts it, as 9front's srv(4)
// does (M6 step 6d4d2c): the dialing done by a relay (relay(4)), which the
// post keeps going for whoever opens it; the mount made in the namespace
// srv shares with whoever ran it, so the shell has it after srv exits.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-rt/spawn.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-ns/relay.c"

static vx_ns ns;
static vx_str dest;

static void say(vx_str a, vx_str b, vx_status st) {
  vx_eprint(VX_STR("srv: "));
  vx_eprint(a);
  vx_eprint(b);
  if (st != VX_OK) {
    vx_eprint(VX_STR(": "));
    vx_eprint(p9_error_text(st));
  }
  vx_eprint(VX_STR("\n"));
}

// Appends s at buf[*n] (cap bytes); false if it does not fit.
static bool put(char *buf, size_t *n, size_t cap, vx_str s) {
  if (s.len > cap - *n) return false;
  memcpy(buf + *n, s.ptr, s.len);
  *n += s.len;
  return true;
}

// The part of s after its last c, or all of it.
static vx_str after_last(vx_str s, char c) {
  size_t i = s.len;
  while (i > 0 && s.ptr[i - 1] != c) i--;
  return (vx_str){s.ptr + i, s.len - i};
}

// The part of s after its first c, or all of it.
static vx_str after_first(vx_str s, char c) {
  for (size_t i = 0; i < s.len; i++)
    if (s.ptr[i] == c) return (vx_str){s.ptr + i + 1, s.len - i - 1};
  return s;
}

// 9front's netmkaddr(dest, 0, "9fs"): host, net!host and net!host!service.
static vx_str address(vx_str d, char *buf, size_t cap) {
  size_t bangs = 0, n = 0;
  for (size_t i = 0; i < d.len; i++) bangs += d.ptr[i] == '!';
  bool ok = (bangs || put(buf, &n, cap, VX_STR("tcp!"))) && put(buf, &n, cap, d) &&
            (bangs == 2 || put(buf, &n, cap, VX_STR("!9fs")));
  return ok ? (vx_str){buf, n} : (vx_str){};
}

static vx_status remove_post(vx_str path) {
  p9_client *c;
  uint32_t fid;
  vx_status st = vx_ns_walk(&ns, path, &c, &fid);
  return st == VX_OK ? p9c_remove(c, fid) : st;
}

// Posts connector (a duplicate of it) as path, owned by whoever runs srv, 0600 as on 9front.
static vx_status post(vx_str path, vx_handle connector) {
  vx_ns_file f;
  vx_status st = vx_ns_create(&ns, path, 0600, P9_OWRITE, &f);
  if (st != VX_OK) return st;
  vx_handle dup;
  st = vx_handle_dup(connector, VX_RIGHTS_SAME, &dup);
  if (st == VX_OK) st = p9c_write_handle(f.c, f.fid, dup);
  vx_ns_close(&f);
  if (st != VX_OK) remove_post(path);
  return st;
}

const char *vx_main(void) {
  bool domount = false, reallymount = false, asnone = false;
  uint8_t flags = 0;
  uint64_t sleeptime = 0;
  uint32_t i = 0;
  for (; i < vx_spawn.argc && vx_spawn.args[i].len > 1 && vx_spawn.args[i].ptr[0] == '-'; i++) {
    vx_str a = vx_spawn.args[i];
    for (size_t j = 1; j < a.len; j++) {
      switch (a.ptr[j]) {
      case 'a': flags |= VX_NS_AFTER, domount = reallymount = true; break;
      case 'b': flags |= VX_NS_BEFORE, domount = reallymount = true; break;
      case 'c': flags |= VX_NS_CREATE, domount = reallymount = true; break;
      case 'C': // no mount cache here: a mount as any other
      case 'm': domount = reallymount = true; break;
      case 'N': asnone = true; break;
      case 'n': break; // no authentication: there is none before keyd (M10)
      case 'q': domount = true, reallymount = false; break;
      case 's':
        if (++i == vx_spawn.argc) return vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n")), "usage";
        for (size_t k = 0;
             k < vx_spawn.args[i].len && vx_spawn.args[i].ptr[k] >= '0' && vx_spawn.args[i].ptr[k] <= '9';
             k++) // as atoi reads it: to the first byte not a digit
          sleeptime = sleeptime * 10 + (uint64_t)(vx_spawn.args[i].ptr[k] - '0');
        j = a.len;
        break;
      default: vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n")); return "usage";
      }
    }
  }
  uint32_t n = vx_spawn.argc - i;
  if ((flags & VX_NS_AFTER) && (flags & VX_NS_BEFORE)) n = 0;
  if (n < 1 || n > 3) {
    vx_eprint(vx_cstr(VX_USAGE)), vx_eprint(VX_STR("\n"));
    return "usage";
  }
  dest = vx_spawn.args[i];
  // 9front's names: /srv/ the address's last element; /n/ the address after its network.
  vx_str base = after_last(dest, '/');
  char srvbuf[96], mtptbuf[VX_NS_MAX_PATH], addrbuf[VX_NS_MAX_SRC];
  size_t sl = 0, ml = 0;
  bool fits = put(srvbuf, &sl, sizeof srvbuf, VX_STR("/srv/")) &&
              put(srvbuf, &sl, sizeof srvbuf, n >= 2 ? vx_spawn.args[i + 1] : base);
  if (n == 3)
    fits = fits && put(mtptbuf, &ml, sizeof mtptbuf, vx_spawn.args[i + 2]), domount = reallymount = true;
  else
    fits = fits && put(mtptbuf, &ml, sizeof mtptbuf, VX_STR("/n/")) &&
           put(mtptbuf, &ml, sizeof mtptbuf, after_first(base, '!'));
  vx_str srv = {srvbuf, sl}, mtpt = {mtptbuf, ml}, addr = address(dest, addrbuf, sizeof addrbuf);
  if (!fits || !addr.len) {
    say(dest, VX_STR(": name too long"), VX_OK);
    return "usage";
  }
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";

  for (int try = 1;; try++) {
    p9_client *c = nullptr;
    vx_handle connector = VX_HANDLE_NONE;
    p9_client *probe;
    uint32_t fid;
    if (vx_ns_walk(&ns, srv, &probe, &fid) == VX_OK) { // there already
      p9c_clunk(probe, fid);
      if (!domount) {
        say(srv, VX_STR(" already exists"), VX_OK);
        return nullptr;
      }
      vx_status st = vx_ns_open_post(&ns, srv, &connector);
      if (st == VX_OK && !(c = vx_ns_connect_handle(connector, &st))) vx_handle_close(connector);
      if (!c) remove_post(srv); // a post of nothing that answers: made again
    }
    if (!c) {
      vx_status st = vx_ns_relay(&ns, addr, &c, &connector);
      if (st != VX_OK) {
        say(VX_STR("dial "), addr, st);
        return "dial";
      }
      if (sleeptime) {
        vx_handle port;
        vx_packet pk;
        if (vx_port_create(0, &port) == VX_OK) {
          vx_port_wait(port, vx_clock_read() + (int64_t)sleeptime * 1'000'000'000, 0, &pk, 1);
          vx_handle_close(port);
        }
      }
      st = post(srv, connector);
      if (st != VX_OK) {
        say(srv, VX_STR(""), st);
        return "post";
      }
    }
    if (!domount || !reallymount) return nullptr;
    if (asnone) c->uname = VX_STR("none"), try = 2; // no retry, as on 9front
    vx_status st = vx_ns_mount(&ns, c, connector, srv, (vx_str){}, mtpt, flags);
    if (st == VX_OK) return nullptr;
    if ((st == VX_ERR_PEER_CLOSED || st == VX_ERR_TIMED_OUT) && try == 1) { // hung up: made again, once
      remove_post(srv);
      continue;
    }
    vx_eprint(VX_STR("srv ")); // 9front's words
    vx_eprint(dest);
    vx_eprint(VX_STR(": mount failed: "));
    vx_eprint(p9_error_text(st));
    vx_eprint(VX_STR("\n"));
    return "mount";
  }
}
