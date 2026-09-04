/*
Vectra build driver.

Run it with:

    odin run build.odin -file -- <target> [options]

Targets:
    kernel   Compile and link kernel/ into build/vectra.elf   (default)
    user     Compile the ring 3 programs into build/user
    programs Compile the ring 3 test programs into build/programs
    check    Type-check the kernel and the programs, emit nothing
    esp      Stage a bootable EFI system partition in build/esp
    run      esp, then boot it under QEMU
    debug    run, but halted and waiting for gdb on :1234
    clean    Remove build/
    lint     Check the prose against ASD-STE100

Options:
    --arch=amd64|arm64|riscv64   Target architecture (default: amd64)
    --release                    Optimise, otherwise a debug build
    --serial=stdio|file          Where QEMU's COM1 goes (default: stdio)
    --monitor=PATH               A QEMU monitor on a unix socket, for screendump
    --gfx                        Open a QEMU window, otherwise headless
    --smp=N                      Cores QEMU presents (default: 4)

An Odin program rather than a shell script, for one reason. The flag handling,
the arch table and the link line will all grow per-architecture.

This way they grow in the same language, and the same type system, as the thing
they build. `justfile` and `Makefile` are thin wrappers over this.
*/
#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

BUILD_DIR :: "build"
ESP_DIR :: "build/esp"
SCRATCH_IMG :: "build/disk.img"
KERNEL_ELF :: "build/vectra.elf"
KERNEL_OBJ :: "build/vectra.o"

USER_DIR :: "build/user"
PROGRAMS_DIR :: "build/programs"

/*
The ring 3 programs this driver builds before the kernel.

Each is an ordinary Odin package, compiled freestanding, linked by
`sys/libuser/link_user.ld`, and converted from ELF to the flat VECTRA02
image the kernel's loader reads. The kernel then embeds the image with
`#load` and serves it from `/bin`, which is why these build first: the
kernel's compile is what consumes the artifact.
*/
User_Program :: struct {
	name: string, // The image's basename under build/user/
	path: string, // The package directory
}

user_programs := [?]User_Program {
	{name = "ramfs", path = "servers/ramfs"},
	{name = "consrv", path = "servers/consrv"},
	{name = "kbdfs", path = "servers/kbdfs"},
	{name = "eiafs", path = "servers/eiafs"},
	{name = "intuition", path = "servers/intuition"},
	{name = "terminal", path = "apps/terminal"},
	{name = "abitest", path = "tests/abi"},
	{name = "threadtest", path = "tests/thread"},
	{name = "mui", path = "tests/mui"},
	{name = "nettest", path = "tests/net"},
	{name = "rc", path = "apps/rc"},
	{name = "echo", path = "cmd/echo"},
	{name = "cat", path = "cmd/cat"},
	{name = "memfs", path = "servers/memfs"},
	{name = "fatfs", path = "servers/fatfs"},
	{name = "kfs", path = "servers/kfs"},
	{name = "pwd", path = "cmd/pwd"},
	{name = "mkdir", path = "cmd/mkdir"},
	{name = "rm", path = "cmd/rm"},
	{name = "cp", path = "cmd/cp"},
	{name = "mv", path = "cmd/mv"},
	{name = "cmp", path = "cmd/cmp"},
	{name = "wc", path = "cmd/wc"},
	{name = "tee", path = "cmd/tee"},
	{name = "tail", path = "cmd/tail"},
	{name = "basename", path = "cmd/basename"},
	{name = "cleanname", path = "cmd/cleanname"},
	{name = "test", path = "cmd/test"},
	{name = "seq", path = "cmd/seq"},
	{name = "sleep", path = "cmd/sleep"},
	{name = "read", path = "cmd/read"},
	{name = "bind", path = "cmd/bind"},
	{name = "mount", path = "cmd/mount"},
	{name = "unmount", path = "cmd/unmount"},
	{name = "env", path = "cmd/env"},
	{name = "sort", path = "cmd/sort"},
	{name = "uniq", path = "cmd/uniq"},
	{name = "tr", path = "cmd/tr"},
	{name = "ls", path = "cmd/ls"},
	{name = "grep", path = "cmd/grep"},
	{name = "sed", path = "cmd/sed"},
	{name = "ps", path = "cmd/ps"},
	{name = "kill", path = "cmd/kill"},
	{name = "ns", path = "cmd/ns"},
	{name = "window", path = "cmd/window"},
	{name = "muidemo", path = "apps/muidemo"},
}

/*
The ring 3 test programs `kernel/user/verify.odin` runs, one per name.

`kernel/user/programs` is one package, compiled once per name with
`-define:PROGRAM=<name>`, so the compiler emits only the program named.
Each links at the address the kernel's loader copies a program to, and the
one segment that comes out is kept as a flat page-sized blob the kernel
embeds with `#load`. That is what lets one suite serve three architectures.
*/
test_programs := [?]string{
	"spin", "poke", "peek", "priv", "jump",
	"hello", "probe", "shadow",
	"namer", "reader", "binder", "painter", "bulkio",
	"mapper", "anon", "sharer", "sharedseg",
	"parent", "child", "poster", "execer", "niner",
	"noter", "catcher", "dfltnote",
	"forker", "memfork", "fdforker", "refuser", "grouper", "nowaiter",
}

// The address the loader copies a program to, and the most it copies. The
// same numbers as `kernel/user/user.odin`'s TEXT_VA and the page, restated
// here because this file checks them before the kernel ever sees a blob.
PROGRAM_TEXT_VA :: u64(0x0040_0000)
PROGRAM_MAX :: 4096

Arch :: enum {
	amd64,
	arm64,
	riscv64,
}

/*
Per-architecture knobs.

`odin_target` and `ld_emulation` have to agree, and the linker script has to
match both. The three in one row is the cheapest way to stop a port from
silently linking an amd64 script into an arm64 image.
*/
Arch_Config :: struct {
	odin_target:   string,
	clang_target:  string,   // What clang assembles the `.S` files for
	asm_sources:   []string, // The `.S` files the kernel links, this arch's own
	ld_emulation:  string,
	link_script:   string,
	qemu:          string,
	qemu_machine:  []string,
	efi_boot_name: string,

	// The UEFI firmware QEMU boots: the code image and the variable store
	// that ship beside every QEMU install, as edk2 builds them. The vars
	// image is copied somewhere writable first, because UEFI writes it. The
	// i386 name on amd64 is not a mistake: QEMU ships one vars image for
	// both x86 targets, and the arm name on arm64 is the same story.
	fw_code:       string,
	fw_vars:       string,
}

/*
The assembly the kernel links beside its own object, per architecture. The
interrupt stubs, the syscall entry, the GDT reload, and the FPU hold the
scheduler's self-test spins in.

**These are files rather than `asm` blocks because a block cannot define a
symbol.** Odin's inline assembly is a template since `dev-2026-09`, checked
against the target's encoding tables, with labels that never leave it. The
CPU enters the stubs, the programs are bytes under global names, and the GDT
reload needs the address of its own landing label. clang assembles each into
an ELF object and `ld.lld` takes them with `vectra.o`. The `.S` files keep
the AT&T syntax the blocks always had, `$` and all.

Every one of them is the architecture's, which is why the list is a row of
this table. A port writes its own and names them here. The files carry the
`_amd64` suffix or live under `arch/amd64`, so nothing generic holds machine
code.
*/
asm_amd64 := [?]string{
	"kernel/arch/amd64/isr.S",
	"kernel/arch/amd64/syscall_entry.S",
	"kernel/arch/amd64/gdt.S",
	"kernel/arch/amd64/fpu_hold.S",
	"kernel/arch/amd64/ap.S",
}

// The vector table and its tail, the AP stack switch, and the
// vector-register hold. See `docs/PORTS.md`.
asm_arm64 := [?]string{
	"kernel/arch/arm64/vectors.S",
	"kernel/arch/arm64/ap.S",
	"kernel/arch/arm64/fpu_hold.S",
}

asm_riscv64 := [?]string{
	"kernel/arch/riscv64/vectors.S",
	"kernel/arch/riscv64/ap.S",
	"kernel/arch/riscv64/fpu_hold.S",
}


// Machine lines live at package scope: a slice of a compound literal built
// inside arch_config would point into that call's stack frame.
//
// The two `virt` boards get a `ramfb`, which is the one display device the
// firmware's GOP drives without a driver of ours, so the bootloader hands
// over a framebuffer and the chassis console comes up. The GIC is pinned to
// version 2, which is the one `kernel/arch/arm64/gic.odin` speaks. ACPI is
// off on riscv64, because the firmware publishes either ACPI tables or the
// device tree and not both, and the tree is the one word on the clock rate
// this kernel can read. See `docs/PORTS.md`.
qemu_amd64_machine := [?]string{"-machine", "q35", "-cpu", "qemu64", "-m", "512M"}
qemu_arm64_machine := [?]string{"-machine", "virt,gic-version=2", "-cpu", "cortex-a72", "-m", "512M", "-device", "ramfb"}
qemu_riscv64_machine := [?]string{"-machine", "virt,acpi=off", "-cpu", "rv64", "-m", "512M", "-device", "ramfb"}

arch_config :: proc(arch: Arch) -> Arch_Config {
	switch arch {
	case .amd64:
		return {
			odin_target   = "freestanding_amd64_sysv",
			clang_target  = "x86_64-unknown-elf",
			asm_sources   = asm_amd64[:],
			ld_emulation  = "elf_x86_64",
			link_script   = "kernel/link_amd64.ld",
			qemu          = "qemu-system-x86_64",
			qemu_machine  = qemu_amd64_machine[:],
			efi_boot_name = "BOOTX64.EFI",
			fw_code       = "edk2-x86_64-code.fd",
			fw_vars       = "edk2-i386-vars.fd",
		}
	case .arm64:
		return {
			odin_target   = "freestanding_arm64",
			clang_target  = "aarch64-unknown-elf",
			asm_sources   = asm_arm64[:],
			ld_emulation  = "aarch64elf",
			link_script   = "kernel/link_arm64.ld",
			qemu          = "qemu-system-aarch64",
			qemu_machine  = qemu_arm64_machine[:],
			efi_boot_name = "BOOTAA64.EFI",
			fw_code       = "edk2-aarch64-code.fd",
			fw_vars       = "edk2-arm-vars.fd",
		}
	case .riscv64:
		return {
			odin_target   = "freestanding_riscv64",
			clang_target  = "riscv64-unknown-elf",
			asm_sources   = asm_riscv64[:],
			ld_emulation  = "elf64lriscv",
			link_script   = "kernel/link_riscv64.ld",
			qemu          = "qemu-system-riscv64",
			qemu_machine  = qemu_riscv64_machine[:],
			efi_boot_name = "BOOTRISCV64.EFI",
			fw_code       = "edk2-riscv-code.fd",
			fw_vars       = "edk2-riscv-vars.fd",
		}
	}
	return {}
}

Options :: struct {
	target:  string,
	arch:    Arch,
	release: bool,
	serial:  string,
	monitor: string,
	gfx:     bool,
	smp:     int,

	// Everything after the target, handed to the target untouched. Only
	// `lint` reads it, so that `build lint --show docs` reaches the checker.
	passthrough: []string,
}

main :: proc() {
	opts := Options {
		target = "kernel",
		arch   = .amd64,
		serial = "stdio",
		smp    = 4,
	}

	positional_seen := false
	rest: [dynamic]string
	defer delete(rest)
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--arch="):
			name := arg[len("--arch="):]
			switch name {
			case "amd64", "x86_64": opts.arch = .amd64
			case "arm64", "aarch64": opts.arch = .arm64
			case "riscv64", "rv64": opts.arch = .riscv64
			case:
				die("unknown --arch=%s (want amd64, arm64, riscv64)", name)
			}
		case strings.has_prefix(arg, "--serial="):
			opts.serial = arg[len("--serial="):]
		case strings.has_prefix(arg, "--monitor="):
			opts.monitor = arg[len("--monitor="):]
		case strings.has_prefix(arg, "--smp="):
			n, ok := strconv.parse_int(arg[len("--smp="):])
			if !ok || n < 1 {
				die("bad --smp=%s (want a core count of 1 or more)", arg[len("--smp="):])
			}
			opts.smp = n
		case arg == "--release":
			opts.release = true
		case arg == "--gfx":
			opts.gfx = true
		case strings.has_prefix(arg, "-"):
			// An option this script does not know is an error, unless a
			// target has already claimed the line. Then it belongs to
			// the target -- see `Options.passthrough`.
			if !positional_seen {
				die("unknown option %s", arg)
			}
			append(&rest, arg)
		case:
			if positional_seen {
				append(&rest, arg)
				continue
			}
			opts.target = arg
			positional_seen = true
		}
	}
	opts.passthrough = rest[:]

	switch opts.target {
	case "kernel":   build_kernel(opts)
	case "user":     build_user(opts)
	case "programs": build_programs(opts)
	case "check":    check(opts)
	case "esp":    stage_esp(opts)
	case "run":    stage_esp(opts); run_qemu(opts, debug = false)
	case "debug":  stage_esp(opts); run_qemu(opts, debug = true)
	case "clean":  clean()
	case "lint":   lint(opts)
	case:
		die("unknown target %q (want kernel, user, programs, check, esp, run, debug, clean, lint)", opts.target)
	}
}

// -- Targets -----------------------------------------------------------------

build_kernel :: proc(opts: Options) {
	cfg := arch_config(opts.arch)
	ensure_dir(BUILD_DIR)

	// The programs first, because the kernel's own compile `#load`s their
	// images into `/bin` and the test blobs into its self-test. A kernel
	// built after them is a kernel that runs what was just built, never
	// something stale.
	build_user(opts)
	build_programs(opts)

	step("compiling kernel for %s", cfg.odin_target)

	compile := [dynamic]string{
		"odin", "build", "kernel",
		fmt.tprintf("-out:%s", KERNEL_OBJ),
		"-build-mode:obj",
		fmt.tprintf("-target:%s", cfg.odin_target),
		"-collection:kernel=kernel",
		"-collection:vsys=sys",

		// Freestanding contract: no libc, no runtime entry point, and no heap.
		// -default-to-nil-allocator turns an accidental `new`/`make` into an
		// immediate nil rather than a call into an allocator we do not have.
		"-no-crt",
		"-no-entry-point",
		"-default-to-nil-allocator",

		// PIC + a single module so the bootloader gets one relocatable image;
		// -disable-red-zone because interrupt handlers will scribble on it.
		"-reloc-mode:pic",
		"-disable-red-zone",
		"-use-single-module",

		// Odin's thread-local storage assumes a platform TLS block. Vectra will
		// do per-CPU state through GS instead, so emitting STT_TLS symbols here
		// only produces a link error about a missing PT_TLS segment.
		"-no-thread-local",

		"-vet",
		"-strict-style",
		"-disallow-do",
	}
	if opts.release {
		append(&compile, "-o:speed", "-no-bounds-check")
	} else {
		append(&compile, "-debug", "-o:none")
	}
	run(compile[:])

	// The assembly, one object each. `-target` names the ELF the kernel is
	// and not the host clang runs on. That is what lets a macOS clang
	// assemble for this link at all.
	objects := [dynamic]string{KERNEL_OBJ}
	for src in cfg.asm_sources {
		obj := fmt.tprintf("%s/%s.o", BUILD_DIR, filepath_stem(src))
		assemble(cfg, opts.arch, src, obj)
		append(&objects, obj)
	}

	step("linking %s", KERNEL_ELF)
	link := [dynamic]string{"ld.lld"}
	append(&link, ..objects[:])
	append(&link,
		"-o", KERNEL_ELF,
		"-m", cfg.ld_emulation,
		"-T", cfg.link_script,
		"-nostdlib",
		"-static",
		"-pie",
		"--no-dynamic-linker",
		"-z", "text",
		"-z", "max-page-size=0x1000",
	)
	run(link[:])

	if info, err := os.stat(KERNEL_ELF, context.allocator); err == nil {
		step("kernel image is %d bytes", info.size)
	}
}

// assemble turns one `.S` into an object for the arch's ELF. `-target`
// names the ELF and not the host clang runs on, which is what lets a macOS
// clang assemble for this link at all.
assemble :: proc(cfg: Arch_Config, arch: Arch, src: string, obj: string) {
	step("assembling %s", src)
	args := [dynamic]string{"clang", "-target", cfg.clang_target}
	if arch == .riscv64 {
		// The assembler needs telling which extensions the `.S` files
		// use; the compiler already knows for the Odin.
		append(&args, "-march=rv64gc_zihintpause")
	}
	append(&args, "-c", src, "-o", obj)
	run(args[:])
}

/*
build_user compiles the ring 3 programs and converts each to a flat image.

The same compiler, target and vets as the kernel, minus the pieces only a
bootloader payload needs: no PIC, because the loader maps every program at
the one address `link_user.ld` names, and no single-module, because nothing
here is relinked by anything else. Always optimised -- a program is a file
the kernel embeds, and nobody debugs it with a host debugger anyway.
*/
build_user :: proc(opts: Options) {
	cfg := arch_config(opts.arch)
	ensure_dir(BUILD_DIR)
	ensure_dir(USER_DIR)

	// The one `.S` a ring 3 program links: `sys/libthread`'s thread switch
	// and its fork onto a new stack, a file for the reason the kernel's
	// are. Linked into every program rather than named per program,
	// because it is a hundred bytes and a table column nothing else would
	// use. A program that never imports `libthread` carries the two
	// symbols unreferenced.
	thread_obj := fmt.tprintf("%s/libthread.o", USER_DIR)
	assemble(cfg, opts.arch, fmt.tprintf("sys/libthread/thread_%v.S", opts.arch), thread_obj)

	for prog in user_programs {
		step("compiling %s for ring 3", prog.path)
		obj := fmt.tprintf("%s/%s.o", USER_DIR, prog.name)
		elf := fmt.tprintf("%s/%s.elf", USER_DIR, prog.name)
		img := fmt.tprintf("%s/%s.vx", USER_DIR, prog.name)

		compile_ring3(cfg, prog.path, obj, {})
		link_ring3(cfg, obj, elf, "sys/libuser/link_user.ld", {thread_obj})
		elf_to_image(elf, img)
	}
	write_pak()
}

/*
write_pak gathers every program image into one file the kernel embeds.

    "VPAK" u32 count, then per program: u32 name length, u32 image size,
    the name, the image

One `#load` in `kernel/user/image.odin` rather than one per program, so a
new tool is a line in `user_programs` and nothing in the kernel. Little
endian, unaligned, because the kernel reads the header a byte at a time and
hands each image to the loader as a slice.
*/
write_pak :: proc() {
	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	append(&out, "VPAK")
	put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	put_u32(&out, u32(len(boot_programs)))
	total := 0
	for name in boot_programs {
		img := fmt.tprintf("%s/%s.vx", USER_DIR, name)
		data, rerr := os.read_entire_file_from_path(img, context.allocator)
		if rerr != nil {
			die("cannot read %s", img)
		}
		put_u32(&out, u32(len(name)))
		put_u32(&out, u32(len(data)))
		append(&out, name)
		append(&out, ..data)
		total += len(data)
	}
	pak := fmt.tprintf("%s/programs.pak", USER_DIR)
	if werr := os.write_entire_file(pak, out[:]); werr != nil {
		die("cannot write %s", pak)
	}
	step("%s holds %d programs, %d bytes", pak, len(boot_programs), total)
}

/*
The programs the kernel carries in its own image: what it takes to reach
the disk and run a script off it. Everything else in `user_programs` is
staged into `build/esp/vectra/bin` and comes from the disk, through
`fatfs`, at `/bin` -- see `docs/SHELL.md` step 6. A tool that only lives on
the disk is a tool the kernel image does not grow by.
*/
boot_programs := [?]string{"fatfs", "rc"}

/*
The flags every ring 3 compile and check shares: the freestanding contract
and the vets. `ring3_build_flags` adds what only a build takes -- no C
runtime, no red zone, no thread-local storage, and speed, because a program
is a file the kernel embeds and nobody debugs one with a host debugger. No
PIC, because the loader maps every program at the one address its link
script names, and no single module, because nothing here is relinked by
anything else.
*/
ring3_check_flags := [?]string{
	"-collection:vsys=sys",
	"-no-entry-point",
	"-default-to-nil-allocator",
	"-vet",
	"-strict-style",
	"-disallow-do",
	"-no-bounds-check",
}

ring3_build_flags := [?]string{
	"-no-crt",
	"-disable-red-zone",
	"-no-thread-local",
	"-o:speed",
}

// compile_ring3 compiles one ring 3 package to an object, with `extra`
// for the flags one caller adds.
compile_ring3 :: proc(cfg: Arch_Config, pkg: string, obj: string, extra: []string) {
	args := [dynamic]string{"odin", "build", pkg, fmt.tprintf("-out:%s", obj), "-build-mode:obj", fmt.tprintf("-target:%s", cfg.odin_target)}
	append(&args, ..ring3_check_flags[:])
	append(&args, ..ring3_build_flags[:])
	append(&args, ..extra)
	run(args[:])
}

/*
link_ring3 links a ring 3 object by the script a caller names.

`-z norelro`, because the linker otherwise carves a read-only segment for
the GOT out of `.data` and starts `.bss` where that ends, mid-page. The
loader maps whole pages, and each link script exists so every segment
starts on one.
*/
link_ring3 :: proc(cfg: Arch_Config, obj: string, elf: string, script: string, extra: []string = nil) {
	args := [dynamic]string{"ld.lld", obj}
	append(&args, ..extra)
	append(&args,
		"-o", elf,
		"-m", cfg.ld_emulation,
		"-T", script,
		"-nostdlib",
		"-static",
		"-z", "norelro",
	)
	run(args[:])
}

/*
build_programs compiles the ring 3 test programs, one blob each.

The same target and vets as the ring 3 programs, with the one program
selected by `-define`. The link is the test layout, one segment at the
loader's address, and `elf_to_blob` keeps that segment's bytes and refuses
anything else: a second segment is a global the program must not have, and
a segment past a page is a program the loader will not copy.
*/
build_programs :: proc(opts: Options) {
	cfg := arch_config(opts.arch)
	ensure_dir(BUILD_DIR)
	ensure_dir(PROGRAMS_DIR)

	for name in test_programs {
		step("compiling test program %s", name)
		obj := fmt.tprintf("%s/%s.o", PROGRAMS_DIR, name)
		elf := fmt.tprintf("%s/%s.elf", PROGRAMS_DIR, name)
		bin := fmt.tprintf("%s/%s.bin", PROGRAMS_DIR, name)

		compile_ring3(cfg, "kernel/user/programs", obj, {fmt.tprintf("-define:PROGRAM=%s", name)})
		link_ring3(cfg, obj, elf, "kernel/user/programs/link_program.ld")
		elf_to_blob(elf, bin)
	}
}

/*
elf_to_blob keeps a test program's one segment as the bytes the loader
copies.

One `PT_LOAD`, readable and executable, not writable, with no bytes the
file does not hold, at the loader's address and inside its page. A program
that asks for more is refused here, with the reason, rather than loaded
short or not at all.
*/
elf_to_blob :: proc(elf_path: string, out_path: string) {
	data := read_elf(elf_path)
	defer delete(data)

	phoff := int(u64le(data, 32))
	phentsize := int(u16le(data, 54))
	phnum := int(u16le(data, 56))

	found := 0
	offset, size := 0, 0
	for i in 0 ..< phnum {
		at := phoff + i * phentsize
		if u32(u32le(data, at)) != ELF_PT_LOAD || u64le(data, at + 40) == 0 {
			continue
		}
		found += 1
		flags := u32(u32le(data, at + 4))
		vaddr := u64le(data, at + 16)
		filesz := u64le(data, at + 32)
		memsz := u64le(data, at + 40)
		if flags & ELF_PF_W != 0 || memsz != filesz {
			die("%s: a writable segment, which is a global a test program may not have", elf_path)
		}
		if vaddr != PROGRAM_TEXT_VA {
			die("%s: segment at %x, and the loader copies to %x", elf_path, vaddr, PROGRAM_TEXT_VA)
		}
		if memsz > PROGRAM_MAX {
			die("%s: %d bytes, and the loader copies one page of %d", elf_path, memsz, PROGRAM_MAX)
		}
		offset = int(u64le(data, at + 8))
		size = int(filesz)
	}
	if found != 1 {
		die("%s: %d loadable segments (want exactly 1)", elf_path, found)
	}
	if offset + size > len(data) {
		die("%s: segment payload runs past the file", elf_path)
	}
	if werr := os.write_entire_file(out_path, data[offset:][:size]); werr != nil {
		die("cannot write %s", out_path)
	}
	step("%s is %d bytes", out_path, size)
}

// read_elf reads a linked program whole and checks it is the ELF the two
// converters below read: 64-bit, little-endian, and long enough to have a
// header. The caller frees it.
read_elf :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		die("cannot read %s", path)
	}
	if len(data) < 64 || data[0] != 0x7F || data[1] != 'E' || data[2] != 'L' || data[3] != 'F' {
		die("%s is not an ELF file", path)
	}
	if data[4] != 2 || data[5] != 1 {
		die("%s is not a little-endian 64-bit ELF", path)
	}
	return data
}

// The little-endian fields an ELF header and its program headers are made of.
u16le :: proc(b: []u8, at: int) -> u64 {
	return u64(b[at]) | u64(b[at + 1]) << 8
}

u32le :: proc(b: []u8, at: int) -> u64 {
	v := u64(0)
	for i in 0 ..< 4 {
		v |= u64(b[at + i]) << (8 * u64(i))
	}
	return v
}

u64le :: proc(b: []u8, at: int) -> u64 {
	v := u64(0)
	for i in 0 ..< 8 {
		v |= u64(b[at + i]) << (8 * u64(i))
	}
	return v
}

// The VECTRA02 constants, written here and in `kernel/user/image.odin`. The
// two cannot share a definition -- this file builds the image and that one
// loads it, and neither can import the other -- so they live beside a loud
// check: the loader refuses anything these emit wrongly.
IMG2_MAGIC :: u64(0x3230_4152_5443_4556) // "VECTRA02"
IMG2_MAX_SEGS :: 4
IMG2_FLAG_W :: u64(1)
IMG2_FLAG_X :: u64(2)

ELF_PT_LOAD :: u32(1)
ELF_PF_X :: u32(1)
ELF_PF_W :: u32(2)

/*
elf_to_image converts a linked program to the flat form the loader reads.

An ELF's `PT_LOAD` segments already say everything the loader wants -- where,
how many file bytes, how many memory bytes, which permissions -- so the image
is those rows and their payloads, behind a header the kernel can check. What
is refused here is what the loader would otherwise have to tolerate: a
segment that starts mid-page shares a page with bytes that want different
flags, and `link_user.ld` exists so that never links.
*/
elf_to_image :: proc(elf_path: string, out_path: string) {
	data := read_elf(elf_path)
	defer delete(data)

	entry := u64le(data, 24)
	phoff := int(u64le(data, 32))
	phentsize := int(u16le(data, 54))
	phnum := int(u16le(data, 56))

	Seg :: struct {
		vaddr:  u64,
		filesz: u64,
		memsz:  u64,
		flags:  u64,
		offset: int,
	}
	segs: [dynamic]Seg
	defer delete(segs)

	for i in 0 ..< phnum {
		at := phoff + i * phentsize
		if u32(u32le(data, at)) != ELF_PT_LOAD {
			continue
		}
		flags := u32(u32le(data, at + 4))
		seg := Seg {
			vaddr  = u64le(data, at + 16),
			filesz = u64le(data, at + 32),
			memsz  = u64le(data, at + 40),
			offset = int(u64le(data, at + 8)),
		}
		if seg.memsz == 0 {
			continue
		}
		if flags & ELF_PF_W != 0 {
			seg.flags |= IMG2_FLAG_W
		}
		if flags & ELF_PF_X != 0 {
			seg.flags |= IMG2_FLAG_X
		}
		if seg.vaddr % 0x1000 != 0 {
			die("%s: segment at %x is not page-aligned; see link_user.ld", elf_path, seg.vaddr)
		}
		if seg.filesz > seg.memsz {
			die("%s: segment at %x has more file than memory", elf_path, seg.vaddr)
		}
		append(&segs, seg)
	}
	if len(segs) == 0 || len(segs) > IMG2_MAX_SEGS {
		die("%s: %d loadable segments (want 1..%d)", elf_path, len(segs), IMG2_MAX_SEGS)
	}

	out: [dynamic]u8
	defer delete(out)
	put :: proc(out: ^[dynamic]u8, v: u64) {
		for i in 0 ..< 8 {
			append(out, u8(v >> (8 * u64(i))))
		}
	}
	put(&out, IMG2_MAGIC)
	put(&out, entry)
	put(&out, u64(len(segs)))
	put(&out, 0)
	for seg in segs {
		put(&out, seg.vaddr)
		put(&out, seg.filesz)
		put(&out, seg.memsz)
		put(&out, seg.flags)
	}
	for seg in segs {
		if seg.offset + int(seg.filesz) > len(data) {
			die("%s: segment payload runs past the file", elf_path)
		}
		for i in 0 ..< int(seg.filesz) {
			append(&out, data[seg.offset + i])
		}
	}

	if werr := os.write_entire_file(out_path, out[:]); werr != nil {
		die("cannot write %s", out_path)
	}
	step("%s is %d bytes in %d segments, entry %x", out_path, len(out), len(segs), entry)
}

/*
stage_esp builds an EFI system partition as a plain directory.

QEMU's vvfat backend (`-drive format=raw,file=fat:rw:<dir>`) presents that
directory to the firmware as a FAT volume. There is no disk image to build, and
no loop device to mount.

That is what makes this work unmodified on macOS, where losetup and mkfs.vfat
do not exist.
*/
stage_esp :: proc(opts: Options) {
	build_kernel(opts)
	cfg := arch_config(opts.arch)

	step("staging EFI system partition in %s", ESP_DIR)
	ensure_dir(ESP_DIR)
	ensure_dir(fmt.tprintf("%s/EFI", ESP_DIR))
	ensure_dir(fmt.tprintf("%s/EFI/BOOT", ESP_DIR))

	copy_file(
		fmt.tprintf("boot/limine/%s", cfg.efi_boot_name),
		fmt.tprintf("%s/EFI/BOOT/%s", ESP_DIR, cfg.efi_boot_name),
	)
	// Limine looks next to its own EFI executable first. The config goes there,
	// rather than at the volume root, where another limine.conf could shadow it.
	copy_file("boot/limine.conf", fmt.tprintf("%s/EFI/BOOT/limine.conf", ESP_DIR))
	copy_file(KERNEL_ELF, fmt.tprintf("%s/vectra.elf", ESP_DIR))
	stage_vectra()
}

/*
stage_vectra puts the programs and the library on the disk, under
`vectra/`, where `fatfs` serves them and the boot binds them over `/bin`
and `/lib`. Every program image under `bin/` by its `/bin` name, `rcmain`
and the test script under `lib/`, and an empty `tmp/` for what a running
machine writes back to the host.
*/
stage_vectra :: proc() {
	root := fmt.tprintf("%s/vectra", ESP_DIR)
	ensure_dir(root)
	ensure_dir(fmt.tprintf("%s/bin", root))
	ensure_dir(fmt.tprintf("%s/lib", root))
	ensure_dir(fmt.tprintf("%s/lib/tests", root))
	// Fresh each build: what the last run wrote there was the last run's
	// proof, and vvfat leaves a removed directory behind as its short name.
	run({"rm", "-rf", fmt.tprintf("%s/tmp", root)})
	ensure_dir(fmt.tprintf("%s/tmp", root))
	for prog in user_programs {
		copy_file(fmt.tprintf("%s/%s.vx", USER_DIR, prog.name), fmt.tprintf("%s/bin/%s", root, prog.name))
	}
	copy_file("apps/rc/rcmain", fmt.tprintf("%s/lib/rcmain", root))
	copy_file("apps/rc/init", fmt.tprintf("%s/lib/init", root))
	// The draw server's two files: the chords, and where a window opens.
	copy_file("servers/intuition/keys", fmt.tprintf("%s/lib/keys", root))
	copy_file("servers/intuition/workspaces", fmt.tprintf("%s/lib/workspaces", root))
	copy_file("tests/tools.rc", fmt.tprintf("%s/lib/tests/tools.rc", root))
	step("staged %d programs and the library under %s", len(user_programs), root)
}

run_qemu :: proc(opts: Options, debug: bool) {
	cfg := arch_config(opts.arch)

	args := [dynamic]string{cfg.qemu}
	append(&args, ..cfg.qemu_machine)

	// UEFI firmware. A combined OVMF image, when one is around, goes in whole
	// via -bios. Otherwise the split edk2 code+vars pair that every QEMU
	// install ships is loaded as two pflash devices -- the code read-only,
	// the vars copied somewhere writable first, because UEFI writes them.
	combined := "../odin-os/ovmf/ovmf_x64.fd"
	if opts.arch == .amd64 && os.exists(combined) {
		append(&args, "-bios", combined)
	} else {
		share := ""
		for dir in ([]string{"/opt/homebrew/share/qemu", "/usr/local/share/qemu", "/usr/share/qemu"}) {
			if os.exists(fmt.tprintf("%s/%s", dir, cfg.fw_code)) {
				share = dir
				break
			}
		}
		if share == "" {
			die("no %s beside QEMU -- UEFI boot needs one", cfg.fw_code)
		}
		vars := fmt.tprintf("%s/%s", BUILD_DIR, cfg.fw_vars)
		if !os.exists(vars) {
			copy_file(fmt.tprintf("%s/%s", share, cfg.fw_vars), vars)
		}
		// Flash unit 0 is the firmware and unit 1 its variables, on every
		// board alike.
		append(&args, "-drive", fmt.tprintf("if=pflash,unit=0,format=raw,readonly=on,file=%s/%s", share, cfg.fw_code))
		append(&args, "-drive", fmt.tprintf("if=pflash,unit=1,format=raw,file=%s", vars))
	}

	// The ESP and a scratch disk, both over virtio-blk-pci, on every board.
	// One transport, one driver: `-device virtio-blk-pci` attaches the drive
	// to the PCI bus that q35 and the two `virt` boards all have, where the
	// firmware's UEFI stack finds the ESP and boots it, and `kernel/drivers/
	// virtio` finds both from the PCI bus itself. See `docs/DISK.md`.
	ensure_scratch_disk()
	append(&args, "-drive", fmt.tprintf("if=none,id=esp,format=raw,file=fat:rw:%s", ESP_DIR))
	append(&args, "-device", "virtio-blk-pci,drive=esp,bootindex=0,disable-legacy=on")
	append(&args, "-drive", fmt.tprintf("if=none,id=scratch,format=raw,file=%s", SCRATCH_IMG))
	append(&args, "-device", "virtio-blk-pci,drive=scratch,disable-legacy=on")
	// A virtio-net card on QEMU's user-mode network. SLIRP answers ARP for the
	// gateway at 10.0.2.2, which is what the kernel's net self-test round-trips
	// against. `docs/FLEET.md` step 0's bench replaces this with a socket
	// network between two machines.
	append(&args, "-netdev", "user,id=n0")
	append(&args, "-device", "virtio-net-pci,netdev=n0,disable-legacy=on")
	// More than one core, because the kernel starts every core the
	// bootloader lists and the self-tests run across them. `--smp=1` is
	// the uniprocessor control.
	append(&args, "-smp", fmt.tprintf("%d", opts.smp))

	switch opts.serial {
	case "stdio": append(&args, "-serial", "stdio")
	case "file":  append(&args, "-serial", "file:build/serial.log")
	case:         die("unknown --serial=%s (want stdio or file)", opts.serial)
	}

	// A QMP-less monitor on a unix socket, for a host that wants to drive the
	// machine -- `screendump` for a screenshot, most of all. Off unless asked.
	if opts.monitor != "" {
		append(&args, "-monitor", fmt.tprintf("unix:%s,server,nowait", opts.monitor))
	}

	if !opts.gfx {
		// Headless still renders: the framebuffer is real, we just are not
		// showing it. `--gfx` opens the window when you want to see the chassis.
		append(&args, "-display", "none")
	}

	if debug {
		append(&args, "-s", "-S")
		step("QEMU halted, waiting for gdb on localhost:1234")
	}

	step("booting %s", cfg.qemu)
	run(args[:])
}

clean :: proc() {
	step("removing %s", BUILD_DIR)
	run({"rm", "-rf", BUILD_DIR})
}

/*
check type-checks the kernel and every ring 3 program for one architecture,
and emits nothing.

The same target and the same vets the build uses, without the link, so a
port's compile errors arrive in seconds rather than after six programs are
built. `--arch` selects the architecture, and a tree that passes for all
three is a tree where nothing generic holds machine code.
*/
check :: proc(opts: Options) {
	cfg := arch_config(opts.arch)
	// The kernel `#load`s the test blobs, so they have to exist to check
	// it, and building them is also the check of their package.
	build_programs(opts)
	step("checking kernel for %s", cfg.odin_target)
	run({
		"odin", "check", "kernel",
		fmt.tprintf("-target:%s", cfg.odin_target),
		"-collection:kernel=kernel",
		"-collection:vsys=sys",
		"-no-entry-point",
		"-default-to-nil-allocator",
		"-vet",
		"-strict-style",
	})
	for prog in user_programs {
		step("checking %s for %s", prog.path, cfg.odin_target)
		args := [dynamic]string{"odin", "check", prog.path, fmt.tprintf("-target:%s", cfg.odin_target)}
		append(&args, ..ring3_check_flags[:])
		run(args[:])
	}
}

// -- Process and file helpers ------------------------------------------------

// filepath_stem is a path's last component without its extension, which is
// what an object file is named after: `kernel/user/programs.S` assembles to
// `build/programs.o`.
filepath_stem :: proc(path: string) -> string {
	name := path
	if i := strings.last_index_byte(name, '/'); i >= 0 {
		name = name[i + 1:]
	}
	if i := strings.last_index_byte(name, '.'); i > 0 {
		name = name[:i]
	}
	return name
}

run :: proc(command: []string) {
	desc := os.Process_Desc {
		command = command,
		stdout  = os.stdout,
		stderr  = os.stderr,
		stdin   = os.stdin,
	}

	process, start_err := os.process_start(desc)
	if start_err != nil {
		die("could not start %s: %v", command[0], start_err)
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		die("could not wait on %s: %v", command[0], wait_err)
	}
	if !state.success || state.exit_code != 0 {
		die("%s exited with %d", command[0], state.exit_code)
	}
}

ensure_dir :: proc(path: string) {
	if os.exists(path) {
		return
	}
	if err := os.make_directory(path); err != nil {
		die("could not create %s: %v", path, err)
	}
}

/*
copy_file rewrites the destination whole.

Deliberately not a mtime check. A stale kernel.elf on the ESP, that boots as
though the edit worked, is the single most expensive bug in an OS build system.
*/
/*
ensure_scratch_disk writes a raw disk image for the virtio-blk driver to
read and write, if one of the right shape is not there already.

Sixty-four megabytes, with a master boot record at sector zero naming two
partitions: a small FAT-typed one at sector 64 with a marker at its first
sector, so the kernel's self-test can prove a partition file reaches the
partition and not the disk, and a Plan 9 one from sector 2048 to the end,
which kfs reams the first time it sees it and keeps after. It is left alone
once made, so a write the machine does to it is still there the next boot
-- which is the persistence a real disk has and the ESP's vvfat backend
does not.
*/
ensure_scratch_disk :: proc() {
	if os.exists(SCRATCH_IMG) {
		if info, err := os.stat(SCRATCH_IMG, context.allocator); err == nil && info.size == SCRATCH_SECTORS * 512 {
			return
		}
		// A different shape: an image from before this layout. Remade,
		// because the table and the partitions have moved.
		step("remaking %s in the current layout", SCRATCH_IMG)
	} else {
		step("making a %s scratch disk", SCRATCH_IMG)
	}
	image := make([]u8, SCRATCH_SECTORS * 512, context.allocator)

	// The MBR: two entries at 446, the 0x55AA signature, and a bootstrap
	// area left zero so the kernel does not mistake this for a volume boot
	// record. The first partition, type 0x0C (FAT32 LBA), is the disk
	// self-test's window, with a marker at its first sector. The second,
	// type 0x39 (Plan 9), is the rest of the disk and kfs's.
	entry := 446
	image[entry + 4] = 0x0C
	put_le32(image[entry + 8:], DOS_PART_START)
	put_le32(image[entry + 12:], DOS_PART_SECTORS)
	entry += 16
	image[entry + 4] = 0x39
	put_le32(image[entry + 8:], KFS_PART_START)
	put_le32(image[entry + 12:], SCRATCH_SECTORS - KFS_PART_START)
	image[510] = 0x55
	image[511] = 0xAA

	copy(image[DOS_PART_START * 512:], transmute([]u8)string("VECTRA-PART0\n"))

	if werr := os.write_entire_file(SCRATCH_IMG, image); werr != nil {
		die("could not write %s: %v", SCRATCH_IMG, werr)
	}
}

// The scratch disk's shape: 64 MiB of 512-byte sectors, a small FAT-typed
// partition for the disk self-test, and a Plan 9 partition for kfs from
// sector 2048 to the end.
SCRATCH_SECTORS :: 131072
DOS_PART_START :: 64
DOS_PART_SECTORS :: 256
KFS_PART_START :: 2048

put_le32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

copy_file :: proc(src, dst: string) {
	data, err := os.read_entire_file_from_path(src, context.allocator)
	if err != nil {
		die("could not read %s: %v", src, err)
	}
	if werr := os.write_entire_file(dst, data); werr != nil {
		die("could not write %s: %v", dst, werr)
	}
}

/*
lint checks the prose in this tree against ASD-STE100.

The rules, the two modes and the project dictionary are in `docs/STYLE.md`. The
checker itself is Python rather than Odin. The job is regular expressions over
text, and it has to run over the `.md` files as well as the source.

A finding exits non-zero, so this works as a gate. The tree is at zero.
*/
lint :: proc(opts: Options) {
	step("checking prose against ASD-STE100")
	args := [dynamic]string{"python3", "tools/ste-lint.py"}
	defer delete(args)
	append(&args, ..opts.passthrough)
	run(args[:])
}

step :: proc(format: string, args: ..any) {
	fmt.printf("==> ")
	fmt.printfln(format, ..args)
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("!!! ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
