// The ones that start, are started, or become another program.
package programs

import "vsys:abi"
import "vsys:libuser"

// parent spawns a child out of a file, waits for it twice, binds the
// console away, spawns it again, and asks for a file that is not there.
parent :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x50524E5450524E54
	pid := libuser.spawn("/bin/child", abi.SPAWN_NS_COPY)
	put(cells, 1, pid)
	put(cells, 2, libuser.wait(u64(pid)))
	put(cells, 3, libuser.wait(u64(pid)))
	put(cells, 4, libuser.bind("/dev/null", "/dev/cons", abi.ORDER_REPLACE))
	pid = libuser.spawn("/bin/child", abi.SPAWN_NS_COPY)
	put(cells, 5, pid)
	put(cells, 6, libuser.wait(u64(pid)))
	put(cells, 7, libuser.spawn("/bin/no-such", abi.SPAWN_NS_COPY))
	libuser.exit(0)
}

// child is what `parent` spawns: it opens the console by name, writes a
// line, and exits with the descriptor and the count packed into its status.
child :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x43484C4443484C44
	fd := libuser.open("/dev/cons", abi.O_WRONLY)
	put(cells, 1, fd)
	put(cells, 2, libuser.write(int(fd), transmute([]u8)string("-- a process started this one")))
	put(cells, 3, libuser.close(int(fd)))
	libuser.exit(u64(fd) << 8 | cells[2])
}

/*
poster publishes a service and mounts it by the name it published.

Open the console, create a name in /srv and write the console's descriptor
digit into it, twice, because the second write is refused. Close the name,
mount it at /mnt, and write a line through /mnt/cons. Remove the name, which
ends the name and not the service: an open of the name fails and the mount
still answers, through /mnt/null.
*/
poster :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x504F5354504F5354
	put(cells, 1, libuser.open("/dev/cons", abi.O_WRONLY))
	srv := libuser.create("/srv/cons2", abi.O_WRONLY, 384)
	put(cells, 2, srv)
	put(cells, 3, libuser.write(int(srv), transmute([]u8)string("3")))
	put(cells, 4, libuser.write(int(srv), transmute([]u8)string("3")))
	put(cells, 5, libuser.close(int(srv)))
	put(cells, 6, libuser.mount("/srv/cons2", "/mnt", abi.ORDER_REPLACE))
	line := transmute([]u8)string("-- this line went through a posted service")
	fd := libuser.open("/mnt/cons", abi.O_WRONLY)
	put(cells, 7, fd)
	put(cells, 8, libuser.write(int(fd), line))
	put(cells, 9, libuser.remove("/srv/cons2"))
	put(cells, 10, libuser.open("/srv/cons2", abi.O_WRONLY))
	fd = libuser.open("/mnt/null", abi.O_WRONLY)
	put(cells, 11, fd)
	put(cells, 12, libuser.write(int(fd), line))
	libuser.exit(0)
}

// execer replaces itself with the child program. The exit after it runs
// only if the exec came back, which it does only to say why not.
execer :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4558454345584543
	put(cells, 1, libuser.exec("/bin/child"))
	libuser.exit(0x66)
}
