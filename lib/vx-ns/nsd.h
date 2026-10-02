// nsd's protocol (ADR-0009): namespace groups. Shared by nsd and vx-ns.
//
// A group's namespace is its namespace(6) text, as vx_ns_print writes it, and
// the connectors its mount lines name. nsd keeps both, and publishes the text
// in a VMO each member maps read-only: a sequence number, then the text. A
// member replays the text (as a spawned child replays its records) whenever
// the sequence has moved since it last did, before it resolves a name; so
// resolving takes no round trip. A member changes the namespace by doing the
// bind, mount or unmount on its own copy, then sending nsd the text it now
// prints, and the sequence it started from: nsd takes it only if no one else
// changed the group meanwhile (STALE otherwise: the member catches up and
// does it again).
//
// Each member has its own channel to nsd, which says which group it is in.
// The first member makes the group (NEW, on nsd's post); a member gets a
// channel for a child that shares its group with SHARE.

#pragma once

#include "../../abi/vx/abi.h"

enum nsd_call : uint32_t {
  // On nsd's post: a new group, from a namespace's text and its connectors
  // (handles, named in order by the "SRC\n" lines after the text). The reply
  // carries the caller's member channel and the group's VMO.
  NSD_NEW = 1,
  // On a member channel: a channel for another member of the same group, to
  // give a child. The reply carries it.
  NSD_SHARE,
  // On a member channel, a new member saying who it is (args.task: its task
  // id): the reply carries the group's VMO.
  NSD_HELLO,
  // On a member channel: the namespace's new text, from sequence args.seq,
  // and any new connectors, named as for NEW. STALE if the group has moved on.
  NSD_UPDATE,
  // On a member channel: the connector for the source named (the bytes after
  // nsd_args). The reply carries a duplicate.
  NSD_CONNECTOR,
  // On nsd's post: the namespace text of the group task args.task is in, for
  // /proc/N/ns (procfs). NOT_FOUND if it is in none.
  NSD_TEXT,
};

typedef struct nsd_args {
  uint64_t seq;      // UPDATE: the sequence the text was made from; a reply: the group's now
  uint64_t task;     // NEW, HELLO: the caller's task id; TEXT: the one asked about
  uint32_t text_len; // the bytes after nsd_args that are text (CONNECTOR: the source's name)
  uint32_t count;    // NEW, UPDATE: connectors given, each named by a "SRC\n" line after the text
} nsd_args;

// A message: the header, nsd_args, then bytes (text, names). A reply's
// h.flags is 0 or a vx_status (STALE is VX_ERR_BAD_STATE); TEXT's carries the
// text after nsd_args.
typedef struct nsd_msg {
  vx_msg_header h;
  nsd_args a;
} nsd_msg;

static constexpr uint32_t NSD_TEXT_MAX = 16 * 1024; // a group's namespace text, at most

// The VMO a group's members map: seq, odd while nsd writes, then the text.
typedef struct nsd_page {
  uint64_t seq; // read and written with __atomic builtins
  uint32_t len;
  uint32_t reserved;
  char text[NSD_TEXT_MAX];
} nsd_page;
