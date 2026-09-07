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
    fleet    esp for two architectures, then boot two machines on one link
    clean    Remove build/
    lint     Check the prose against ASD-STE100

Options:
    --arch=amd64|arm64|riscv64   Target architecture (default: amd64)
    --arch2=amd64|arm64|riscv64  The fleet's second machine (default: arm64)
    --release                    Optimise, otherwise a debug build
    --serial=stdio|file          Where QEMU's COM1 goes (default: stdio)
    --monitor=PATH               A QEMU monitor on a unix socket, for screendump
    --gfx                        Open a QEMU window, otherwise headless
    --smp=N                      Cores QEMU presents (default: 4)
    --pcap                       fleet: capture each machine's frames to build/net-{a,b}.pcap

An Odin program rather than a shell script, for one reason. The flag handling,
the arch table and the link line will all grow per-architecture.

This way they grow in the same language, and the same type system, as the thing
they build. `justfile` and `Makefile` are thin wrappers over this.
*/
#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

BUILD_DIR :: "build"
ESP_DIR :: "build/esp"
SCRATCH_IMG :: "build/disk.img"
KERNEL_ELF :: "build/vectra.elf"
KERNEL_VXD :: "build/vectra.vxd"
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
	dis:  bool, // Whether its debug file carries disassembly, `docs/DEVTOOLS.md` section 6
	noopt: bool, // Built at -o:none, so every variable has a place a debugger can read
}

user_programs := [?]User_Program {
	{name = "ramfs", path = "servers/ramfs"},
	{name = "consrv", path = "servers/consrv"},
	{name = "kbdfs", path = "servers/kbdfs"},
	{name = "netfs", path = "servers/netfs"},
	{name = "eiafs", path = "servers/eiafs"},
	{name = "intuition", path = "servers/intuition"},
	{name = "terminal", path = "apps/terminal"},
	{name = "abitest", path = "tests/abi"},
	{name = "threadtest", path = "tests/thread"},
	{name = "mui", path = "tests/mui"},
	{name = "nettest", path = "tests/net"},
	{name = "udptest", path = "tests/udp"},
	{name = "tcptest", path = "tests/tcp"},
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
	{name = "netecho", path = "cmd/netecho"},
	{name = "ping", path = "cmd/ping"},
	{name = "ipconfig", path = "cmd/ipconfig"},
	{name = "dns", path = "servers/dns"},
	{name = "cs", path = "servers/cs"},
	{name = "dnstest", path = "tests/dns"},
	{name = "exportfs", path = "cmd/exportfs"},
	{name = "listen", path = "cmd/listen"},
	{name = "srv", path = "cmd/srv"},
	{name = "import", path = "cmd/import"},
	{name = "cryptotest", path = "tests/crypto"},
	{name = "factotum", path = "servers/factotum"},
	{name = "authtest", path = "tests/auth"},
	{name = "chmod", path = "cmd/chmod"},
	{name = "auth", path = "cmd/auth"},
	{name = "fonttest", path = "tests/font"},
	{name = "muidemo", path = "apps/muidemo"},
	{name = "debugtest", path = "tests/debug", dis = true},
	{name = "dbgfs", path = "servers/dbgfs"},
	{name = "db", path = "cmd/db"},
	{name = "debuggee", path = "tests/debuggee", dis = true, noopt = true},
	{name = "debugger", path = "apps/debugger"},
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

// parse_arch reads an `--arch=NAME` or `--arch2=NAME` option.
parse_arch :: proc(arg: string) -> Arch {
	name := arg[strings.index_byte(arg, '=') + 1:]
	switch name {
	case "amd64", "x86_64": return .amd64
	case "arm64", "aarch64": return .arm64
	case "riscv64", "rv64": return .riscv64
	}
	die("unknown %s (want amd64, arm64, riscv64)", arg)
}

Options :: struct {
	target:  string,
	arch:    Arch,
	arch2:   Arch, // The fleet's second machine, `arch` being its first
	release: bool,
	serial:  string,
	monitor: string,
	gfx:     bool,
	smp:     int,
	pcap:    bool, // The fleet's frames, captured at QEMU's netdev
	hostname: string, // Whose host key the staged /adm carries;  when unset

	// Everything after the target, handed to the target untouched. Only
	// `lint` reads it, so that `build lint --show docs` reaches the checker.
	passthrough: []string,
}

main :: proc() {
	opts := Options {
		target = "kernel",
		arch   = .amd64,
		arch2  = .arm64,
		serial = "stdio",
		smp    = 4,
	}

	positional_seen := false
	rest: [dynamic]string
	defer delete(rest)
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--arch="):
			opts.arch = parse_arch(arg)
		case strings.has_prefix(arg, "--arch2="):
			opts.arch2 = parse_arch(arg)
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
		case arg == "--pcap":
			opts.pcap = true
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
	case "fleet":  run_fleet(opts)
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
	// The kernel's own debug file, which Limine loads as a module beside
	// it and the panic screen resolves names through. No disassembly: a
	// table of the whole kernel's instructions is a large module for a
	// line the panic screen does not print.
	elf_to_debug(KERNEL_ELF, KERNEL_VXD, opts.arch, false)
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

		// A program the debugger's self-test steps is built at none, so
		// every variable has a place to be read from.
		objs := compile_ring3(cfg, prog.path, obj, prog.noopt ? {"-o:none"} : {})
		link_ring3(cfg, objs, elf, "sys/libuser/link_user.ld", {thread_obj})
		elf_to_image(elf, img)
		elf_to_debug(elf, fmt.tprintf("%s/%s.vxd", USER_DIR, prog.name), opts.arch, prog.dis)
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
	// DWARF beside the code, for `elf_to_debug`. The image does not grow:
	// the converter consumes the sections and `elf_to_image` drops them.
	"-debug",
}

/*
compile_ring3 compiles one ring 3 package, with `extra` for the flags one
caller adds, and returns the objects to link.

Usually that is the one object named. At `-o:none` and `-o:minimal` this
compiler writes one object per package instead -- `name-debuggee.o`,
`name-runtime-core.o` and so on beside the name asked for, and nothing at
the name itself -- and exits 0 either way. A stale single object would
link without a word. So both shapes are removed before the compile, and
what the compile left is what is linked.
*/
compile_ring3 :: proc(cfg: Arch_Config, pkg: string, obj: string, extra: []string) -> []string {
	dir, stem := split_object_name(obj)
	_ = os.remove(obj)
	for old in sibling_objects(dir, stem) {
		_ = os.remove(old)
	}
	args := [dynamic]string{"odin", "build", pkg, fmt.tprintf("-out:%s", obj), "-build-mode:obj", fmt.tprintf("-target:%s", cfg.odin_target)}
	append(&args, ..ring3_check_flags[:])
	// The compiler refuses an optimisation flag given twice, so a caller's
	// `-o:` replaces the table's rather than follows it.
	own_opt := false
	for e in extra {
		if strings.has_prefix(e, "-o:") {
			own_opt = true
		}
	}
	for f in ring3_build_flags {
		if own_opt && strings.has_prefix(f, "-o:") {
			continue
		}
		append(&args, f)
	}
	append(&args, ..extra)
	run(args[:])
	if os.exists(obj) {
		one := make([]string, 1)
		one[0] = obj
		return one
	}
	objs := sibling_objects(dir, stem)
	if len(objs) == 0 {
		die("%s left no object at %s and none beside it", pkg, obj)
	}
	step("%s compiled to %d objects", pkg, len(objs))
	return objs
}

// split_object_name splits `build/user/name.o` into its directory and `name`.
split_object_name :: proc(obj: string) -> (dir: string, stem: string) {
	slash := strings.last_index_byte(obj, '/')
	dir = slash < 0 ? "." : obj[:slash]
	stem = strings.trim_suffix(obj[slash + 1:], ".o")
	return
}

// sibling_objects lists `dir/stem-*.o`, sorted, so a link is the same
// order every build.
sibling_objects :: proc(dir: string, stem: string) -> []string {
	found := make([dynamic]string)
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return found[:]
	}
	prefix := fmt.tprintf("%s-", stem)
	for fi in infos {
		if strings.has_prefix(fi.name, prefix) && strings.has_suffix(fi.name, ".o") {
			append(&found, fmt.tprintf("%s/%s", dir, fi.name))
		}
	}
	slice.sort(found[:])
	return found[:]
}

/*
link_ring3 links ring 3 objects by the script a caller names.

`-z norelro`, because the linker otherwise carves a read-only segment for
the GOT out of `.data` and starts `.bss` where that ends, mid-page. The
loader maps whole pages, and each link script exists so every segment
starts on one.
*/
link_ring3 :: proc(cfg: Arch_Config, objs: []string, elf: string, script: string, extra: []string = nil) {
	args := [dynamic]string{"ld.lld"}
	append(&args, ..objs)
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

		objs := compile_ring3(cfg, "kernel/user/programs", obj, {fmt.tprintf("-define:PROGRAM=%s", name)})
		link_ring3(cfg, objs, elf, "kernel/user/programs/link_program.ld")
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
	// The kernel's debug table, named as a module in limine.conf.
	copy_file(KERNEL_VXD, fmt.tprintf("%s/vectra.vxd", ESP_DIR))
	stage_vectra(opts.hostname == "" ? "vectra" : opts.hostname)
}

/*
stage_vectra puts the programs and the library on the disk, under
`vectra/`, where `fatfs` serves them and the boot binds them over `/bin`
and `/lib`. Every program image under `bin/` by its `/bin` name, `rcmain`
and the test script under `lib/`, and an empty `tmp/` for what a running
machine writes back to the host.
*/
stage_vectra :: proc(host: string) {
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
	// Each program's debug file, where a debugger looks for it by the
	// program's name. `/bin` is served from the image and stays small.
	ensure_dir(fmt.tprintf("%s/lib/debug", root))
	for prog in user_programs {
		copy_file(fmt.tprintf("%s/%s.vxd", USER_DIR, prog.name), fmt.tprintf("%s/lib/debug/%s.vxd", root, prog.name))
	}
	copy_file("apps/rc/rcmain", fmt.tprintf("%s/lib/rcmain", root))
	copy_file("apps/rc/init", fmt.tprintf("%s/lib/init", root))
	// The font past ASCII: a `.font` index and the subfont files it names,
	// read at run time. ASCII stays baked in `sys/libfont`. Generated by
	// `tools/gensubfont.py` and checked in, so a build stages without a
	// rasterizer. See `docs/DRAW.md`.
	ensure_dir(fmt.tprintf("%s/lib/font", root))
	copy_file("lib/font/default.font", fmt.tprintf("%s/lib/font/default.font", root))
	for sf in ([]string{"latin1.subf", "punct.subf", "arrows.subf"}) {
		copy_file(fmt.tprintf("lib/font/%s", sf), fmt.tprintf("%s/lib/font/%s", root, sf))
	}
	// The draw server's two files: the chords, and where a window opens.
	copy_file("servers/intuition/keys", fmt.tprintf("%s/lib/keys", root))
	copy_file("servers/intuition/workspaces", fmt.tprintf("%s/lib/workspaces", root))
	copy_file("tests/tools.rc", fmt.tprintf("%s/lib/tests/tools.rc", root))
	copy_file("tests/dbg.rc", fmt.tprintf("%s/lib/tests/dbg.rc", root))
	// The source the debugger's window shows, under the path the debug file
	// names. The one program a debugger is expected on today.
	ensure_dir(fmt.tprintf("%s/lib/src", root))
	ensure_dir(fmt.tprintf("%s/lib/src/tests", root))
	ensure_dir(fmt.tprintf("%s/lib/src/tests/debuggee", root))
	copy_file("tests/debuggee/main.odin", fmt.tprintf("%s/lib/src/tests/debuggee/main.odin", root))
	ensure_dir(fmt.tprintf("%s/lib/ndb", root))
	copy_file("lib/ndb/local", fmt.tprintf("%s/lib/ndb/local", root))
	// The services `listen` announces: one script per port.
	ensure_dir(fmt.tprintf("%s/lib/service", root))
	copy_file("lib/service/tcp564", fmt.tprintf("%s/lib/service/tcp564", root))
	copy_file("lib/service/tcp565", fmt.tprintf("%s/lib/service/tcp565", root))
	// /adm: the users and their public keys, one file for the fleet, and
	// this machine's own host key, the private half only it carries.
	ensure_dir(fmt.tprintf("%s/adm", root))
	copy_file("lib/adm/keys", fmt.tprintf("%s/adm/keys", root))
	copy_file(fmt.tprintf("lib/adm/hostkey.%s", host), fmt.tprintf("%s/adm/hostkey", root))
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
	// A virtio entropy source, the machine's randomness. `/dev/random` reads
	// it, and `docs/FLEET.md` step 2's handshake needs it for a fresh key.
	append(&args, "-object", "rng-builtin,id=rng0")
	append(&args, "-device", "virtio-rng-pci,rng=rng0,disable-legacy=on")
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

/*
run_fleet boots two machines on one socket network, which is `docs/FLEET.md`
step 0's bench. One machine listens for the link and the other dials it, so the
two are wired as if by a crossing cable. They are of two architectures, `--arch`
and `--arch2`, because the plan's boot line wants the one tree proven across
them, not one kernel twice. The tree is staged once per architecture, and each
staging is copied aside before the next overwrites `build/`. Each machine gets
its own copy of the ESP and its own scratch disk. Two QEMUs cannot share one
`fat:rw` overlay, nor one raw image's write lock. Each gets a distinct card
address, so `/lib/ndb/local` gives each a distinct name and IP -- the whole
point of a fleet reading one database.

The consoles go to unix sockets a host script drives, and the serial log of
each also to a file. This launches both and waits. A driver connects to the
sockets, runs `netecho` on each, and watches a line cross.
*/
run_fleet :: proc(opts: Options) {

	// Each machine's own ESP, staged for its own architecture, and its own
	// scratch disk. Machine one is `--arch`, machine two `--arch2`.
	opts_a := opts
	opts_b := opts
	opts_b.arch = opts.arch2
	opts_a.hostname = "one"
	opts_b.hostname = "two"
	esp_a := fmt.tprintf("%s/esp-a", BUILD_DIR)
	esp_b := fmt.tprintf("%s/esp-b", BUILD_DIR)
	stage_esp(opts_a)
	copy_tree(ESP_DIR, esp_a)
	stage_esp(opts_b)
	copy_tree(ESP_DIR, esp_b)
	ensure_scratch_disk()
	scratch_a := fmt.tprintf("%s/disk-a.img", BUILD_DIR)
	scratch_b := fmt.tprintf("%s/disk-b.img", BUILD_DIR)
	copy_file(SCRATCH_IMG, scratch_a)
	copy_file(SCRATCH_IMG, scratch_b)

	PORT :: "17999"
	// Two cards each: the socket link between the machines is `ether0`, the
	// first on the bus, and a user-mode network to the host is `ether1`,
	// where QEMU's router hands out an address and `ipconfig` asks for it.
	a := machine_args(
		opts_a, esp_a, scratch_a,
		{"-netdev", fmt.tprintf("socket,id=n0,listen=127.0.0.1:%s", PORT),
		 "-device", "virtio-net-pci,netdev=n0,mac=52:54:00:00:00:0a,disable-legacy=on",
		 "-netdev", "user,id=n1",
		 "-device", "virtio-net-pci,netdev=n1,mac=52:54:00:00:01:0a,disable-legacy=on"},
		fmt.tprintf("%s/console-a.sock", BUILD_DIR),
		fmt.tprintf("%s/serial-a.log", BUILD_DIR),
	)
	b := machine_args(
		opts_b, esp_b, scratch_b,
		{"-netdev", fmt.tprintf("socket,id=n0,connect=127.0.0.1:%s", PORT),
		 "-device", "virtio-net-pci,netdev=n0,mac=52:54:00:00:00:0b,disable-legacy=on",
		 "-netdev", "user,id=n1",
		 "-device", "virtio-net-pci,netdev=n1,mac=52:54:00:00:01:0b,disable-legacy=on"},
		fmt.tprintf("%s/console-b.sock", BUILD_DIR),
		fmt.tprintf("%s/serial-b.log", BUILD_DIR),
	)

	step("booting machine one (%v), listening for the link on port %s", opts_a.arch, PORT)
	pa := spawn_bg(a[:])
	// Let machine one open its listening socket before machine two dials it.
	// A socket netdev does not retry, so a dial that races the listen leaves
	// the two on a dead link with no way back.
	run({"sleep", "3"})
	step("booting machine two (%v), dialling the link", opts_b.arch)
	pb := spawn_bg(b[:])

	step("fleet up: consoles at %s/console-a.sock and console-b.sock", BUILD_DIR)
	step("drive it with scripts/fleet.py, or connect a socket to a console")

	// Wait for both to exit. A driver kills them when its checks are done.
	_, _ = os.process_wait(pa)
	_, _ = os.process_wait(pb)
}

/*
machine_args builds one QEMU command with a given ESP, scratch disk, network,
console and serial log. It is `run_qemu`'s body with the parts that differ
between fleet machines lifted out.
*/
machine_args :: proc(opts: Options, esp_dir, scratch: string, net: []string, console, serial_log: string) -> [dynamic]string {
	cfg := arch_config(opts.arch)
	args := [dynamic]string{cfg.qemu}
	append(&args, ..cfg.qemu_machine)

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
		// Each machine needs its own writable copy of the firmware variables.
		tag := serial_log
		vars := fmt.tprintf("%s/%s%s.vars", BUILD_DIR, cfg.fw_vars, path_tag(tag))
		copy_file(fmt.tprintf("%s/%s", share, cfg.fw_vars), vars)
		append(&args, "-drive", fmt.tprintf("if=pflash,unit=0,format=raw,readonly=on,file=%s/%s", share, cfg.fw_code))
		append(&args, "-drive", fmt.tprintf("if=pflash,unit=1,format=raw,file=%s", vars))
	}

	append(&args, "-drive", fmt.tprintf("if=none,id=esp,format=raw,file=fat:rw:%s", esp_dir))
	append(&args, "-device", "virtio-blk-pci,drive=esp,bootindex=0,disable-legacy=on")
	append(&args, "-drive", fmt.tprintf("if=none,id=scratch,format=raw,file=%s", scratch))
	append(&args, "-device", "virtio-blk-pci,drive=scratch,disable-legacy=on")
	append(&args, ..net)
	// The entropy source, on every fleet machine, for the handshake.
	append(&args, "-object", fmt.tprintf("rng-builtin,id=rng%s", path_tag(serial_log)))
	append(&args, "-device", fmt.tprintf("virtio-rng-pci,rng=rng%s,disable-legacy=on", path_tag(serial_log)))
	if opts.pcap {
		// Every frame the netdev carries, both ways, as a pcap a host reads
		// with tcpdump. What one machine sent and the other received is
		// then a question with an answer.
		append(&args, "-object", fmt.tprintf("filter-dump,id=dump,netdev=n0,file=%s/net-%s.pcap", BUILD_DIR, path_tag(serial_log)))
	}
	append(&args, "-smp", fmt.tprintf("%d", opts.smp))
	// The guest console is the serial line, on a unix socket a host drives, and
	// a copy also to a log file. The monitor is not needed here.
	append(&args, "-chardev", fmt.tprintf("socket,id=con,path=%s,server=on,wait=off,logfile=%s", console, serial_log))
	append(&args, "-serial", "chardev:con")
	append(&args, "-display", "none")
	return args
}

// path_tag turns a file path into a short suffix, so two machines name their
// firmware-variable copies apart.
path_tag :: proc(s: string) -> string {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '-' {
			return s[i + 1:i + 2]
		}
	}
	return "x"
}

// spawn_bg starts a process without waiting for it, for the fleet's two
// machines that must run at once.
spawn_bg :: proc(command: []string) -> os.Process {
	desc := os.Process_Desc{command = command, stdout = os.stdout, stderr = os.stderr}
	process, err := os.process_start(desc)
	if err != nil {
		die("could not start %s: %v", command[0], err)
	}
	return process
}

// copy_tree copies a directory recursively, for a per-machine ESP.
copy_tree :: proc(src, dst: string) {
	run({"rm", "-rf", dst})
	run({"cp", "-R", src, dst})
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

/*
-- Debug information ----------------------------------------------------------

elf_to_debug writes the flat debug file `docs/DEVTOOLS.md` section 6
describes, beside a program's image: `build/user/<name>.vxd`, and
`build/vectra.vxd` for the kernel. `sys/libdebug` reads it, on the machine.

The sources are the linked ELF's `.symtab` for the procedures, its DWARF 4
`.debug_info` for the compilation units and `.debug_line` for the files and
the line rows, and `llvm-objdump` for the disassembly where a program asks
for it. This Odin emits DWARF 4, and the reader below refuses a version or
a form it does not know by name. A compiler that moves is then a build
failure and not a wrong answer. Nothing here reads `.debug_frame`, because
nothing emits one. The frame chain is the fallback the plan named.

The tables and their layout are the reader's file comment, and the two
must agree by hand: this file builds the file and that one reads it, and
neither can import the other.
*/

VXD_MAGIC :: u32(0x3144_5856) // "VXD1"
VXD_VERSION :: u32(1)

Vxd_Table :: enum u32 {
	Units   = 1,
	Files   = 2,
	Procs   = 3,
	Lines   = 4,
	Names   = 5,
	Dis     = 6,
	Strings = 7,
	Types   = 8,
	Members = 9,
	Scopes  = 10,
	Vars    = 11,
}

Vxd_Unit :: struct {
	name, dir, lang, stmt: u32,
}
Vxd_File :: struct {
	unit, path: u32,
}
Vxd_Proc :: struct {
	low, high: u64,
	name, unit: u32,
}
Vxd_Line :: struct {
	addr:       u64,
	file, line: u32,
}
Vxd_Name :: struct {
	name, index: u32,
}
Vxd_Dis :: struct {
	addr:      u64,
	text, pad: u32,
}

Vxd_Builder :: struct {
	pool:     [dynamic]u8,
	interned: map[string]u32,
	units:    [dynamic]Vxd_Unit,
	files:    [dynamic]Vxd_File,
	procs:    [dynamic]Vxd_Proc,
	lines:    [dynamic]Vxd_Line,
	names:    [dynamic]Vxd_Name,
	dis:      [dynamic]Vxd_Dis,
	types:    [dynamic]Vxd_Type,
	members:  [dynamic]Vxd_Member,
	scopes:   [dynamic]Vxd_Scope,
	vars:     [dynamic]Vxd_Var,
}

vxd_intern :: proc(b: ^Vxd_Builder, s: string) -> u32 {
	if len(b.pool) == 0 {
		append(&b.pool, 0) // Offset zero is the empty string.
	}
	if off, found := b.interned[s]; found {
		return off
	}
	off := u32(len(b.pool))
	append(&b.pool, ..transmute([]u8)s)
	append(&b.pool, 0)
	b.interned[strings.clone(s)] = off
	return off
}

// One ELF section, as the converter reads it.
Elf_Section :: struct {
	name:   string,
	kind:   u32,
	addr:   u64,
	offset: int,
	size:   int,
	link:   u32,
}

elf_sections :: proc(data: []u8) -> []Elf_Section {
	shoff := int(u64le(data, 0x28))
	shentsize := int(u16le(data, 0x3a))
	shnum := int(u16le(data, 0x3c))
	shstrndx := int(u16le(data, 0x3e))
	out := make([]Elf_Section, shnum)
	for i in 0 ..< shnum {
		at := shoff + i * shentsize
		out[i] = Elf_Section {
			kind   = u32(u32le(data, at + 4)),
			addr   = u64le(data, at + 16),
			offset = int(u64le(data, at + 24)),
			size   = int(u64le(data, at + 32)),
			link   = u32(u32le(data, at + 40)),
		}
	}
	names := out[shstrndx]
	for i in 0 ..< shnum {
		n := int(u32le(data, shoff + i * shentsize))
		out[i].name = cstr_at(data, names.offset + n)
	}
	return out
}

elf_section :: proc(secs: []Elf_Section, name: string) -> (Elf_Section, bool) {
	for s in secs {
		if s.name == name {
			return s, true
		}
	}
	return {}, false
}

cstr_at :: proc(data: []u8, at: int) -> string {
	n := at
	for n < len(data) && data[n] != 0 {
		n += 1
	}
	return string(data[at:n])
}

// A cursor over a DWARF section, with the LEB128 readers the format is
// built on.
Dwarf_Cursor :: struct {
	data: []u8,
	at:   int,
}

dw_u8 :: proc(c: ^Dwarf_Cursor) -> u64 {
	v := u64(c.data[c.at])
	c.at += 1
	return v
}
dw_u16 :: proc(c: ^Dwarf_Cursor) -> u64 {
	v := u16le(c.data, c.at)
	c.at += 2
	return v
}
dw_u32 :: proc(c: ^Dwarf_Cursor) -> u64 {
	v := u32le(c.data, c.at)
	c.at += 4
	return v
}
dw_u64 :: proc(c: ^Dwarf_Cursor) -> u64 {
	v := u64le(c.data, c.at)
	c.at += 8
	return v
}
dw_uleb :: proc(c: ^Dwarf_Cursor) -> u64 {
	v := u64(0)
	shift := u64(0)
	for {
		b := c.data[c.at]
		c.at += 1
		v |= u64(b & 0x7f) << shift
		shift += 7
		if b & 0x80 == 0 {
			break
		}
	}
	return v
}
dw_sleb :: proc(c: ^Dwarf_Cursor) -> i64 {
	v := i64(0)
	shift := u64(0)
	b: u8
	for {
		b = c.data[c.at]
		c.at += 1
		v |= i64(b & 0x7f) << shift
		shift += 7
		if b & 0x80 == 0 {
			break
		}
	}
	if shift < 64 && b & 0x40 != 0 {
		v |= -(i64(1) << shift)
	}
	return v
}
dw_cstr :: proc(c: ^Dwarf_Cursor) -> string {
	s := cstr_at(c.data, c.at)
	c.at += len(s) + 1
	return s
}

// The DWARF 4 attributes and forms the converter names. Anything else on a
// compile unit's DIE is skipped by its form's size. A form this table does
// not size is a refusal.
DW_TAG_compile_unit :: 0x11
DW_AT_name :: 0x03
DW_AT_stmt_list :: 0x10
DW_AT_language :: 0x13
DW_AT_comp_dir :: 0x1b

Dwarf_Attr :: struct {
	at, form: u64,
}

Dwarf_Abbrev :: struct {
	tag:      u64,
	children: bool,
	attrs:    [dynamic]Dwarf_Attr,
}

// dw_form_value reads one attribute value of `form` and answers it as a
// number and, for the string forms, as text. Block and expression forms
// are skipped and answer nothing.
dw_form_value :: proc(c: ^Dwarf_Cursor, form: u64, str_section: []u8, elf_path: string) -> (num: u64, text: string) {
	switch form {
	case 0x01: return dw_u64(c), "" // addr
	case 0x03: n := dw_u16(c); c.at += int(n); return 0, "" // block2
	case 0x04: n := dw_u32(c); c.at += int(n); return 0, "" // block4
	case 0x05: return dw_u16(c), "" // data2
	case 0x06: return dw_u32(c), "" // data4
	case 0x07: return dw_u64(c), "" // data8
	case 0x08: s := dw_cstr(c); return 0, s // string
	case 0x09: n := dw_uleb(c); c.at += int(n); return 0, "" // block
	case 0x0a: n := dw_u8(c); c.at += int(n); return 0, "" // block1
	case 0x0b: return dw_u8(c), "" // data1
	case 0x0c: return dw_u8(c), "" // flag
	case 0x0d: return u64(dw_sleb(c)), "" // sdata
	case 0x0e: off := dw_u32(c); return off, cstr_at(str_section, int(off)) // strp
	case 0x0f: return dw_uleb(c), "" // udata
	case 0x10: return dw_u32(c), "" // ref_addr
	case 0x11: return dw_u8(c), "" // ref1
	case 0x12: return dw_u16(c), "" // ref2
	case 0x13: return dw_u32(c), "" // ref4
	case 0x14: return dw_u64(c), "" // ref8
	case 0x15: return dw_uleb(c), "" // ref_udata
	case 0x16: inner := dw_uleb(c); return dw_form_value(c, inner, str_section, elf_path) // indirect
	case 0x17: return dw_u32(c), "" // sec_offset
	case 0x18: n := dw_uleb(c); c.at += int(n); return 0, "" // exprloc
	case 0x19: return 1, "" // flag_present
	case 0x20: return dw_u64(c), "" // ref_sig8
	}
	die("%s: DWARF form 0x%x is not one this converter knows", elf_path, form)
}

// dw_abbrevs reads one abbreviation table, from `offset` to its terminator.
dw_abbrevs :: proc(section: []u8, offset: int) -> map[u64]Dwarf_Abbrev {
	out := make(map[u64]Dwarf_Abbrev)
	c := Dwarf_Cursor{data = section, at = offset}
	for {
		code := dw_uleb(&c)
		if code == 0 {
			break
		}
		ab := Dwarf_Abbrev {
			tag      = dw_uleb(&c),
			children = dw_u8(&c) != 0,
		}
		for {
			at := dw_uleb(&c)
			form := dw_uleb(&c)
			if at == 0 && form == 0 {
				break
			}
			append(&ab.attrs, Dwarf_Attr{at, form})
		}
		out[code] = ab
	}
	return out
}

/*
The DIE tree of one compilation unit, read whole.

`vxd_units` used to read the top DIE alone. The scopes, variables and types
the plan lists live under it, and they refer to each other by offset, a
variable's type or an inlined block's origin. So the tree is read into a
flat list first, offsets to indices, and the tables are built from the
list. A unit of the kernel is some fifty thousand DIEs, which is nothing.
*/
Dwarf_Value :: struct {
	form:  u64,
	num:   u64,
	text:  string,
	block: []u8,
}

Dwarf_Die :: struct {
	offset:   int, // From the section start: what a `ref_addr` names
	tag:      u64,
	parent:   int,
	children: [dynamic]int,
	attrs:    map[u64]Dwarf_Value,
}

DW_TAG_array_type :: 0x01
DW_TAG_enumeration_type :: 0x04
DW_TAG_formal_parameter :: 0x05
DW_TAG_lexical_block :: 0x0b
DW_TAG_member :: 0x0d
DW_TAG_pointer_type :: 0x0f
DW_TAG_structure_type :: 0x13
DW_TAG_subroutine_type :: 0x15
DW_TAG_typedef :: 0x16
DW_TAG_union_type :: 0x17
DW_TAG_inlined_subroutine :: 0x1d
DW_TAG_subrange_type :: 0x21
DW_TAG_base_type :: 0x24
DW_TAG_enumerator :: 0x28
DW_TAG_subprogram :: 0x2e
DW_TAG_variable :: 0x34

DW_AT_location :: 0x02
DW_AT_byte_size :: 0x0b
DW_AT_low_pc :: 0x11
DW_AT_high_pc :: 0x12
DW_AT_const_value :: 0x1c
DW_AT_abstract_origin :: 0x31
DW_AT_count :: 0x37
DW_AT_data_member_location :: 0x38
DW_AT_encoding :: 0x3e
DW_AT_frame_base :: 0x40
DW_AT_type :: 0x49
DW_AT_ranges :: 0x55
DW_AT_linkage_name :: 0x6e

// The forms whose value is a reference to another DIE of the same unit.
dw_form_is_ref :: proc(form: u64) -> bool {
	return form == 0x11 || form == 0x12 || form == 0x13 || form == 0x14 || form == 0x15
}

// dw_form_read reads one attribute of `form`, keeping what the tables need:
// a number, the text of a string form, or the bytes of a block form.
dw_form_read :: proc(c: ^Dwarf_Cursor, form: u64, str_section: []u8, elf_path: string) -> Dwarf_Value {
	v := Dwarf_Value{form = form}
	switch form {
	case 0x01: v.num = dw_u64(c)
	case 0x03: n := int(dw_u16(c)); v.block = c.data[c.at:][:n]; c.at += n
	case 0x04: n := int(dw_u32(c)); v.block = c.data[c.at:][:n]; c.at += n
	case 0x05: v.num = dw_u16(c)
	case 0x06: v.num = dw_u32(c)
	case 0x07: v.num = dw_u64(c)
	case 0x08: v.text = dw_cstr(c)
	case 0x09: n := int(dw_uleb(c)); v.block = c.data[c.at:][:n]; c.at += n
	case 0x0a: n := int(dw_u8(c)); v.block = c.data[c.at:][:n]; c.at += n
	case 0x0b: v.num = dw_u8(c)
	case 0x0c: v.num = dw_u8(c)
	case 0x0d: v.num = u64(dw_sleb(c))
	case 0x0e: off := dw_u32(c); v.num = off; v.text = cstr_at(str_section, int(off))
	case 0x0f: v.num = dw_uleb(c)
	case 0x10: v.num = dw_u32(c)
	case 0x11: v.num = dw_u8(c)
	case 0x12: v.num = dw_u16(c)
	case 0x13: v.num = dw_u32(c)
	case 0x14: v.num = dw_u64(c)
	case 0x15: v.num = dw_uleb(c)
	case 0x16:
		inner := dw_uleb(c)
		v = dw_form_read(c, inner, str_section, elf_path)
	case 0x17: v.num = dw_u32(c)
	case 0x18: n := int(dw_uleb(c)); v.block = c.data[c.at:][:n]; c.at += n
	case 0x19: v.num = 1
	case 0x20: v.num = dw_u64(c)
	case:
		die("%s: DWARF form 0x%x is not one this converter knows", elf_path, form)
	}
	return v
}

// One unit's tree, and the section offsets the unit's references are
// relative to.
Dwarf_Unit :: struct {
	base:  int, // The unit header's offset in `.debug_info`
	dies:  [dynamic]Dwarf_Die,
	index: map[int]int, // DIE offset to its place in `dies`
}

dw_attr :: proc(d: ^Dwarf_Die, at: u64) -> (Dwarf_Value, bool) {
	v, ok := d.attrs[at]
	return v, ok
}

// dw_ref answers the DIE a reference attribute names, or -1.
dw_ref :: proc(u: ^Dwarf_Unit, d: ^Dwarf_Die, at: u64) -> int {
	v, ok := dw_attr(d, at)
	if !ok {
		return -1
	}
	target := int(v.num)
	if dw_form_is_ref(v.form) {
		target += u.base
	}
	if i, found := u.index[target]; found {
		return i
	}
	return -1
}

// dw_origin_attr answers an attribute of a DIE, or of the abstract origin
// it stands for, as far up as origins go. An inlined variable's name is on
// the original.
dw_origin_attr :: proc(u: ^Dwarf_Unit, i: int, at: u64) -> (Dwarf_Value, bool) {
	at_die := i
	for _ in 0 ..< 8 {
		if at_die < 0 {
			break
		}
		d := &u.dies[at_die]
		if v, ok := dw_attr(d, at); ok {
			return v, true
		}
		at_die = dw_ref(u, d, DW_AT_abstract_origin)
	}
	return {}, false
}

dw_origin_ref :: proc(u: ^Dwarf_Unit, i: int, at: u64) -> int {
	at_die := i
	for _ in 0 ..< 8 {
		if at_die < 0 {
			break
		}
		d := &u.dies[at_die]
		if r := dw_ref(u, d, at); r >= 0 {
			return r
		}
		at_die = dw_ref(u, d, DW_AT_abstract_origin)
	}
	return -1
}

// dw_read_unit reads one unit's DIEs into a tree and answers where the
// next unit starts.
dw_read_unit :: proc(info: []u8, abbrev_section: []u8, str_section: []u8, start: int, elf_path: string) -> (u: Dwarf_Unit, next: int) {
	c := Dwarf_Cursor{data = info, at = start}
	unit_length := dw_u32(&c)
	if unit_length == 0xffff_ffff {
		die("%s: a 64-bit DWARF unit, which this converter does not read", elf_path)
	}
	end := c.at + int(unit_length)
	version := dw_u16(&c)
	if version != 4 {
		die("%s: DWARF version %d, and this converter reads 4", elf_path, version)
	}
	abbrev_offset := dw_u32(&c)
	address_size := dw_u8(&c)
	if address_size != 8 {
		die("%s: DWARF address size %d", elf_path, address_size)
	}
	abbrevs := dw_abbrevs(abbrev_section, int(abbrev_offset))
	u.base = start
	u.index = make(map[int]int)
	stack: [dynamic]int
	for c.at < end {
		offset := c.at
		code := dw_uleb(&c)
		if code == 0 {
			if len(stack) > 0 {
				pop(&stack)
			}
			continue
		}
		ab, known := abbrevs[code]
		if !known {
			die("%s: abbreviation %d is not in the table", elf_path, code)
		}
		d := Dwarf_Die {
			offset = offset,
			tag    = ab.tag,
			parent = len(stack) > 0 ? stack[len(stack) - 1] : -1,
			attrs  = make(map[u64]Dwarf_Value),
		}
		for a in ab.attrs {
			d.attrs[a.at] = dw_form_read(&c, a.form, str_section, elf_path)
		}
		i := len(u.dies)
		append(&u.dies, d)
		u.index[offset] = i
		if d.parent >= 0 {
			append(&u.dies[d.parent].children, i)
		}
		if ab.children {
			append(&stack, i)
		}
	}
	return u, end
}

/*
vxd_units reads every compilation unit out of `.debug_info`: its name,
directory, language and the offset of its line program from the top DIE,
and the types, procedures, scopes and variables from the tree below it.
*/
vxd_units :: proc(b: ^Vxd_Builder, data: []u8, secs: []Elf_Section, elf_path: string) {
	info, has_info := elf_section(secs, ".debug_info")
	abbrev, has_abbrev := elf_section(secs, ".debug_abbrev")
	if !has_info || !has_abbrev {
		return
	}
	strs, _ := elf_section(secs, ".debug_str")
	str_section := data[strs.offset:][:strs.size]
	abbrev_section := data[abbrev.offset:][:abbrev.size]
	info_section := data[info.offset:][:info.size]
	loc, has_loc := elf_section(secs, ".debug_loc")
	loc_section := has_loc ? data[loc.offset:][:loc.size] : nil
	rng, has_rng := elf_section(secs, ".debug_ranges")
	rng_section := has_rng ? data[rng.offset:][:rng.size] : nil

	at := 0
	for at < len(info_section) {
		u, next := dw_read_unit(info_section, abbrev_section, str_section, at, elf_path)
		at = next
		if len(u.dies) == 0 || u.dies[0].tag != DW_TAG_compile_unit {
			die("%s: a unit at %d whose first DIE is not a compile unit", elf_path, u.base)
		}
		top := &u.dies[0]
		unit := Vxd_Unit{stmt = 0xffff_ffff}
		if v, ok := dw_attr(top, DW_AT_name); ok {
			unit.name = vxd_intern(b, v.text)
		}
		if v, ok := dw_attr(top, DW_AT_comp_dir); ok {
			unit.dir = vxd_intern(b, v.text)
		}
		if v, ok := dw_attr(top, DW_AT_language); ok {
			unit.lang = u32(v.num)
		}
		if v, ok := dw_attr(top, DW_AT_stmt_list); ok {
			unit.stmt = u32(v.num)
		}
		append(&b.units, unit)
		unit_index := u32(len(b.units) - 1)
		cu_low := u64(0)
		if v, ok := dw_attr(top, DW_AT_low_pc); ok {
			cu_low = v.num
		}
		ctx := Vxd_Unit_Ctx {
			b       = b,
			u       = &u,
			unit    = unit_index,
			cu_low  = cu_low,
			loc     = loc_section,
			ranges  = rng_section,
			types   = make(map[int]u32),
			elf     = elf_path,
		}
		vxd_types(&ctx)
		vxd_scopes(&ctx)
	}
}

// What one unit's tables are built with. The tree, the section slices its
// references reach into, and the map from a type DIE to its row.
Vxd_Unit_Ctx :: struct {
	b:      ^Vxd_Builder,
	u:      ^Dwarf_Unit,
	unit:   u32,
	cu_low: u64,
	loc:    []u8,
	ranges: []u8,
	types:  map[int]u32,
	elf:    string,
}

// The kinds of type the file names. `docs/DEVTOOLS.md` section 6's list,
// with Odin's slice, string and map told apart from a struct by the name
// the compiler gives them.
Vxd_Type_Kind :: enum u32 {
	Unknown = 0,
	Base    = 1,
	Pointer = 2,
	Array   = 3,
	Struct  = 4,
	Union   = 5,
	Enum    = 6,
	Proc    = 7,
	Typedef = 8,
	Slice   = 9,
	String  = 10,
	Map     = 11,
}

Vxd_Type :: struct {
	kind:   u32,
	name:   u32,
	size:   u32,
	target: u32, // The type this points at, holds, or names; `NO_TYPE` for none
	count:  u32, // Members, enumerators, or an array's length
	first:  u32, // First member or enumerator row
	enc:    u32, // A base type's DWARF encoding
	pad:    u32,
}

Vxd_Member :: struct {
	name, type: u32,
	offset:     u64, // A member's byte offset, or an enumerator's value
}

VXD_NO_TYPE :: u32(0xffff_ffff)

/*
vxd_types makes a row for every type DIE of the unit, in two passes. The
rows come first, so a reference to a type not seen yet has a row to name,
and the references after. Members and enumerators go in one table, a struct's
run of them named by `first` and `count`.
*/
vxd_types :: proc(ctx: ^Vxd_Unit_Ctx) {
	b := ctx.b
	u := ctx.u
	is_type :: proc(tag: u64) -> bool {
		switch tag {
		case DW_TAG_base_type, DW_TAG_pointer_type, DW_TAG_array_type, DW_TAG_structure_type,
		     DW_TAG_union_type, DW_TAG_enumeration_type, DW_TAG_subroutine_type, DW_TAG_typedef:
			return true
		}
		return false
	}
	for d, i in u.dies {
		if is_type(d.tag) {
			ctx.types[i] = u32(len(b.types))
			append(&b.types, Vxd_Type{target = VXD_NO_TYPE})
		}
	}
	for d, i in u.dies {
		row, is := ctx.types[i]
		if !is {
			continue
		}
		t := &b.types[row]
		if v, ok := dw_attr(&u.dies[i], DW_AT_name); ok {
			t.name = vxd_intern(b, v.text)
		}
		if v, ok := dw_attr(&u.dies[i], DW_AT_byte_size); ok {
			t.size = u32(v.num)
		}
		if r := dw_ref(u, &u.dies[i], DW_AT_type); r >= 0 {
			if tr, known := ctx.types[r]; known {
				t.target = tr
			}
		}
		switch d.tag {
		case DW_TAG_base_type:
			t.kind = u32(Vxd_Type_Kind.Base)
			if v, ok := dw_attr(&u.dies[i], DW_AT_encoding); ok {
				t.enc = u32(v.num)
			}
		case DW_TAG_pointer_type:
			t.kind = u32(Vxd_Type_Kind.Pointer)
			t.size = 8
		case DW_TAG_array_type:
			t.kind = u32(Vxd_Type_Kind.Array)
			for ci in u.dies[i].children {
				if u.dies[ci].tag == DW_TAG_subrange_type {
					if v, ok := dw_attr(&u.dies[ci], DW_AT_count); ok {
						t.count = u32(v.num)
					}
				}
			}
		case DW_TAG_structure_type, DW_TAG_union_type:
			name := cstr_at(b.pool[:], int(t.name))
			switch {
			case d.tag == DW_TAG_union_type:  t.kind = u32(Vxd_Type_Kind.Union)
			case name == "string":            t.kind = u32(Vxd_Type_Kind.String)
			case strings.has_prefix(name, "[]"): t.kind = u32(Vxd_Type_Kind.Slice)
			case strings.has_prefix(name, "map["): t.kind = u32(Vxd_Type_Kind.Map)
			case:                             t.kind = u32(Vxd_Type_Kind.Struct)
			}
			t.first = u32(len(b.members))
			for ci in u.dies[i].children {
				m := &u.dies[ci]
				if m.tag != DW_TAG_member {
					continue
				}
				row := Vxd_Member{type = VXD_NO_TYPE}
				if v, ok := dw_attr(m, DW_AT_name); ok {
					row.name = vxd_intern(b, v.text)
				}
				if v, ok := dw_attr(m, DW_AT_data_member_location); ok {
					row.offset = v.num
				}
				if r := dw_ref(u, m, DW_AT_type); r >= 0 {
					if tr, known := ctx.types[r]; known {
						row.type = tr
					}
				}
				append(&b.members, row)
				t.count += 1
			}
		case DW_TAG_enumeration_type:
			t.kind = u32(Vxd_Type_Kind.Enum)
			t.first = u32(len(b.members))
			for ci in u.dies[i].children {
				e := &u.dies[ci]
				if e.tag != DW_TAG_enumerator {
					continue
				}
				row := Vxd_Member{type = VXD_NO_TYPE}
				if v, ok := dw_attr(e, DW_AT_name); ok {
					row.name = vxd_intern(b, v.text)
				}
				if v, ok := dw_attr(e, DW_AT_const_value); ok {
					row.offset = v.num
				}
				append(&b.members, row)
				t.count += 1
			}
		case DW_TAG_subroutine_type:
			t.kind = u32(Vxd_Type_Kind.Proc)
			t.size = 8
		case DW_TAG_typedef:
			t.kind = u32(Vxd_Type_Kind.Typedef)
		}
	}
}

// Where a variable is, in the words the reader repeats. A location the
// converter cannot say in one of these is `Other`, which a debugger shows
// as optimised away.
Vxd_Loc_Kind :: enum u32 {
	Gone  = 0, // No location at all
	Fbreg = 1, // At the frame base plus `offset`
	Reg   = 2, // In register `reg`
	Breg  = 3, // At register `reg` plus `offset`
	Addr  = 4, // At the address `offset`
	Const = 5, // The value `offset` itself
	Other = 6, // An expression this file does not say
}

Vxd_Scope :: struct {
	low, high: u64,
	parent:    u32, // The enclosing scope's row, or `VXD_NO_SCOPE`
	name:      u32, // The procedure's, for a procedure or an inlined one; empty for a block
	first:     u32, // Its first variable row
	nvars:     u32,
}

Vxd_Var :: struct {
	name:      u32,
	type:      u32,
	kind:      u32,
	reg:       u32,
	offset:    i64,
	low, high: u64, // Where this row holds; zero and zero for everywhere
}

VXD_NO_SCOPE :: u32(0xffff_ffff)

// vxd_classify turns one DWARF expression into a kind, a register and an
// offset. One operation, or one with `stack_value` behind it, or an address
// form with `plus_uconst` behind it: what the compiler emits for a value it
// kept somewhere simple, and for a global it placed past another.
vxd_classify :: proc(expr: []u8) -> (kind: Vxd_Loc_Kind, reg: u32, offset: i64) {
	if len(expr) == 0 {
		return .Gone, 0, 0
	}
	c := Dwarf_Cursor{data = expr}
	op := dw_u8(&c)
	// The rest of an address form may be one `plus_uconst`, which is an
	// offset added; anything else makes the expression one this file does
	// not say.
	tail_offset :: proc(c: ^Dwarf_Cursor) -> (extra: i64, ok: bool) {
		if c.at == len(c.data) {
			return 0, true
		}
		if c.data[c.at] == 0x23 {
			c.at += 1
			v := dw_uleb(c)
			return i64(v), c.at == len(c.data)
		}
		return 0, false
	}
	switch {
	case op == 0x03: // addr
		if len(expr) >= 9 {
			a := i64(dw_u64(&c))
			if extra, ok := tail_offset(&c); ok {
				return .Addr, 0, a + extra
			}
		}
	case op == 0x91: // fbreg
		off := dw_sleb(&c)
		if extra, ok := tail_offset(&c); ok {
			return .Fbreg, 0, off + extra
		}
	case op >= 0x50 && op <= 0x6f: // reg0..reg31
		if len(expr) == 1 {
			return .Reg, u32(op - 0x50), 0
		}
	case op == 0x90: // regx
		r := dw_uleb(&c)
		if c.at == len(expr) {
			return .Reg, u32(r), 0
		}
	case op >= 0x70 && op <= 0x8f: // breg0..breg31
		off := dw_sleb(&c)
		if extra, ok := tail_offset(&c); ok {
			return .Breg, u32(op - 0x70), off + extra
		}
	case op >= 0x30 && op <= 0x4f: // lit0..lit31, with stack_value
		if len(expr) == 2 && expr[1] == 0x9f {
			return .Const, 0, i64(op - 0x30)
		}
	case op == 0x10: // constu, with stack_value
		v := dw_uleb(&c)
		if c.at + 1 == len(expr) && expr[c.at] == 0x9f {
			return .Const, 0, i64(v)
		}
	case op == 0x11: // consts, with stack_value
		v := dw_sleb(&c)
		if c.at + 1 == len(expr) && expr[c.at] == 0x9f {
			return .Const, 0, v
		}
	}
	return .Other, 0, 0
}

// vxd_var_rows appends the rows for one variable. One for an expression,
// one per entry for a location list, and one `Gone` row for a variable
// with no location, so a debugger can still name and type it.
vxd_var_rows :: proc(ctx: ^Vxd_Unit_Ctx, i: int) {
	b := ctx.b
	u := ctx.u
	name := u32(0)
	if v, ok := dw_origin_attr(u, i, DW_AT_name); ok {
		name = vxd_intern(b, v.text)
	}
	type_row := VXD_NO_TYPE
	if r := dw_origin_ref(u, i, DW_AT_type); r >= 0 {
		if tr, known := ctx.types[r]; known {
			type_row = tr
		}
	}
	d := &u.dies[i]
	if v, ok := dw_attr(d, DW_AT_const_value); ok {
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(Vxd_Loc_Kind.Const), offset = i64(v.num)})
		return
	}
	v, has_loc := dw_attr(d, DW_AT_location)
	if !has_loc {
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(Vxd_Loc_Kind.Gone)})
		return
	}
	if v.form == 0x18 || len(v.block) > 0 {
		kind, reg, off := vxd_classify(v.block)
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(kind), reg = reg, offset = off})
		return
	}
	// A location list: entries relative to a base the list may reset.
	if ctx.loc == nil {
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(Vxd_Loc_Kind.Other)})
		return
	}
	c := Dwarf_Cursor{data = ctx.loc, at = int(v.num)}
	base := ctx.cu_low
	rows := 0
	for c.at + 16 <= len(c.data) {
		lo := dw_u64(&c)
		hi := dw_u64(&c)
		if lo == 0 && hi == 0 {
			break
		}
		if lo == 0xffff_ffff_ffff_ffff {
			base = hi
			continue
		}
		n := int(dw_u16(&c))
		expr := c.data[c.at:][:n]
		c.at += n
		kind, reg, off := vxd_classify(expr)
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(kind), reg = reg, offset = off, low = base + lo, high = base + hi})
		rows += 1
	}
	if rows == 0 {
		append(&b.vars, Vxd_Var{name = name, type = type_row, kind = u32(Vxd_Loc_Kind.Gone)})
	}
}

// vxd_die_ranges answers the address ranges a DIE covers: its low and
// high, or every pair of its range list.
vxd_die_ranges :: proc(ctx: ^Vxd_Unit_Ctx, i: int) -> [dynamic][2]u64 {
	out: [dynamic][2]u64
	d := &ctx.u.dies[i]
	if lo, ok := dw_attr(d, DW_AT_low_pc); ok {
		if hi, hok := dw_attr(d, DW_AT_high_pc); hok {
			high := hi.form == 0x01 ? hi.num : lo.num + hi.num
			append(&out, [2]u64{lo.num, high})
		}
		return out
	}
	if r, ok := dw_attr(d, DW_AT_ranges); ok && ctx.ranges != nil {
		c := Dwarf_Cursor{data = ctx.ranges, at = int(r.num)}
		base := ctx.cu_low
		for c.at + 16 <= len(c.data) {
			lo := dw_u64(&c)
			hi := dw_u64(&c)
			if lo == 0 && hi == 0 {
				break
			}
			if lo == 0xffff_ffff_ffff_ffff {
				base = hi
				continue
			}
			append(&out, [2]u64{base + lo, base + hi})
		}
	}
	return out
}

/*
vxd_scope adds the rows for one scope-making DIE, a procedure with code,
a block or an inlined call. Below it come its variables and the scopes
nested in it. A scope with several ranges is several rows sharing one run
of variables. A lookup by address then finds the right one whichever
range the address is in.
*/
vxd_scope :: proc(ctx: ^Vxd_Unit_Ctx, i: int, parent: u32) {
	b := ctx.b
	u := ctx.u
	ranges := vxd_die_ranges(ctx, i)
	defer delete(ranges)
	if len(ranges) == 0 {
		return
	}
	name := u32(0)
	if u.dies[i].tag != DW_TAG_lexical_block {
		if v, ok := dw_origin_attr(u, i, DW_AT_linkage_name); ok {
			name = vxd_intern(b, v.text)
		} else if v, ok := dw_origin_attr(u, i, DW_AT_name); ok {
			name = vxd_intern(b, v.text)
		}
	}
	first := u32(len(b.vars))
	for ci in u.dies[i].children {
		tag := u.dies[ci].tag
		if tag == DW_TAG_variable || tag == DW_TAG_formal_parameter {
			vxd_var_rows(ctx, ci)
		}
	}
	nvars := u32(len(b.vars)) - first
	// The first row is the one children hang off; the others are the
	// same scope again at its other ranges.
	row := u32(len(b.scopes))
	for r in ranges {
		append(&b.scopes, Vxd_Scope{low = r[0], high = r[1], parent = parent, name = name, first = first, nvars = nvars})
	}
	for ci in u.dies[i].children {
		tag := u.dies[ci].tag
		if tag == DW_TAG_lexical_block || tag == DW_TAG_inlined_subroutine || tag == DW_TAG_subprogram {
			vxd_scope(ctx, ci, row)
		}
	}
}

// vxd_scopes walks the unit: a scope for the unit's own variables, which
// hold everywhere, then one for every procedure with code and everything
// below it.
vxd_scopes :: proc(ctx: ^Vxd_Unit_Ctx) {
	b := ctx.b
	u := ctx.u
	top := &u.dies[0]
	unit_row := u32(len(b.scopes))
	first := u32(len(b.vars))
	for ci in top.children {
		if u.dies[ci].tag == DW_TAG_variable {
			vxd_var_rows(ctx, ci)
		}
	}
	name := u32(0)
	if v, ok := dw_attr(top, DW_AT_name); ok {
		name = vxd_intern(b, v.text)
	}
	append(&b.scopes, Vxd_Scope{low = 0, high = 0xffff_ffff_ffff_ffff, parent = VXD_NO_SCOPE, name = name, first = first, nvars = u32(len(b.vars)) - first})
	for ci in top.children {
		if u.dies[ci].tag == DW_TAG_subprogram {
			vxd_scope(ctx, ci, unit_row)
		}
	}
}

// vxd_unit_for answers the unit whose line program sits at `stmt`, or a
// nameless one made for a program no unit claims.
vxd_unit_for :: proc(b: ^Vxd_Builder, stmt: u32) -> u32 {
	for u, i in b.units {
		if u.stmt == stmt {
			return u32(i)
		}
	}
	append(&b.units, Vxd_Unit{stmt = stmt})
	return u32(len(b.units) - 1)
}

/*
vxd_lines runs every line program in `.debug_line` and keeps the rows: an
address, a file and a line, in address order once sorted. The DWARF 4
header carries the directory and file tables, so the `files` table is
built here too. It has one entry per program file, with the path joined
to its directory or the unit's.
*/
vxd_lines :: proc(b: ^Vxd_Builder, data: []u8, secs: []Elf_Section, elf_path: string) {
	sec, has := elf_section(secs, ".debug_line")
	if !has {
		return
	}
	c := Dwarf_Cursor{data = data[sec.offset:][:sec.size]}
	for c.at < len(c.data) {
		program := c.at
		unit_length := dw_u32(&c)
		if unit_length == 0xffff_ffff {
			die("%s: a 64-bit line program, which this converter does not read", elf_path)
		}
		end := c.at + int(unit_length)
		version := dw_u16(&c)
		if version != 4 {
			die("%s: line table version %d, and this converter reads 4", elf_path, version)
		}
		header_length := dw_u32(&c)
		rows_at := c.at + int(header_length)
		min_inst := dw_u8(&c)
		_ = dw_u8(&c) // maximum operations per instruction: one, on every target here
		default_is_stmt := dw_u8(&c) != 0
		line_base := i64(i8(dw_u8(&c)))
		line_range := dw_u8(&c)
		opcode_base := dw_u8(&c)
		std_lengths := make([]u64, opcode_base)
		for i in 1 ..< int(opcode_base) {
			std_lengths[i] = dw_u8(&c)
		}
		unit := vxd_unit_for(b, u32(program))
		// Cloned out of the pool: the pool grows as paths are interned below,
		// and a string into it would point at wherever it was.
		unit_dir := ""
		if b.units[unit].dir != 0 {
			unit_dir = strings.clone(cstr_at(b.pool[:], int(b.units[unit].dir)))
		}
		dirs: [dynamic]string
		append(&dirs, unit_dir)
		for {
			d := dw_cstr(&c)
			if len(d) == 0 {
				break
			}
			append(&dirs, d)
		}
		// File one is the first entry; zero is "no file", which an end of
		// sequence row uses.
		first_file := u32(len(b.files))
		append(&b.files, Vxd_File{unit = unit, path = 0})
		for {
			name := dw_cstr(&c)
			if len(name) == 0 {
				break
			}
			dir := dw_uleb(&c)
			_ = dw_uleb(&c) // mtime
			_ = dw_uleb(&c) // length
			path := name
			if len(name) > 0 && name[0] != '/' && int(dir) < len(dirs) && len(dirs[dir]) > 0 {
				path = fmt.tprintf("%s/%s", dirs[dir], name)
			}
			append(&b.files, Vxd_File{unit = unit, path = vxd_intern(b, path)})
		}
		c.at = rows_at

		address := u64(0)
		file := u64(1)
		line := i64(1)
		is_stmt := default_is_stmt
		emit :: proc(b: ^Vxd_Builder, address: u64, first_file: u32, file: u64, line: i64, end_sequence: bool) {
			if end_sequence {
				append(&b.lines, Vxd_Line{addr = address, file = 0, line = 0})
				return
			}
			append(&b.lines, Vxd_Line{addr = address, file = first_file + u32(file), line = u32(max(line, 0))})
		}
		for c.at < end {
			op := dw_u8(&c)
			switch {
			case op == 0:
				n := dw_uleb(&c)
				sub_at := c.at
				sub := dw_u8(&c)
				switch sub {
				case 1:
					emit(b, address, first_file, file, line, true)
					address = 0
					file = 1
					line = 1
					is_stmt = default_is_stmt
				case 2:
					address = dw_u64(&c)
				case 3:
					// A file defined in the program rather than the header:
					// added the same way, at the next index.
					name := dw_cstr(&c)
					dir := dw_uleb(&c)
					_ = dw_uleb(&c)
					_ = dw_uleb(&c)
					path := name
					if len(name) > 0 && name[0] != '/' && int(dir) < len(dirs) && len(dirs[dir]) > 0 {
						path = fmt.tprintf("%s/%s", dirs[dir], name)
					}
					append(&b.files, Vxd_File{unit = unit, path = vxd_intern(b, path)})
				case 4:
					_ = dw_uleb(&c) // discriminator
				case:
					die("%s: extended line opcode %d", elf_path, sub)
				}
				c.at = sub_at + int(n)
			case op < opcode_base:
				switch op {
				case 1: emit(b, address, first_file, file, line, false)
				case 2: address += dw_uleb(&c) * u64(min_inst)
				case 3: line += dw_sleb(&c)
				case 4: file = dw_uleb(&c)
				case 5: _ = dw_uleb(&c) // column
				case 6: is_stmt = !is_stmt
				case 7: // basic block
				case 8: address += u64((255 - opcode_base) / line_range) * u64(min_inst)
				case 9: address += dw_u16(&c)
				case 10: // prologue end
				case 11: // epilogue begin
				case 12: _ = dw_uleb(&c) // isa
				case:
					// A standard opcode this reader does not know is skipped
					// by the length the header gave it.
					for _ in 0 ..< std_lengths[op] {
						_ = dw_uleb(&c)
					}
				}
			case:
				adjusted := u64(op - opcode_base)
				address += (adjusted / u64(line_range)) * u64(min_inst)
				line += line_base + i64(adjusted % u64(line_range))
				emit(b, address, first_file, file, line, false)
			}
		}
		c.at = end
	}
}

// vxd_procs takes every function symbol with a size out of `.symtab`.
// The symbol table names what DWARF's subprograms name and more, the
// assembly entry points too, and is the simpler source.
vxd_procs :: proc(b: ^Vxd_Builder, data: []u8, secs: []Elf_Section, elf_path: string) {
	sym, has := elf_section(secs, ".symtab")
	if !has {
		die("%s: no symbol table", elf_path)
	}
	strtab := secs[sym.link]
	STT_FUNC :: 2
	for at := sym.offset; at + 24 <= sym.offset + sym.size; at += 24 {
		info := data[at + 4]
		if info & 0xf != STT_FUNC {
			continue
		}
		value := u64le(data, at + 8)
		size := u64le(data, at + 16)
		if size == 0 {
			continue
		}
		name := cstr_at(data, strtab.offset + int(u32le(data, at)))
		append(&b.procs, Vxd_Proc{low = value, high = value + size, name = vxd_intern(b, name), unit = 0xffff_ffff})
	}
	// A compiler helper -- `__$equal$$struct{...}` -- that shares its start
	// with a named procedure is an alias of it, and the name a person wrote
	// is the one an address should answer. The helper goes.
	kept: [dynamic]Vxd_Proc
	for p in b.procs {
		name := cstr_at(b.pool[:], int(p.name))
		if strings.has_prefix(name, "__$") {
			twin := false
			for q in b.procs {
				if q.low == p.low && !strings.has_prefix(cstr_at(b.pool[:], int(q.name)), "__$") {
					twin = true
					break
				}
			}
			if twin {
				continue
			}
		}
		append(&kept, p)
	}
	delete(b.procs)
	b.procs = kept
}

// vxd_dis runs `llvm-objdump` over the program and keeps one line of text
// per instruction, so the machine never needs a decoder.
vxd_dis :: proc(b: ^Vxd_Builder, elf_path: string) {
	desc := os.Process_Desc {
		command = {"llvm-objdump", "-d", "--no-show-raw-insn", elf_path},
	}
	state, stdout, _, err := os.process_exec(desc, context.allocator)
	if err != nil || !state.success {
		die("%s: llvm-objdump did not run", elf_path)
	}
	text_out := string(stdout)
	for line in strings.split_lines_iterator(&text_out) {
		trimmed := strings.trim_left_space(line)
		colon := strings.index_byte(trimmed, ':')
		// An instruction is `addr: text`; a symbol's header is `addr <name>:`
		// with nothing after its colon, and a name may carry `::` of its own.
		if colon <= 0 || colon + 1 >= len(trimmed) || (trimmed[colon + 1] != ' ' && trimmed[colon + 1] != '\t') {
			continue
		}
		addr, ok := strconv.parse_u64_of_base(trimmed[:colon], 16)
		if !ok {
			continue
		}
		text := strings.trim_space(trimmed[colon + 1:])
		if len(text) == 0 {
			continue
		}
		// Tabs to one space, so a reader prints it as it is.
		cleaned, _ := strings.replace_all(text, "\t", " ")
		append(&b.dis, Vxd_Dis{addr = addr, text = vxd_intern(b, cleaned)})
	}
}

vxd_arch_id :: proc(arch: Arch) -> u32 {
	switch arch {
	case .amd64:   return 1
	case .arm64:   return 2
	case .riscv64: return 3
	}
	return 0
}

// vxd_put appends one table's bytes to `out` and records its directory row.
vxd_write_table :: proc(out: ^[dynamic]u8, dir: ^[dynamic]u8, kind: Vxd_Table, entry: int, count: int, bytes: []u8) {
	if count == 0 {
		return
	}
	offset := len(out)
	append(out, ..bytes)
	put_u32(dir, u32(kind))
	put_u32(dir, u32(entry))
	put_u64(dir, u64(count))
	put_u64(dir, u64(offset))
}

put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

put_u64 :: proc(out: ^[dynamic]u8, v: u64) {
	put_u32(out, u32(v))
	put_u32(out, u32(v >> 32))
}

elf_to_debug :: proc(elf_path: string, out_path: string, arch: Arch, with_dis: bool) {
	data := read_elf(elf_path)
	defer delete(data)
	secs := elf_sections(data)
	b: Vxd_Builder
	_ = vxd_intern(&b, "")

	vxd_units(&b, data, secs, elf_path)
	vxd_lines(&b, data, secs, elf_path)
	vxd_procs(&b, data, secs, elf_path)
	if with_dis {
		vxd_dis(&b, elf_path)
	}

	// Sorted on their keys, which is what the reader's binary searches
	// stand on. Rows with one address keep their order.
	slice.stable_sort_by(b.procs[:], proc(x, y: Vxd_Proc) -> bool {return x.low < y.low})
	slice.stable_sort_by(b.lines[:], proc(x, y: Vxd_Line) -> bool {return x.addr < y.addr})
	slice.stable_sort_by(b.dis[:], proc(x, y: Vxd_Dis) -> bool {return x.addr < y.addr})
	// Scopes sort by their start, and a nested one after the one around it.
	// The same start means the outer one first, which is the order they
	// were made in. `parent` rows are indices, so the sort must keep them,
	// and a permutation is applied to the links after.
	vxd_sort_scopes(&b)
	for p, i in b.procs {
		append(&b.names, Vxd_Name{name = p.name, index = u32(i)})
	}
	pool := b.pool[:]
	context.user_ptr = &pool
	slice.sort_by(b.names[:], proc(x, y: Vxd_Name) -> bool {
		pool := (^[]u8)(context.user_ptr)^
		return cstr_at(pool, int(x.name)) < cstr_at(pool, int(y.name))
	})

	// The header and directory come first, so the reader knows where every
	// table is from sixteen bytes and the rows after them. The directory is
	// written after the tables are laid out, at a size fixed by the count.
	tables := 11
	dir_size := tables * 24
	body: [dynamic]u8
	dir: [dynamic]u8
	// Offsets in the directory are from the start of the file, so the
	// body starts where the directory ends.
	for _ in 0 ..< 16 + dir_size {
		append(&body, 0)
	}
	vxd_write_table(&body, &dir, .Units, 16, len(b.units), slice.to_bytes(b.units[:]))
	vxd_write_table(&body, &dir, .Files, 8, len(b.files), slice.to_bytes(b.files[:]))
	vxd_write_table(&body, &dir, .Procs, 24, len(b.procs), slice.to_bytes(b.procs[:]))
	vxd_write_table(&body, &dir, .Lines, 16, len(b.lines), slice.to_bytes(b.lines[:]))
	vxd_write_table(&body, &dir, .Names, 8, len(b.names), slice.to_bytes(b.names[:]))
	vxd_write_table(&body, &dir, .Dis, 16, len(b.dis), slice.to_bytes(b.dis[:]))
	vxd_write_table(&body, &dir, .Types, 32, len(b.types), slice.to_bytes(b.types[:]))
	vxd_write_table(&body, &dir, .Members, 16, len(b.members), slice.to_bytes(b.members[:]))
	vxd_write_table(&body, &dir, .Scopes, 32, len(b.scopes), slice.to_bytes(b.scopes[:]))
	vxd_write_table(&body, &dir, .Vars, 40, len(b.vars), slice.to_bytes(b.vars[:]))
	vxd_write_table(&body, &dir, .Strings, 1, len(b.pool), b.pool[:])
	written := len(dir) / 24
	head: [dynamic]u8
	put_u32(&head, VXD_MAGIC)
	put_u32(&head, VXD_VERSION)
	put_u32(&head, vxd_arch_id(arch))
	put_u32(&head, u32(written))
	copy(body[:16], head[:])
	copy(body[16:16 + len(dir)], dir[:])
	if werr := os.write_entire_file(out_path, body[:]); werr != nil {
		die("cannot write %s", out_path)
	}
	step("%s: %d units, %d files, %d procedures, %d line rows, %d types, %d scopes, %d variable rows, %d instructions, %d bytes",
		out_path, len(b.units), len(b.files), len(b.procs), len(b.lines), len(b.types), len(b.scopes), len(b.vars), len(b.dis), len(body))
}

// vxd_sort_scopes orders the scope rows by start address, keeping a scope
// before the ones nested in it. Every `parent` link is rewritten for the
// new order.
vxd_sort_scopes :: proc(b: ^Vxd_Builder) {
	n := len(b.scopes)
	order := make([]int, n)
	for i in 0 ..< n {
		order[i] = i
	}
	rows := b.scopes[:]
	context.user_ptr = &rows
	slice.sort_by(order, proc(x, y: int) -> bool {
		rows := (^[]Vxd_Scope)(context.user_ptr)^
		a, c := rows[x], rows[y]
		if a.low != c.low {
			return a.low < c.low
		}
		if a.high != c.high {
			return a.high > c.high
		}
		return x < y
	})
	place := make([]u32, n)
	for old, new_i in order {
		place[old] = u32(new_i)
	}
	sorted := make([dynamic]Vxd_Scope, 0, n)
	for old in order {
		r := b.scopes[old]
		if r.parent != VXD_NO_SCOPE {
			r.parent = place[r.parent]
		}
		append(&sorted, r)
	}
	delete(b.scopes)
	b.scopes = sorted
}
