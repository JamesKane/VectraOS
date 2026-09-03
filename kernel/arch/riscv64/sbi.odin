/*
The supervisor binary interface: what the firmware below the kernel does on
its behalf.

A hart in supervisor mode cannot program the machine-mode timer, cannot
interrupt another hart, and on this board reaches the console through a
device it has not mapped yet. OpenSBI does all three on request. A request
is an `ecall` with the extension in `a7`, the function in `a6`, arguments
in `a0` upward, and an error and a value back in `a0` and `a1`.

Every call here is in the specification's version 2. The legacy console is
kept as the fallback for a firmware without the debug console, because a
kernel that cannot say anything cannot say why.
*/
package riscv64

SBI_EXT_BASE :: u64(0x10)
SBI_EXT_TIME :: u64(0x5449_4D45) // "TIME"
SBI_EXT_IPI :: u64(0x73_5049)    // "sPI"
SBI_EXT_DBCN :: u64(0x4442_434E) // "DBCN"
SBI_LEGACY_PUTCHAR :: u64(0x01)
SBI_LEGACY_GETCHAR :: u64(0x02)

SBI_SUCCESS :: i64(0)

// sbi_call makes one request and returns what came back.
sbi_call :: proc "contextless" (ext, fn, a0, a1, a2: u64) -> (err: i64, value: i64) {
	e, v, _, _, _ := asm(ext, fn, a0, a1, a2: u64) -> (e: i64, v: i64, x6: u64, x7: u64, x2: u64) [ext -> x7 = %a7, fn -> x6 = %a6, a0 -> e = %a0, a1 -> v = %a1, a2 -> x2 = %a2, #clobber memory, #volatile] { #byte 0x73, 0x00, 0x00, 0x00 }(ext, fn, a0, a1, a2)
	return e, v
}

// sbi_probe reports whether the firmware implements an extension.
sbi_probe :: proc "contextless" (ext: u64) -> bool {
	err, value := sbi_call(SBI_EXT_BASE, 3, ext, 0, 0)
	return err == SBI_SUCCESS && value != 0
}

// sbi_set_timer asks for a timer interrupt when `time` passes `deadline`.
sbi_set_timer :: proc "contextless" (deadline: u64) {
	_, _ = sbi_call(SBI_EXT_TIME, 0, deadline, 0, 0)
}

// sbi_send_ipi raises a supervisor software interrupt on every hart in
// `mask`, whose bit 0 is hart `base`.
sbi_send_ipi :: proc "contextless" (mask: u64, base: u64) {
	_, _ = sbi_call(SBI_EXT_IPI, 0, mask, base, 0)
}

// -- The console ----------------------------------------------------------------

@(private = "file") have_dbcn: bool
@(private = "file") have_putchar: bool
@(private = "file") have_getchar: bool

// console_available probes the firmware once, for the three calls the
// console is made of. `kernel/drivers/uart` asks before the first byte and
// keeps the answer in `Port.present`, so nothing below asks again.
console_available :: proc "contextless" () -> bool {
	have_dbcn = sbi_probe(SBI_EXT_DBCN)
	have_putchar = sbi_probe(SBI_LEGACY_PUTCHAR)
	have_getchar = sbi_probe(SBI_LEGACY_GETCHAR)
	return have_dbcn || have_putchar
}

/*
console_write puts a run of bytes on the console with one call, where the
firmware has the debug console, and byte by byte where it has only the
legacy one. The debug console takes the buffer by physical address, which
`physical` answers for an address in the image or the direct map; a buffer
anywhere else goes the byte way.
*/
console_write :: proc "contextless" (bytes: []u8) {
	if len(bytes) == 0 {
		return
	}
	if have_dbcn {
		if phys := physical(uintptr(raw_data(bytes))); phys != 0 {
			_, _ = sbi_call(SBI_EXT_DBCN, 0, u64(len(bytes)), phys, 0)
			return
		}
	}
	for b in bytes {
		console_write_byte(b)
	}
}

console_write_byte :: proc "contextless" (b: u8) {
	if have_dbcn {
		_, _ = sbi_call(SBI_EXT_DBCN, 2, u64(b), 0, 0)
	} else if have_putchar {
		_, _ = sbi_call(SBI_LEGACY_PUTCHAR, 0, u64(b), 0, 0)
	}
}

// console_read_byte polls the firmware console. Only the legacy call can
// answer a byte at a time without a buffer in physical memory, so the debug
// console's read is not used here.
console_read_byte :: proc "contextless" () -> (u8, bool) {
	if !have_getchar {
		return 0, false
	}
	err, _ := sbi_call(SBI_LEGACY_GETCHAR, 0, 0, 0, 0)
	if err < 0 {
		return 0, false
	}
	return u8(err), true
}
