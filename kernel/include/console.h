// The kernel console's buffer (Uart.swift's ConsoleBuffer): what the
// kernel writes to its console waits here for the debuglog's dumper to
// print, so boot doesn't wait on a serial port (115200 baud prints about
// 11 bytes a millisecond). C because a large Swift global is initialized
// lazily; this one is .bss.

#pragma once

#include <stdint.h>

enum : uint32_t { CROI_CONSOLE_BUFFER_SIZE = 16384 };

// Its CROI_CONSOLE_BUFFER_SIZE bytes (Swift imports a C array as a tuple,
// and one this long not at all).
uint8_t *croi_console_buffer(void);
