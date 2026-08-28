/*
Two error vocabularies, deliberately not merged.

`Error` is the codec's: the bytes are wrong, and no reply can be built from
them. `Errno` is the protocol's, carried in Rlerror: the request was
well-formed and the answer is no.

A merge of the two would let a server answer a corrupt message as though it
understood it. A Tread on a fid that was never opened is EBADF, and a perfectly
ordinary reply. A Tread whose declared size runs past the buffer is a transport
failure, and the whole session is suspect.
*/
package vectra9

Error :: enum {
	None,
	Short_Buffer, // Ran off the end reading, or out of room writing
	Size_Mismatch, // The declared size disagrees with the buffer handed over
	Unknown_Kind, // Type byte is not a 9P2000.L message
	Illegal_Kind, // Type 6 (Tlerror) is reserved and never legal on the wire
	String_Too_Long, // A string longer than the 16-bit length prefix can hold
	Too_Many_Walk_Elements, // More than MAX_WALK_ELEMENTS names or qids
	Transport_Failed,
	Interrupted, // The caller gave up and the request was flushed
}

// describe renders an Error for a log. There is no `fmt` down here, and an enum
// otherwise prints as its ordinal.
describe :: proc "contextless" (err: Error) -> string {
	switch err {
	case .None:                   return "no error"
	case .Short_Buffer:           return "message runs past the end of its buffer"
	case .Size_Mismatch:          return "declared message size does not match the buffer"
	case .Unknown_Kind:           return "unknown message type"
	case .Illegal_Kind:           return "reserved message type"
	case .String_Too_Long:        return "string exceeds the 16-bit length prefix"
	case .Too_Many_Walk_Elements: return "walk has more than 16 elements"
	case .Transport_Failed:       return "transport failed"
	case .Interrupted:            return "request flushed before it was answered"
	}
	return "unknown codec error"
}

/*
Protocol errors, as Linux numbers.

9P2000.L carries an errno in Rlerror rather than the human-readable string
plain 9P used. Worse to read, and far better to translate, which is what
libposix will do with it. It is a wire-compatibility obligation, not a claim
that errno is a good error model.

Only the codes a file server actually produces are named. An unnamed code is
still a perfectly valid Errno. It just prints as a number.
*/
Errno :: distinct u32

EPERM :: Errno(1)
ENOENT :: Errno(2)
ESRCH :: Errno(3)
EINTR :: Errno(4)
EIO :: Errno(5)
ENXIO :: Errno(6)
ENOEXEC :: Errno(8)
EBADF :: Errno(9)
ECHILD :: Errno(10)
EAGAIN :: Errno(11)
ENOMEM :: Errno(12)
EACCES :: Errno(13)
EFAULT :: Errno(14)
EBUSY :: Errno(16)
EEXIST :: Errno(17)
EXDEV :: Errno(18)
ENODEV :: Errno(19)
ENOTDIR :: Errno(20)
EISDIR :: Errno(21)
EINVAL :: Errno(22)
ENFILE :: Errno(23)
EMFILE :: Errno(24)
ENOSPC :: Errno(28)
ESPIPE :: Errno(29)
EROFS :: Errno(30)
EMLINK :: Errno(31)
EPIPE :: Errno(32)
EDEADLK :: Errno(35)
ENAMETOOLONG :: Errno(36)
ENOSYS :: Errno(38)
ENOTEMPTY :: Errno(39)
ELOOP :: Errno(40)
EPROTO :: Errno(71)
EOPNOTSUPP :: Errno(95)
ETIMEDOUT :: Errno(110)
ECONNREFUSED :: Errno(111)

errno_name :: proc "contextless" (code: Errno) -> string {
	switch code {
	case EPERM:        return "EPERM"
	case ENOENT:       return "ENOENT"
	case ESRCH:        return "ESRCH"
	case EINTR:        return "EINTR"
	case EIO:          return "EIO"
	case ENXIO:        return "ENXIO"
	case ENOEXEC:      return "ENOEXEC"
	case EBADF:        return "EBADF"
	case ECHILD:       return "ECHILD"
	case EAGAIN:       return "EAGAIN"
	case ENOMEM:       return "ENOMEM"
	case EACCES:       return "EACCES"
	case EFAULT:       return "EFAULT"
	case EBUSY:        return "EBUSY"
	case EEXIST:       return "EEXIST"
	case EXDEV:        return "EXDEV"
	case ENODEV:       return "ENODEV"
	case ENOTDIR:      return "ENOTDIR"
	case EISDIR:       return "EISDIR"
	case EINVAL:       return "EINVAL"
	case ENFILE:       return "ENFILE"
	case EMFILE:       return "EMFILE"
	case ENOSPC:       return "ENOSPC"
	case ESPIPE:       return "ESPIPE"
	case EROFS:        return "EROFS"
	case EMLINK:       return "EMLINK"
	case EPIPE:        return "EPIPE"
	case EDEADLK:      return "EDEADLK"
	case ENAMETOOLONG: return "ENAMETOOLONG"
	case ENOSYS:       return "ENOSYS"
	case ENOTEMPTY:    return "ENOTEMPTY"
	case ELOOP:        return "ELOOP"
	case EPROTO:       return "EPROTO"
	case EOPNOTSUPP:   return "EOPNOTSUPP"
	case ETIMEDOUT:    return "ETIMEDOUT"
	case ECONNREFUSED: return "ECONNREFUSED"
	}
	return "errno"
}

// error_reply is the reply to send when a request cannot be honoured. Spelled
// out as a helper because every server needs it and getting Rlerror's shape
// wrong is a protocol violation rather than a visible bug.
error_reply :: proc "contextless" (code: Errno) -> Msg {
	return Rlerror{ecode = u32(code)}
}
