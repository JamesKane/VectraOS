/*
The workers, and where Rflush's ordering rule is actually enforced.

`Tflush` has exactly one requirement, and every other property of it follows:
**Rflush is sent after the flushed request's fate is decided.** Not before, and
not instead. The client is entitled to read `Rflush` as `that tag is mine
again`. It can only do that if nothing will still write into the slot.

The obvious implementation lets the worker serving the `Tflush` mark the
original, prod the server, and then wait for the original to finish before
replying. It is also the wrong one. That worker is now parked. `n` flushes can
therefore empty a pool of `n` workers. That happens when the requests they name
are themselves waiting for something a worker would deliver. Plan 9 sidesteps
the question by giving every request a thread of its own.

So the wait is turned inside out. The `Tflush` records itself as the original's
`partner` and returns. Whoever finishes the original answers the flush as it
leaves. The ordering is then structural, and no worker waits for anything. No
code path writes `Rflush` except the one that just finished with the original.

    Tflush arrives ──▶ original still running?
                         no  ──▶ Rflush now
                         yes ──▶ mark it, call abort, become its partner
                                 └──▶ (later) original finishes ──▶ Rflush

Both branches are under `Conn.lock`, which is what makes "still running" and
"become its partner" one decision rather than two.
*/
package mnt

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:vectra9"

/*
serve_start puts `n` worker threads on the connection.

**`n` must exceed the number of requests that can block in a handler at once.**
Otherwise the connection deadlocks in a way no message can rescue.

Every worker inside a stuck handler is a worker that is not serving the
`Tflush` that would unstick one. This package cannot check that, because how
many of a server's requests can block is the server's own business. What it can
do is say so where the number is chosen.

One worker is the exception, and is worth having. A connection one thread
serves has one request in flight at a time, which makes it behave exactly like
`vectra9.In_Process` from the outside.

That is the shape a server whose replies borrow its own storage still needs.
See the file comment in `mnt.odin`.
*/
serve_start :: proc(c: ^Conn, n: int = 2) -> bool {
	if c == nil || c.handler == nil || n <= 0 {
		return false
	}

	c.workers = 0
	for _ in 0 ..< n {
		if sched.spawn("9p-worker", worker, c) == nil {
			break
		}
		c.workers += 1
	}
	return c.workers == n
}

/*
serve_stop asks the workers to leave and waits until they have.

Waits rather than trusts, because the caller's next act is usually to free
something a worker is standing on. Clients parked for a slot go free too.
`take` returns nil once `stop` is set, and their calls fail as transport
failures. That is what a connection that goes away looks like from the outside.
*/
serve_stop :: proc "contextless" (c: ^Conn) {
	guard := sync.acquire(&c.lock)
	c.stop = true
	sync.release(&c.lock, guard)

	sync.wakeup_all(&c.work)
	sync.wakeup_all(&c.free)
	sync.sleep(&c.quiet, all_gone, c)
}

@(private = "file")
all_gone :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(cast(^Conn)arg).live) == 0
}

@(private = "file")
have_work :: proc "contextless" (arg: rawptr) -> bool {
	c := cast(^Conn)arg
	if intrinsics.volatile_load(&c.stop) {
		return true
	}
	return intrinsics.volatile_load(&c.head) != nil
}

@(private = "file")
worker :: proc "contextless" (arg: rawptr) {
	c := cast(^Conn)arg

	// A handler may allocate. Nothing in this loop does, but the handler is
	// somebody else's code and it runs on this stack.
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	guard := sync.acquire(&c.lock)
	c.live += 1
	sync.release(&c.lock, guard)

	for {
		sync.sleep(&c.work, have_work, c)

		g := sync.acquire(&c.lock)
		r := dequeue(c)
		if r != nil {
			r.state = .Running
		}
		stopping := c.stop
		sync.release(&c.lock, g)

		if r == nil {
			if stopping {
				break
			}
			continue
		}

		serve_one(c, r)
	}

	g := sync.acquire(&c.lock)
	c.live -= 1
	sync.release(&c.lock, g)
	sync.wakeup_all(&c.quiet)
}

@(private = "file")
serve_one :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	if t, is_flush := r.request.(vectra9.Tflush); is_flush {
		if !serve_flush(c, r, t.oldtag) {
			// Somebody else's request will answer this one. The refusal to finish it
			// here is the whole mechanism. See the file comment.
			return
		}
	} else {
		c.handler(c.server, &c.session, r.tag, &r.request, &r.reply)
	}
	finish(c, r)
}

/*
serve_flush answers a Tflush, or arranges for the original to answer it.

Reports whether the caller should finish this request now. False means the
flush went to the request it names, which will answer it when it is done.
`Rflush` is then provably after the original's fate, because the code that
decided that fate writes it.

Three cases and all three end in `Rflush`, because **Tflush can never be
answered with an error**. From the client's side, all three mean `the tag is
yours again`. Those are a tag that names no request, a request that already
finished, and a request still running. The client only ever needed to know that
much.
*/
@(private = "file")
serve_flush :: proc "contextless" (c: ^Conn, f: ^Rpc, oldtag: vectra9.Tag) -> bool #no_bounds_check {
	guard := sync.acquire(&c.lock)
	c.stats.flushes += 1

	if !is_request_tag(oldtag) {
		// Not an index into the request half of the pool, so it names nothing that
		// was ever in flight. That includes NOTAG, and this connection's own flush
		// slots.
		c.stats.stale += 1
		sync.release(&c.lock, guard)
		f.reply = vectra9.Msg(vectra9.Rflush{})
		return true
	}

	old := &c.pool[int(oldtag)]
	if old.state == .Free || old.state == .Done {
		// Already settled. The client will find its reply where it left it,
		// and Rflush is honest either way.
		c.stats.stale += 1
		sync.release(&c.lock, guard)
		f.reply = vectra9.Msg(vectra9.Rflush{})
		return true
	}

	old.flushed = true
	old.partner = f
	c.stats.aborted += 1
	sync.release(&c.lock, guard)

	// Outside the lock: unsticking a request means waking a thread, and this
	// package has no business dictating how a server does that.
	if c.abort != nil {
		c.abort(c.server, oldtag)
	}
	return false
}

/*
finish publishes a reply and, if a Tflush was waiting on this request, answers
that too.

The two state changes are one critical section. A `Tflush` that arrives at this
instant therefore does one of two things. It finds the request still running
and becomes its partner, in which case the line below takes it. Or it finds the
request Done, and answers itself. There is no third outcome and therefore no
window in which a flush is recorded against a request that will never look at
it again.
*/
@(private = "file")
finish :: proc "contextless" (c: ^Conn, r: ^Rpc) {
	guard := sync.acquire(&c.lock)
	r.state = .Done
	f := r.partner
	r.partner = nil
	if f != nil {
		f.reply = vectra9.Msg(vectra9.Rflush{})
		f.state = .Done
	}
	sync.release(&c.lock, guard)

	sync.wakeup_all(&r.settled)
	if f != nil {
		sync.wakeup_all(&f.settled)
	}
}

// flushed reports whether a Tflush named this tag. For a handler that can
// abandon its work: the abort hook is the wake, and this is the reason.
flushed :: proc "contextless" (c: ^Conn, tag: vectra9.Tag) -> bool #no_bounds_check {
	if !is_request_tag(tag) {
		return false
	}
	return intrinsics.volatile_load(&c.pool[int(tag)].flushed)
}
