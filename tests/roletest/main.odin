/*
roletest -- a machine's role, read from its `ndb` line, `docs/FLEET.md` step 3.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first check that did not hold. It asks `sys/libuser`'s `ndb_attr`
-- the same call `cmd/role` and `/lib/init` use -- for the role attributes on
records in `/lib/ndb/local`, and checks that a present role reads true even
though its value is empty, and an absent one reads false. That is exactly the
distinction `/lib/init` branches a service on.
*/
package roletest

import "vsys:abi"
import "vsys:libuser"

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		libuser.exits(what)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	buf: [64]u8

	// This machine, `vectra`, is a terminal and a CPU server at once -- both
	// present, and both with an empty value, so presence is `ok`, not a value.
	_, term := libuser.ndb_attr("vectra", "terminal", buf[:])
	want(term, "the terminal role is present on vectra")
	_, cpu := libuser.ndb_attr("vectra", "cpu", buf[:])
	want(cpu, "the cpu role is present on vectra")

	// It is not a file server, and a role it does not carry reads false.
	_, fs := libuser.ndb_attr("vectra", "fs", buf[:])
	want(!fs, "the fs role is absent on vectra")

	// The gateway record carries no role at all.
	_, gwterm := libuser.ndb_attr("gw", "terminal", buf[:])
	want(!gwterm, "no role on the gateway record")

	// A record that does not exist answers false, not a stale match.
	_, none := libuser.ndb_attr("nosuchhost", "cpu", buf[:])
	want(!none, "an absent record answers false")

	libuser.exits("ok")
}
