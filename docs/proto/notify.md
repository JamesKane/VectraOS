# 9Px extension `notify`

Status: draft, M6 step 6e1d (decided 2026-10-07: one reply per request; events made in vx-9p's framework).

File watching without polling: a client waits on a fid for changes to the file or directory it names. 02 §3.3 sketched `Tnotify fid mask` answered by a stream of `Rnotify`; that would break 9P's rule of one reply to a request, which the ring client's leader and followers and the relay rely on, so instead each `Tnotify` is answered once, when events are queued, and the client asks again. It works unchanged over the ring, TCP and a relay, and `Tflush` cancels a wait. A connection asks for it in `Tversion` (`9P2000.x/1 +notify`).

## Messages

    size[4] Tnotify tag[2] fid[4] mask[8]      type 164
    size[4] Rnotify tag[2] count[4] data[count] type 165

`data` is events, each `kind[1] name[s]`. Kinds, also the mask's bits: CREATE 1, REMOVE 2, MODIFY 4, ATTRIB 8, MOVED_FROM 16, MOVED_TO 32; LOST 128, never asked for, always given, when the watch's queue overflowed. A directory's watch names the entry; a file's watch has an empty name.

## Rules

- The first `Tnotify` on a fid makes its watch; each later one sets the mask; the fid's clunk ends it.
- A `Tnotify` with nothing queued is held until an event comes (vx-9p: SHOULD_WAIT, served again when one is queued); `Tflush` drops it.
- The server queues up to 32 events per watch between asks; more set LOST.
- Events come from the changes the server serves on any connection: `Tcreate`, `Tmkdir`, `Tsymlink` (CREATE on the directory); `Twrite`, `Twriteref` (MODIFY on the file and its directory); `Tremove`, `Tunlinkat`, an `ORCLOSE` clunk (REMOVE on both); `Trenameat`, `Trename`, `Twstat`'s name (MOVED_FROM and MOVED_TO on the directories); `Tsetattr`, `Twstat` (ATTRIB on the file and its directory).

## Implementation

vx-9p's server framework (lib/vx-9p/server.c) does it all, for every server that lists `P9_EXT_NOTIFY`: fsd, tmpfs and srvfs. The watches live in the server's `p9_shared`, beside its open files and locks, so they span its connections; each change goes through a wrapper (`p9_fs_create` and the rest) that serves it and then queues its events, waking the held `Tnotify`s (`p9_shared.again`, which ring_server checks). The client's call is `p9c_notify` (lib/vx-9p/client.c).
