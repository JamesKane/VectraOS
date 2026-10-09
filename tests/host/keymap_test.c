// keymap_test.c: lib/vx-input/keymap.h (M7 steps 7c1, 7d2b): US runes with
// shift, caps lock and control; us-intl's dead keys; the combinations dead
// keys and compose make.

#include <stdint.h>

#include "check.h"
#include "../../lib/vx-input/keymap.h"

static uint32_t K(uint32_t id) { return VX_HID_KEYBOARD | id; }

int main(void) {
  CHECK(vx_keymap_rune(K(0x04), 0) == 'a' && vx_keymap_rune(K(0x04), VX_MOD_SHIFT) == 'A');
  CHECK(vx_keymap_rune(K(0x04), VX_MOD_CAPS) == 'A' &&
        vx_keymap_rune(K(0x04), VX_MOD_CAPS | VX_MOD_SHIFT) == 'a');
  CHECK(vx_keymap_rune(K(0x1e), VX_MOD_CAPS) == '1' && vx_keymap_rune(K(0x1e), VX_MOD_SHIFT) == '!');
  CHECK(vx_keymap_rune(K(0x06), VX_MOD_CTRL) == 0x03); // ^C
  CHECK(vx_keymap_rune(K(0x28), 0) == '\n' && vx_keymap_rune(K(0xe1), 0) == 0 &&
        vx_keymap_rune(VX_HID_BUTTON | 1, 0) == 0);
  // us-intl: ' " ` ~ ^ are dead; US has none, and control makes none.
  CHECK(vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x34), 0) == '\'' &&
        vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x34), VX_MOD_SHIFT) == '"');
  CHECK(vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x23), VX_MOD_SHIFT) == '^' &&
        vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x35), VX_MOD_SHIFT) == '~');
  CHECK(vx_keymap_dead(VX_LAYOUT_US, K(0x34), 0) == 0 &&
        vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x34), VX_MOD_CTRL) == 0);
  CHECK(vx_keymap_dead(VX_LAYOUT_US_INTL, K(0x04), 0) == 0);
  // Combinations: accents either way round, pairs as X11 has them.
  CHECK(vx_keymap_combine('\'', 'e') == 0xe9 && vx_keymap_combine('e', '\'') == 0xe9);
  CHECK(vx_keymap_combine('"', 'U') == 0xdc && vx_keymap_combine('~', 'n') == 0xf1 &&
        vx_keymap_combine('`', 'a') == 0xe0);
  CHECK(vx_keymap_combine('o', 'c') == 0xa9 && vx_keymap_combine('s', 's') == 0xdf &&
        vx_keymap_combine('-', '-') == 0x2014);
  CHECK(vx_keymap_combine('\'', 'q') == 0 && vx_keymap_combine('x', 'y') == 0 &&
        vx_keymap_combine('~', 'e') == 0);
  return check_result();
}
