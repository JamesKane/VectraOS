/*
The ring 3 test programs, as Odin.

`kernel/user/verify.odin` runs thirty-one small programs against the kernel:
one that spins until the tick catches it, ones that fault on purpose, ones
that open files, fork, post a service, catch a note, and one that answers
9P by hand. They were assembly once, one file per architecture, and a port
meant writing them all again. They are one package now, compiled once per
program for whichever architecture the kernel is built for, and the door
they knock on is `sys/libuser`'s.

**One program per build.** `PROGRAM` names the one `start` runs, and the
compiler emits only what that one reaches. `build.odin` compiles this
package once per name, links each at `TEXT_VA`, and keeps the one segment
that comes out as a flat blob the kernel embeds. The loader copies a blob
into a text page and starts it with three arguments: the data page, and
two numbers the self-test chose. Everything a program reports goes into the
data page's cells, eight bytes each, and `program.odin` names them.

**Nothing here has a runtime.** No context, no allocator, no globals, and
no bounds checks: a page of text holds a program and the three copies the
compiler links, and nothing else. A program that needs to wait spins on a
cell with a bound, because a program that hangs is a self-test that hangs.
A program that is done exits through the door. One that is meant to end on
a fault does so on an undefined instruction, which every architecture
reports as one.
*/
package programs

import "base:intrinsics"

// The program this build is. `build.odin` passes one of the names below.
PROGRAM :: #config(PROGRAM, "")

// Where the loader puts the data page. A note handler, which is called with
// no data pointer, finds the cells here.
DATA_VA :: uintptr(0x0040_1000)

Cells :: [512]u64
Page :: [4096]u8

// The bound on every wait, in rounds of a load. About a second of emulated
// ring 3, and fifty times what any wait here takes.
ROUNDS :: 400_000_000

@(export, link_name = "_start", link_section = ".text.start")
start :: proc "c" (cells: ^Cells, arg1, arg2: u64) -> ! {
	when PROGRAM == "spin" {
		spin(cells)
	} else when PROGRAM == "poke" {
		poke(cells, arg1)
	} else when PROGRAM == "peek" {
		peek(cells, arg1)
	} else when PROGRAM == "priv" {
		priv(cells)
	} else when PROGRAM == "jump" {
		jump(cells, arg1)
	} else when PROGRAM == "hello" {
		hello(cells, arg1)
	} else when PROGRAM == "probe" {
		probe(cells, arg1)
	} else when PROGRAM == "shadow" {
		shadow(cells)
	} else when PROGRAM == "namer" {
		namer(cells, arg1, arg2)
	} else when PROGRAM == "reader" {
		reader(cells, arg1)
	} else when PROGRAM == "binder" {
		binder(cells, arg1, arg2)
	} else when PROGRAM == "painter" {
		painter(cells, arg1, arg2)
	} else when PROGRAM == "bulkio" {
		bulkio(cells, arg1, arg2)
	} else when PROGRAM == "mapper" {
		mapper(cells, arg1)
	} else when PROGRAM == "anon" {
		anon(cells, arg1)
	} else when PROGRAM == "sharer" {
		sharer(cells)
	} else when PROGRAM == "sharedseg" {
		sharedseg(cells)
	} else when PROGRAM == "parent" {
		parent(cells)
	} else when PROGRAM == "child" {
		child(cells)
	} else when PROGRAM == "poster" {
		poster(cells)
	} else when PROGRAM == "execer" {
		execer(cells)
	} else when PROGRAM == "niner" {
		niner(cells)
	} else when PROGRAM == "noter" {
		noter(cells)
	} else when PROGRAM == "catcher" {
		catcher(cells)
	} else when PROGRAM == "dfltnote" {
		dfltnote(cells)
	} else when PROGRAM == "forker" {
		forker(cells)
	} else when PROGRAM == "memfork" {
		memfork(cells)
	} else when PROGRAM == "fdforker" {
		fdforker(cells, arg1)
	} else when PROGRAM == "refuser" {
		refuser(cells)
	} else when PROGRAM == "grouper" {
		grouper(cells)
	} else when PROGRAM == "nowaiter" {
		nowaiter(cells)
	} else {
		#panic("PROGRAM names no program; see build.odin's list")
	}
}

// -- What every program uses -------------------------------------------------

// die ends the program on an undefined instruction. Every architecture
// reports it as an invalid instruction, which is what the self-test expects
// of a program that ends without asking.
die :: proc "contextless" () -> ! {
	when ODIN_ARCH == .amd64 {
		asm() [#volatile, #clobber memory] { #byte 0x0F, 0x0B }() // ud2
	} else when ODIN_ARCH == .arm64 {
		asm() [#volatile, #clobber memory] { #byte 0x00, 0x00, 0x00, 0x00 }() // udf #0
	} else {
		asm() [#volatile, #clobber memory] { #byte 0x00, 0x00 }() // unimp
	}
	for {
	}
}

// bytes is the data page as bytes, for the paths and texts the self-test
// stages into it at the offsets `program.odin` names.
bytes :: proc "contextless" (cells: ^Cells) -> ^Page {
	return (^Page)(cells)
}

// slot is `n` bytes of the data page at `at`.
slot :: proc "contextless" (cells: ^Cells, at: int, n: u64) -> []u8 {
	return bytes(cells)[at:][:n]
}

// text is the same as a string, for the calls that take a path.
text :: proc "contextless" (cells: ^Cells, at: int, n: u64) -> string {
	return string(slot(cells, at, n))
}

// put records a call's answer in a cell, sign and all.
put :: proc "contextless" (cells: ^Cells, cell: int, value: i64) {
	cells[cell] = u64(value)
}

// bump counts one round in a cell, through memory every time, so another
// process sharing the page sees it move and the kernel can read it after.
bump :: proc "contextless" (cells: ^Cells, cell: int) {
	intrinsics.volatile_store(&cells[cell], intrinsics.volatile_load(&cells[cell]) + 1)
}

// wait_cell spins until a cell is nonzero, for at most `ROUNDS` rounds, and
// says whether it was. Every wait a program makes on another process goes
// through this, so no program can wait for ever.
wait_cell :: proc "contextless" (cells: ^Cells, cell: int) -> bool {
	for _ in 0 ..< ROUNDS {
		if intrinsics.volatile_load(&cells[cell]) != 0 {
			return true
		}
	}
	return false
}

// load64 and store64 touch memory at an address a program was handed, the
// kernel's or its own, through a volatile access the compiler cannot fold
// into what it knows.
load64 :: proc "contextless" (at: uintptr) -> u64 {
	return intrinsics.volatile_load((^u64)(at))
}

store64 :: proc "contextless" (at: uintptr, value: u64) {
	intrinsics.volatile_store((^u64)(at), value)
}

// seg_result is a segment call's answer as one number: the address, or the
// negative errno, which is how the self-test reads the cell.
seg_result :: proc "contextless" (addr: uintptr, err: i64) -> i64 {
	if err != 0 {
		return err
	}
	return i64(addr)
}
