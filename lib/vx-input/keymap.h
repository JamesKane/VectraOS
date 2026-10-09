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

// --- Layouts, dead keys and compose (M7 step 7d2b) ---

// The layouts winsrv knows: US, and US international, whose ' ` ^ " ~ are
// dead keys (the accent waits for the next key).
enum vx_keymap_layout { VX_LAYOUT_US, VX_LAYOUT_US_INTL, VX_LAYOUTS };
static const char *const VX_KEYMAP_NAMES[VX_LAYOUTS] = {"us", "us-intl"};

// The accent a key is in this layout, if it is a dead one there; else 0.
[[maybe_unused]] static uint32_t vx_keymap_dead(enum vx_keymap_layout layout, uint32_t usage, uint32_t mods) {
  if (layout != VX_LAYOUT_US_INTL || mods & (VX_MOD_CTRL | VX_MOD_ALT | VX_MOD_META)) return 0;
  uint32_t r = vx_keymap_rune(usage, mods);
  return r == '\'' || r == '`' || r == '^' || r == '"' || r == '~' ? r : 0;
}

// Two runes combined, as a dead key and its next key or the two after the
// compose key are: an accent and a letter (either order for compose), or
// one of X11's common pairs. 0: they make nothing.
[[maybe_unused]] static uint32_t vx_keymap_combine(uint32_t a, uint32_t b) {
  static const struct {
    char accent, base;
    uint16_t made;
  } TABLE[] = {
      // Accents and letters.
      {'\'', 'a', 0xe1}, {'\'', 'e', 0xe9}, {'\'', 'i', 0xed},  {'\'', 'o', 0xf3},  {'\'', 'u', 0xfa},
      {'\'', 'y', 0xfd}, {'\'', 'A', 0xc1}, {'\'', 'E', 0xc9},  {'\'', 'I', 0xcd},  {'\'', 'O', 0xd3},
      {'\'', 'U', 0xda}, {'\'', 'Y', 0xdd}, {'\'', 'c', 0x107}, {'\'', 'C', 0x106}, {'`', 'a', 0xe0},
      {'`', 'e', 0xe8},  {'`', 'i', 0xec},  {'`', 'o', 0xf2},   {'`', 'u', 0xf9},   {'`', 'A', 0xc0},
      {'`', 'E', 0xc8},  {'`', 'I', 0xcc},  {'`', 'O', 0xd2},   {'`', 'U', 0xd9},   {'^', 'a', 0xe2},
      {'^', 'e', 0xea},  {'^', 'i', 0xee},  {'^', 'o', 0xf4},   {'^', 'u', 0xfb},   {'^', 'A', 0xc2},
      {'^', 'E', 0xca},  {'^', 'I', 0xce},  {'^', 'O', 0xd4},   {'^', 'U', 0xdb},   {'"', 'a', 0xe4},
      {'"', 'e', 0xeb},  {'"', 'i', 0xef},  {'"', 'o', 0xf6},   {'"', 'u', 0xfc},   {'"', 'y', 0xff},
      {'"', 'A', 0xc4},  {'"', 'E', 0xcb},  {'"', 'I', 0xcf},   {'"', 'O', 0xd6},   {'"', 'U', 0xdc},
      {'~', 'a', 0xe3},  {'~', 'o', 0xf5},  {'~', 'n', 0xf1},   {'~', 'A', 0xc3},   {'~', 'O', 0xd5},
      {'~', 'N', 0xd1},
  };
  static const struct {
    char a, b;
    uint16_t made;
  } PAIRS[] = {{'o', 'c', 0xa9}, {'o', 'r', 0xae}, {'s', 's', 0xdf},   {'-', '-', 0x2014}, {'<', '<', 0xab},
               {'>', '>', 0xbb}, {'a', 'e', 0xe6}, {'e', '=', 0x20ac}, {'1', '2', 0xbd},   {'o', 'o', 0xb0}};
  for (size_t i = 0; i < sizeof TABLE / sizeof TABLE[0]; i++) { // an accent and a letter, either way round
    uint32_t accent = (uint8_t)TABLE[i].accent, base = (uint8_t)TABLE[i].base;
    if ((a == accent && b == base) || (a == base && b == accent)) return TABLE[i].made;
  }
  for (size_t i = 0; i < sizeof PAIRS / sizeof PAIRS[0]; i++)
    if ((uint32_t)(uint8_t)PAIRS[i].a == a && (uint32_t)(uint8_t)PAIRS[i].b == b) return PAIRS[i].made;
  return 0;
}
