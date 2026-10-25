// The kernel console's buffer (see include/console.h for why it is C).

#include "console.h"

static uint8_t buffer[CROI_CONSOLE_BUFFER_SIZE];

uint8_t *croi_console_buffer(void) { return buffer; }
