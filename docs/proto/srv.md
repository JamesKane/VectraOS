# 9Px extension `srv`

Status: draft, M6 step 6d4d2a.

Handles beside messages, for `/srv` as a file tree (srvfs, servers/srvfs): a connector given to whoever opens a post, and taken from whoever writes one. It is 9front's `#s` (srv(3)) over 9P: there, opening `/srv/NAME` gives the posted channel and writing a descriptor's number posts it; here a handle travels beside the message instead, as `map`'s VMO does. A connection asks for it in `Tversion` (`9P2000.x/1 +srv`); srvfs has it, and no other server.

## Messages

None of its own. On a session with `srv`:

- **`Ropen`** may carry a handle, beside it as `Rmap`'s VMO is (`P9_CQE_HANDLE` and a handle slot, lib/vx-9p/ring.c). srvfs gives a duplicate of the post's connector; the directory's open carries none. A client that does not want it closes it.
- **`Twrite`** may carry a handle (`VX_SQE_HANDLES` and a handle slot, as `Treadref`'s VMO). srvfs takes it as the post's connector; its data are ignored, and the reply's count is the write's.

vx-9p's server gives the file server `open_handle` and `write_handle` for these (lib/vx-9p/server.c); its client has `p9c_open_handle` and `p9c_write_handle` (lib/vx-9p/ring.c). Over TCP there are no handles, and the extension is never offered.

## srvfs's posts

- **Made** by `Tcreate` in the directory, by anyone (it is `0777`), with the permissions given (`0777` at most: a post is a file), owned by the attaching user; a name taken is `file already exists`.
- **Posted** by one `Twrite` with a connector; a second is refused (`fid already in use`). A post made and not written is listed, and its open is refused the same way.
- **Opened** for its connector, the mode checked against the owner's bits, or everyone else's (no groups): `ORDWR` for a mount.
- **Removed** by its owner only, which drops the connector; a connection made through it goes on. One made with `ORCLOSE` goes when its maker's fid does.
- **Lifetime:** srvfs keeps nothing across a restart; svcd lists the manifest posts that say `srvmode=` again only when it starts srvfs.
