// vx-input keymap: a keyboard's HID usages as runes (M7 step 7c1). The US
// layout only, until 7d2's keymaps: the rune a key types unshifted and
// shifted. inputd uses it for each key record's unmodified rune and to type
// into the console; winsrv will resolve dead keys and compose over it (03 §5).

#pragma once

#include <stdint.h>

#include "../vx-driver/inputproto.h"

// Usages 0x04 to 0x38 of the keyboard page: letters, digits, and the keys
// between; unshifted, then shifted. 0: no rune.
static const char VX_KEYMAP_US[2][0x39] = {
    {0,   0,   0,    0,    'a',  'b',  'c', 'd', 'e', 'f', 'g', 'h',  'i', 'j', 'k',  'l', 'm', 'n', 'o',
     'p', 'q', 'r',  's',  't',  'u',  'v', 'w', 'x', 'y', 'z', '1',  '2', '3', '4',  '5', '6', '7', '8',
     '9', '0', '\n', 0x1b, 0x08, '\t', ' ', '-', '=', '[', ']', '\\', 0,   ';', '\'', '`', ',', '.', '/'},
    {0,   0,   0,    0,    'A',  'B',  'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
     'P', 'Q', 'R',  'S',  'T',  'U',  'V', 'W', 'X', 'Y', 'Z', '!', '@', '#', '$', '%', '^', '&', '*',
     '(', ')', '\n', 0x1b, 0x08, '\t', ' ', '_', '+', '{', '}', '|', 0,   ':', '"', '~', '<', '>', '?'},
};

// The rune a usage types with these modifiers, or 0 for none (a modifier, a
// function key). Caps lock shifts letters only; control makes a letter's
// control character.
[[maybe_unused]] static uint32_t vx_keymap_rune(uint32_t usage, uint32_t mods) {
  if (usage >> 16 != VX_HID_KEYBOARD >> 16) return 0;
  uint32_t id = usage & 0xffff;
  if (id == 0x4c) return 0x7f;                            // delete
  if (id == 0x58) return '\n';                            // the keypad's enter
  if (id >= 0x54 && id <= 0x57) return "/*-+"[id - 0x54]; // the keypad's operators
  if (id >= 0x59 && id <= 0x62) return id == 0x62 ? '0' : '1' + (id - 0x59);
  if (id >= sizeof VX_KEYMAP_US[0]) return 0;
  bool letter = id >= 0x04 && id <= 0x1d;
  bool shift = (mods & VX_MOD_SHIFT) != 0;
  if (letter && mods & VX_MOD_CAPS) shift = !shift;
  uint32_t r = (uint8_t)VX_KEYMAP_US[shift][id];
  if (letter && mods & VX_MOD_CTRL) return r & 0x1f;
  return r;
}
