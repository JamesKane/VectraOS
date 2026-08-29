/*
Vectra9 -- the message layer of Vectra's file protocol.

The protocol on the wire is 9P2000.L, unmodified, and staying that way is a
design constraint rather than an accident: see docs/VECTRA9.md. Nothing in this
package invents a message, adds a field, or negotiates a private version string.
When a service needs an operation 9P does not have, the answer is a file.

This file is the vocabulary -- the fifty-odd message bodies and the tagged
union over them. `codec.odin` turns that union into bytes and back.
`session.odin` decides whether bytes take any part at all.

Ownership, because it is the rule most easily broken: **a decoded message
borrows its buffer.** Strings and byte slices inside a `Msg` point into whatever
it was decoded from. They are valid exactly as long as that memory is, and no
part of this package copies to make that easier. It is what lets an `Rread` of
four kilobytes cost nothing to pass around.
*/
package vectra9

VERSION :: "9P2000.L"

// The largest single message either side will send, negotiated by Tversion.
// Two pages, which is what Linux's v9fs asks for by default. It bounds the
// wire. An in-process transport has no buffer to overflow, and may report
// whatever it likes.
MSIZE_DEFAULT :: 8192

// The smallest legal message: size[4] type[1] tag[2] and an empty body.
HEADER_SIZE :: 7

/*
Room a data-carrying message reserves for its own header, so the largest
payload that fits an msize is `msize - IOHDRSZ`. Plan 9 calls this number
IOHDRSZ and sets it to 24. 9front's `<fcall.h>` keeps the same value. This is
that number, and the reason it is not `HEADER_SIZE`.

A `Twrite` is the binding case. Its fixed fields are size[4] type[1] tag[2]
fid[4] offset[8] count[4] = 23 bytes before the data, and `Rread`'s are
size[4] type[1] tag[2] count[4] = 11. Reserving only the smaller of the two
-- the mistake this constant corrects -- lets a full-payload write serialise
to twelve bytes past the msize. Twenty-four is 9front's number: the binding
23, rounded up by one.
*/
IOHDRSZ :: 24

/*
9P caps a walk at sixteen elements, which is the reason `Twalk` can hold its
names inline and a `Msg` can stay a stack value. Raising this is not a local
change -- it is the size of every message in the system.
*/
MAX_WALK_ELEMENTS :: 16

Fid :: distinct u32
Tag :: distinct u16

// NOFID is the absence of a fid -- an attach with no prior authentication, for
// instance. NOTAG is legal only on Tversion, which by definition cannot have
// negotiated a tag space yet.
NOFID :: Fid(0xFFFF_FFFF)
NOTAG :: Tag(0xFFFF)

// NONUNAME is the absence of a numeric uid in Tauth and Tattach, for a client
// that named itself with a string and left `n_uname` alone. Same sentinel shape
// as NOFID and for the same reason: zero is a legal uid -- it is root.
NONUNAME :: u32(0xFFFF_FFFF)

// -- Qid ---------------------------------------------------------------------

/*
The server's permanent identity for a file.

`path` is the identity: two qids with equal paths are the same file, forever.
`version` changes whenever the contents do. That makes cache validation
possible, and makes a whole qid unsuitable as a mount-table key. A file created
inside a mounted-over directory would otherwise unmount it.
*/
Qid_Flag :: enum u8 {
	Link    = 0, // 0x01 -- hard link
	Symlink = 1, // 0x02
	Tmp     = 2, // 0x04 -- contents not preserved across restarts
	Auth    = 3, // 0x08 -- an authentication file from Tauth
	Mount   = 4, // 0x10
	Excl    = 5, // 0x20 -- exclusive use
	Append  = 6, // 0x40 -- append-only
	Dir     = 7, // 0x80
}

Qid_Flags :: bit_set[Qid_Flag;u8]

Qid :: struct {
	kind:    Qid_Flags,
	version: u32,
	path:    u64,
}

// Thirteen on the wire. Sixteen in memory, because Odin aligns `path`. Both
// numbers are needed and confusing them truncates every qid in a walk.
QID_WIRE_SIZE :: 13

// -- Message kinds -----------------------------------------------------------

/*
The 9P2000.L message numbers.

The numbering is the protocol's, not ours, and the gaps are real. 9P2000.L
claimed the low numbers for its own operations, and left the classic 9P2000
messages at 100 and above. Six (`Tlerror`) is reserved and illegal to send.

Absent, because 9P2000.L replaced them: Topen, Tcreate, Tstat, Twstat, Rerror.
Anything asking for those is speaking plain 9P2000 and should be refused at
Tversion time.
*/
Kind :: enum u8 {
	Rlerror      = 7,
	Tstatfs      = 8,
	Rstatfs      = 9,
	Tlopen       = 12,
	Rlopen       = 13,
	Tlcreate     = 14,
	Rlcreate     = 15,
	Tsymlink     = 16,
	Rsymlink     = 17,
	Tmknod       = 18,
	Rmknod       = 19,
	Trename      = 20,
	Rrename      = 21,
	Treadlink    = 22,
	Rreadlink    = 23,
	Tgetattr     = 24,
	Rgetattr     = 25,
	Tsetattr     = 26,
	Rsetattr     = 27,
	Txattrwalk   = 30,
	Rxattrwalk   = 31,
	Txattrcreate = 32,
	Rxattrcreate = 33,
	Treaddir     = 40,
	Rreaddir     = 41,
	Tfsync       = 50,
	Rfsync       = 51,
	Tlock        = 52,
	Rlock        = 53,
	Tgetlock     = 54,
	Rgetlock     = 55,
	Tlink        = 70,
	Rlink        = 71,
	Tmkdir       = 72,
	Rmkdir       = 73,
	Trenameat    = 74,
	Rrenameat    = 75,
	Tunlinkat    = 76,
	Runlinkat    = 77,
	Tversion     = 100,
	Rversion     = 101,
	Tauth        = 102,
	Rauth        = 103,
	Tattach      = 104,
	Rattach      = 105,
	Tflush       = 108,
	Rflush       = 109,
	Twalk        = 110,
	Rwalk        = 111,
	Tread        = 116,
	Rread        = 117,
	Twrite       = 118,
	Rwrite       = 119,
	Tclunk       = 120,
	Rclunk       = 121,
	Tremove      = 122,
	Rremove      = 123,
}

/*
kind_name renders a message kind for a log.

Needed the moment anyone traces 9P traffic, which is the first thing anyone
does when a server and a client disagree.

An enum otherwise prints as its ordinal. For this enum that is the wire number,
which is just misleading enough to waste an afternoon.
*/
kind_name :: proc "contextless" (k: Kind) -> string {
	switch k {
	case .Rlerror:      return "Rlerror"
	case .Tstatfs:      return "Tstatfs"
	case .Rstatfs:      return "Rstatfs"
	case .Tlopen:       return "Tlopen"
	case .Rlopen:       return "Rlopen"
	case .Tlcreate:     return "Tlcreate"
	case .Rlcreate:     return "Rlcreate"
	case .Tsymlink:     return "Tsymlink"
	case .Rsymlink:     return "Rsymlink"
	case .Tmknod:       return "Tmknod"
	case .Rmknod:       return "Rmknod"
	case .Trename:      return "Trename"
	case .Rrename:      return "Rrename"
	case .Treadlink:    return "Treadlink"
	case .Rreadlink:    return "Rreadlink"
	case .Tgetattr:     return "Tgetattr"
	case .Rgetattr:     return "Rgetattr"
	case .Tsetattr:     return "Tsetattr"
	case .Rsetattr:     return "Rsetattr"
	case .Txattrwalk:   return "Txattrwalk"
	case .Rxattrwalk:   return "Rxattrwalk"
	case .Txattrcreate: return "Txattrcreate"
	case .Rxattrcreate: return "Rxattrcreate"
	case .Treaddir:     return "Treaddir"
	case .Rreaddir:     return "Rreaddir"
	case .Tfsync:       return "Tfsync"
	case .Rfsync:       return "Rfsync"
	case .Tlock:        return "Tlock"
	case .Rlock:        return "Rlock"
	case .Tgetlock:     return "Tgetlock"
	case .Rgetlock:     return "Rgetlock"
	case .Tlink:        return "Tlink"
	case .Rlink:        return "Rlink"
	case .Tmkdir:       return "Tmkdir"
	case .Rmkdir:       return "Rmkdir"
	case .Trenameat:    return "Trenameat"
	case .Rrenameat:    return "Rrenameat"
	case .Tunlinkat:    return "Tunlinkat"
	case .Runlinkat:    return "Runlinkat"
	case .Tversion:     return "Tversion"
	case .Rversion:     return "Rversion"
	case .Tauth:        return "Tauth"
	case .Rauth:        return "Rauth"
	case .Tattach:      return "Tattach"
	case .Rattach:      return "Rattach"
	case .Tflush:       return "Tflush"
	case .Rflush:       return "Rflush"
	case .Twalk:        return "Twalk"
	case .Rwalk:        return "Rwalk"
	case .Tread:        return "Tread"
	case .Rread:        return "Rread"
	case .Twrite:       return "Twrite"
	case .Rwrite:       return "Rwrite"
	case .Tclunk:       return "Tclunk"
	case .Rclunk:       return "Rclunk"
	case .Tremove:      return "Tremove"
	case .Rremove:      return "Rremove"
	}
	return "unknown"
}

// is_request reports whether a kind is a T-message. Odd-numbered kinds are
// replies throughout 9P, with Rlerror at 7 the only reply that answers any
// request rather than its own.
is_request :: proc "contextless" (kind: Kind) -> bool {
	return u8(kind) & 1 == 0
}

// -- Session establishment ---------------------------------------------------

Tversion :: struct {
	msize:   u32,
	version: string,
}

Rversion :: struct {
	msize:   u32,
	version: string,
}

Tauth :: struct {
	afid:    Fid,
	uname:   string,
	aname:   string,
	n_uname: u32, // .L's numeric uid; NONUNAME when unused
}

Rauth :: struct {
	aqid: Qid,
}

Tattach :: struct {
	fid:     Fid,
	afid:    Fid, // NOFID when the server needs no authentication
	uname:   string,
	aname:   string,
	n_uname: u32,
}

Rattach :: struct {
	qid: Qid,
}

/*
Rlerror carries a numeric errno, not a string.

This is 9P2000.L's break from plain 9P, whose Rerror carried human text. A
number is worse to read and far better to translate, which is what libposix will
be doing with it.
*/
Rlerror :: struct {
	ecode: u32,
}

/*
Tflush asks the server to abandon a pending request.

Not a cancellation so much as a synchronisation point. The server may finish
the flushed request or drop it. But Rflush must come *after* whatever it does
with the original tag, and the client must not reuse that tag until Rflush
arrives. This is the one ordering requirement in the protocol, and it is what
makes a blocked read interruptible.

Two rules that are part of the protocol rather than any server's policy, both
taken from how Plan 9 implements this (docs/VECTRA9.md section 7.3):

  - **Tflush can never be answered with an error.** It gets Rflush or the
    connection is broken. A server that can neither find nor abort the request
    still answers Rflush -- the client only needs to know the tag is free.
  - **A flushed request may still be answered.** The client has to tolerate the
    reply to the request it tried to cancel, arriving before the Rflush.

Serving this needs a pool of in-flight requests indexed by tag, and a way to
wake the thread blocked on one. Neither exists yet. The scheduler is what
unblocks it.
*/
Tflush :: struct {
	oldtag: Tag,
}

Rflush :: struct {}

// -- Navigation --------------------------------------------------------------

/*
Twalk walks up to sixteen elements from `fid`, binding the result to `newfid`.

A short Rwalk -- fewer qids than there were names -- is a *success* carrying a
partial result, and `newfid` is not created. Only an empty Rwalk in answer to a
non-empty Twalk is a failure. Treating a short walk as an error turns every
"no such file" into a protocol error, which is the classic way to get this
wrong.
*/
Twalk :: struct {
	fid:    Fid,
	newfid: Fid,
	names:  [MAX_WALK_ELEMENTS]string,
	count:  int,
}

Rwalk :: struct {
	qids:  [MAX_WALK_ELEMENTS]Qid,
	count: int,
}

Tclunk :: struct {
	fid: Fid,
}

Rclunk :: struct {}

Tremove :: struct {
	fid: Fid,
}

Rremove :: struct {}

// -- Data --------------------------------------------------------------------

Tread :: struct {
	fid:    Fid,
	offset: u64,
	count:  u32,
}

// Borrowed, like every slice in this package: `data` points into the buffer the
// message was decoded from.
Rread :: struct {
	data: []u8,
}

Twrite :: struct {
	fid:    Fid,
	offset: u64,
	data:   []u8,
}

Rwrite :: struct {
	count: u32,
}

/*
Treaddir reads directory entries, not raw bytes.

`offset` is an opaque cookie: it must be zero or a value previously returned in
an Rreaddir entry, never an arbitrary byte position. That requirement is what
lets a union directory encode which member it is part-way through, in the high
bits of the offset. See docs/VECTRA9.md section 5.6.
*/
Treaddir :: struct {
	fid:    Fid,
	offset: u64,
	count:  u32,
}

Rreaddir :: struct {
	data: []u8,
}

// -- Open and create ---------------------------------------------------------

Tlopen :: struct {
	fid:   Fid,
	flags: u32, // Linux O_* flags
}

/*
`iounit` is the largest read or write the server promises to do atomically, or
zero for "no promise". It, not msize, is the number a well-behaved client
chunks by.
*/
Rlopen :: struct {
	qid:    Qid,
	iounit: u32,
}

Tlcreate :: struct {
	fid:   Fid, // The *directory*; becomes the new file on success
	name:  string,
	flags: u32,
	mode:  u32,
	gid:   u32,
}

Rlcreate :: struct {
	qid:    Qid,
	iounit: u32,
}

Tmkdir :: struct {
	dfid: Fid,
	name: string,
	mode: u32,
	gid:  u32,
}

Rmkdir :: struct {
	qid: Qid,
}

Tmknod :: struct {
	dfid:  Fid,
	name:  string,
	mode:  u32,
	major: u32,
	minor: u32,
	gid:   u32,
}

Rmknod :: struct {
	qid: Qid,
}

// -- Links -------------------------------------------------------------------

Tsymlink :: struct {
	fid:    Fid, // The directory to create in
	name:   string,
	target: string,
	gid:    u32,
}

Rsymlink :: struct {
	qid: Qid,
}

Treadlink :: struct {
	fid: Fid,
}

Rreadlink :: struct {
	target: string,
}

Tlink :: struct {
	dfid: Fid, // The directory the new name goes in
	fid:  Fid, // The existing file
	name: string,
}

Rlink :: struct {}

// -- Names -------------------------------------------------------------------

Trename :: struct {
	fid:  Fid,
	dfid: Fid,
	name: string,
}

Rrename :: struct {}

Trenameat :: struct {
	olddirfid: Fid,
	oldname:   string,
	newdirfid: Fid,
	newname:   string,
}

Rrenameat :: struct {}

Tunlinkat :: struct {
	dirfid: Fid,
	name:   string,
	flags:  u32, // AT_REMOVEDIR when the target is a directory
}

Runlinkat :: struct {}

// -- Attributes --------------------------------------------------------------

/*
Tgetattr asks for the fields named in `request_mask`. Rgetattr's `valid` says
which it actually filled in.

The two masks are not the same thing and a server is entitled to return fewer
fields than were asked for. A client that reads a field without checking `valid`
is reading whatever the server left there.
*/
Tgetattr :: struct {
	fid:          Fid,
	request_mask: u64,
}

Rgetattr :: struct {
	valid:        u64,
	qid:          Qid,
	mode:         u32,
	uid:          u32,
	gid:          u32,
	nlink:        u64,
	rdev:         u64,
	size:         u64,
	blksize:      u64,
	blocks:       u64,
	atime_sec:    u64,
	atime_nsec:   u64,
	mtime_sec:    u64,
	mtime_nsec:   u64,
	ctime_sec:    u64,
	ctime_nsec:   u64,
	btime_sec:    u64,
	btime_nsec:   u64,
	gen:          u64,
	data_version: u64,
}

Tsetattr :: struct {
	fid:        Fid,
	valid:      u32,
	mode:       u32,
	uid:        u32,
	gid:        u32,
	size:       u64,
	atime_sec:  u64,
	atime_nsec: u64,
	mtime_sec:  u64,
	mtime_nsec: u64,
}

Rsetattr :: struct {}

Tstatfs :: struct {
	fid: Fid,
}

Rstatfs :: struct {
	type:    u32,
	bsize:   u32,
	blocks:  u64,
	bfree:   u64,
	bavail:  u64,
	files:   u64,
	ffree:   u64,
	fsid:    u64,
	namelen: u32,
}

// -- Extended attributes -----------------------------------------------------

Txattrwalk :: struct {
	fid:    Fid,
	newfid: Fid,
	name:   string, // Empty means "list all attribute names"
}

Rxattrwalk :: struct {
	size: u64,
}

Txattrcreate :: struct {
	fid:       Fid,
	name:      string,
	attr_size: u64,
	flags:     u32,
}

Rxattrcreate :: struct {}

// -- Durability and locking --------------------------------------------------

Tfsync :: struct {
	fid:      Fid,
	datasync: u32,
}

Rfsync :: struct {}

Tlock :: struct {
	fid:       Fid,
	type:      u8, // F_RDLCK / F_WRLCK / F_UNLCK
	flags:     u32,
	start:     u64,
	length:    u64,
	proc_id:   u32,
	client_id: string,
}

Rlock :: struct {
	status: u8, // SUCCESS / BLOCKED / ERROR / GRACE
}

Tgetlock :: struct {
	fid:       Fid,
	type:      u8,
	start:     u64,
	length:    u64,
	proc_id:   u32,
	client_id: string,
}

Rgetlock :: struct {
	type:      u8,
	start:     u64,
	length:    u64,
	proc_id:   u32,
	client_id: string,
}

// -- The union ---------------------------------------------------------------

Msg :: union {
	Rlerror,
	Tstatfs,
	Rstatfs,
	Tlopen,
	Rlopen,
	Tlcreate,
	Rlcreate,
	Tsymlink,
	Rsymlink,
	Tmknod,
	Rmknod,
	Trename,
	Rrename,
	Treadlink,
	Rreadlink,
	Tgetattr,
	Rgetattr,
	Tsetattr,
	Rsetattr,
	Txattrwalk,
	Rxattrwalk,
	Txattrcreate,
	Rxattrcreate,
	Treaddir,
	Rreaddir,
	Tfsync,
	Rfsync,
	Tlock,
	Rlock,
	Tgetlock,
	Rgetlock,
	Tlink,
	Rlink,
	Tmkdir,
	Rmkdir,
	Trenameat,
	Rrenameat,
	Tunlinkat,
	Runlinkat,
	Tversion,
	Rversion,
	Tauth,
	Rauth,
	Tattach,
	Rattach,
	Tflush,
	Rflush,
	Twalk,
	Rwalk,
	Tread,
	Rread,
	Twrite,
	Rwrite,
	Tclunk,
	Rclunk,
	Tremove,
	Rremove,
}

/*
A Msg is a stack value, and this assert is what keeps it one.

Twalk's sixteen inline names set the floor. If this trips, something grew an
inline array. Fix that rather than raise the bound. Every message in the system
is this size, whether it needs to be or not.
*/
#assert(size_of(Msg) <= 320)

/*
kind reports which message a Msg holds.

A type switch rather than a stored tag, so the kind and the contents cannot
disagree. The cost is that adding a message means touching this, `encode_body`
and `decode_body` -- which is the right number of places to be reminded.
*/
kind :: proc "contextless" (msg: Msg) -> Kind {
	switch _ in msg {
	case Rlerror:      return .Rlerror
	case Tstatfs:      return .Tstatfs
	case Rstatfs:      return .Rstatfs
	case Tlopen:       return .Tlopen
	case Rlopen:       return .Rlopen
	case Tlcreate:     return .Tlcreate
	case Rlcreate:     return .Rlcreate
	case Tsymlink:     return .Tsymlink
	case Rsymlink:     return .Rsymlink
	case Tmknod:       return .Tmknod
	case Rmknod:       return .Rmknod
	case Trename:      return .Trename
	case Rrename:      return .Rrename
	case Treadlink:    return .Treadlink
	case Rreadlink:    return .Rreadlink
	case Tgetattr:     return .Tgetattr
	case Rgetattr:     return .Rgetattr
	case Tsetattr:     return .Tsetattr
	case Rsetattr:     return .Rsetattr
	case Txattrwalk:   return .Txattrwalk
	case Rxattrwalk:   return .Rxattrwalk
	case Txattrcreate: return .Txattrcreate
	case Rxattrcreate: return .Rxattrcreate
	case Treaddir:     return .Treaddir
	case Rreaddir:     return .Rreaddir
	case Tfsync:       return .Tfsync
	case Rfsync:       return .Rfsync
	case Tlock:        return .Tlock
	case Rlock:        return .Rlock
	case Tgetlock:     return .Tgetlock
	case Rgetlock:     return .Rgetlock
	case Tlink:        return .Tlink
	case Rlink:        return .Rlink
	case Tmkdir:       return .Tmkdir
	case Rmkdir:       return .Rmkdir
	case Trenameat:    return .Trenameat
	case Rrenameat:    return .Rrenameat
	case Tunlinkat:    return .Tunlinkat
	case Runlinkat:    return .Runlinkat
	case Tversion:     return .Tversion
	case Rversion:     return .Rversion
	case Tauth:        return .Tauth
	case Rauth:        return .Rauth
	case Tattach:      return .Tattach
	case Rattach:      return .Rattach
	case Tflush:       return .Tflush
	case Rflush:       return .Rflush
	case Twalk:        return .Twalk
	case Rwalk:        return .Rwalk
	case Tread:        return .Tread
	case Rread:        return .Rread
	case Twrite:       return .Twrite
	case Rwrite:       return .Rwrite
	case Tclunk:       return .Tclunk
	case Rclunk:       return .Rclunk
	case Tremove:      return .Tremove
	case Rremove:      return .Rremove
	}
	return .Rlerror
}
