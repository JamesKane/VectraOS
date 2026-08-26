/*
Vectra build driver.

Run it with:

    odin run build.odin -file -- <target> [options]

Targets:
    kernel   Compile and link kernel/ into build/vectra.elf   (default)
    esp      Stage a bootable EFI system partition in build/esp
    run      esp, then boot it under QEMU
    debug    run, but halted and waiting for gdb on :1234
    clean    Remove build/

Options:
    --arch=amd64|arm64|riscv64   Target architecture (default: amd64)
    --release                    Optimise, otherwise a debug build
    --serial=stdio|file          Where QEMU's COM1 goes (default: stdio)
    --gfx                        Open a QEMU window, otherwise headless

An Odin program rather than a shell script, for one reason. The flag handling,
the arch table and the link line will all grow per-architecture.

This way they grow in the same language, and the same type system, as the thing
they build. `justfile` and `Makefile` are thin wrappers over this.
*/
#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:strings"

BUILD_DIR :: "build"
ESP_DIR :: "build/esp"
KERNEL_ELF :: "build/vectra.elf"
KERNEL_OBJ :: "build/vectra.o"

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
	ld_emulation:  string,
	link_script:   string,
	qemu:          string,
	qemu_machine:  []string,
	efi_boot_name: string,
}

// Machine lines live at package scope: a slice of a compound literal built
// inside arch_config would point into that call's stack frame.
qemu_amd64_machine := [?]string{"-machine", "q35", "-cpu", "qemu64", "-m", "512M"}
qemu_arm64_machine := [?]string{"-machine", "virt", "-cpu", "cortex-a72", "-m", "512M"}
qemu_riscv64_machine := [?]string{"-machine", "virt", "-m", "512M"}

arch_config :: proc(arch: Arch) -> Arch_Config {
	switch arch {
	case .amd64:
		return {
			odin_target   = "freestanding_amd64_sysv",
			ld_emulation  = "elf_x86_64",
			link_script   = "kernel/link_amd64.ld",
			qemu          = "qemu-system-x86_64",
			qemu_machine  = qemu_amd64_machine[:],
			efi_boot_name = "BOOTX64.EFI",
		}
	case .arm64:
		return {
			odin_target   = "freestanding_arm64",
			ld_emulation  = "aarch64elf",
			link_script   = "kernel/link_arm64.ld",
			qemu          = "qemu-system-aarch64",
			qemu_machine  = qemu_arm64_machine[:],
			efi_boot_name = "BOOTAA64.EFI",
		}
	case .riscv64:
		return {
			odin_target   = "freestanding_riscv64",
			ld_emulation  = "elf64lriscv",
			link_script   = "kernel/link_riscv64.ld",
			qemu          = "qemu-system-riscv64",
			qemu_machine  = qemu_riscv64_machine[:],
			efi_boot_name = "BOOTRISCV64.EFI",
		}
	}
	return {}
}

Options :: struct {
	target:  string,
	arch:    Arch,
	release: bool,
	serial:  string,
	gfx:     bool,

	// Everything after the target, handed to the target untouched. Only
	// `lint` reads it, so that `build lint --show docs` reaches the checker.
	passthrough: []string,
}

main :: proc() {
	opts := Options {
		target = "kernel",
		arch   = .amd64,
		serial = "stdio",
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
	case "kernel": build_kernel(opts)
	case "esp":    stage_esp(opts)
	case "run":    stage_esp(opts); run_qemu(opts, debug = false)
	case "debug":  stage_esp(opts); run_qemu(opts, debug = true)
	case "clean":  clean()
	case "lint":   lint(opts)
	case:
		die("unknown target %q (want kernel, esp, run, debug, clean, lint)", opts.target)
	}
}

// -- Targets -----------------------------------------------------------------

build_kernel :: proc(opts: Options) {
	cfg := arch_config(opts.arch)
	ensure_dir(BUILD_DIR)

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

	step("linking %s", KERNEL_ELF)
	run({
		"ld.lld", KERNEL_OBJ,
		"-o", KERNEL_ELF,
		"-m", cfg.ld_emulation,
		"-T", cfg.link_script,
		"-nostdlib",
		"-static",
		"-pie",
		"--no-dynamic-linker",
		"-z", "text",
		"-z", "max-page-size=0x1000",
	})

	if info, err := os.stat(KERNEL_ELF, context.allocator); err == nil {
		step("kernel image is %d bytes", info.size)
	}
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
}

run_qemu :: proc(opts: Options, debug: bool) {
	cfg := arch_config(opts.arch)

	args := [dynamic]string{cfg.qemu}
	append(&args, ..cfg.qemu_machine)

	// OVMF firmware, borrowed from the neighbouring odin-os checkout until we
	// vendor our own.
	firmware := "../odin-os/ovmf/ovmf_x64.fd"
	if opts.arch == .amd64 && os.exists(firmware) {
		append(&args, "-bios", firmware)
	} else if opts.arch == .amd64 {
		die("no OVMF firmware at %s -- UEFI boot needs it", firmware)
	}

	append(&args, "-drive", fmt.tprintf("format=raw,file=fat:rw:%s", ESP_DIR))
	append(&args, "-net", "none")

	switch opts.serial {
	case "stdio": append(&args, "-serial", "stdio")
	case "file":  append(&args, "-serial", "file:build/serial.log")
	case:         die("unknown --serial=%s (want stdio or file)", opts.serial)
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

// -- Process and file helpers ------------------------------------------------

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
