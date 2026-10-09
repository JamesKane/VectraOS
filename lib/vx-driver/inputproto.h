// The input class protocol (docs/proto/input.md; M7 step 7c1): between an
// input driver (drv-virtio-input; USB HID's later) and inputd, on a channel
// the driver hands inputd from its post. The driver sends: DEVICE once, then
// EVENTS, a batch of records each time it wakes with input, never merged.
// inputd sends nothing on it but LEDS (version 1: none).

#pragma once

#include "../../abi/vx/abi.h"

enum : uint32_t {
  VX_INPUT_CONNECT = 0x706e'6963
}; // "cinp": the post's one request; the reply carries the channel
static constexpr uint32_t VX_INPUT_VERSION = 1;

enum : uint32_t { VX_INPUT_DEVICE = 1, VX_INPUT_EVENTS = 2 }; // the session's messages, driver to inputd
// inputd's client (winsrv, 7d1c) sends CONNECT on /srv/input and is given a
// session on which every device's DEVICE and EVENTS come as the drivers sent
// them, each message's header flags the device's post number, and GONE
// (a header alone) when a device's driver has gone.
enum : uint32_t { VX_INPUT_GONE = 3 };

enum : uint8_t { VX_INPUT_KEYBOARD = 1, VX_INPUT_POINTER = 2 };
enum : uint8_t { VX_INPUT_ABSOLUTE = 1, VX_INPUT_RELATIVE = 2, VX_INPUT_WHEEL = 4 }; // a pointer's axes

// DEVICE: what it is. An absolute pointer's x and y run from 0 to x_max and
// y_max, the device's own range (a tablet's 0..32767), which a reader scales
// to its output.
typedef struct vx_input_device {
  vx_msg_header h;
  uint32_t version; // VX_INPUT_VERSION
  uint8_t kind;     // KEYBOARD or POINTER
  uint8_t axes;     // a pointer's
  uint16_t reserved;
  uint32_t x_max, y_max;
  char name[64]; // the device's, NUL-padded: "QEMU Virtio Keyboard"
} vx_input_device;

// A key's HID usage: page << 16 | id. The keyboard page is 7; mouse buttons
// are the button page, 9, from 1 (left, right, middle, ...).
static constexpr uint32_t VX_HID_KEYBOARD = 0x07 << 16, VX_HID_BUTTON = 0x09 << 16;
static constexpr uint32_t VX_INPUT_HELD = 12; // keys held at once, at most, in a record

enum : uint8_t { VX_KEY_UP = 0, VX_KEY_DOWN = 1, VX_KEY_REPEAT = 2 };

// The modifiers held, from the held set (left and right alike).
enum : uint32_t {
  VX_MOD_SHIFT = 1,
  VX_MOD_CTRL = 2,
  VX_MOD_ALT = 4,
  VX_MOD_META = 8,
  VX_MOD_ALTGR = 16, // the right Alt
  VX_MOD_CAPS = 32,  // caps lock, as a toggle: on after an odd number of presses
};

// One key changing, and the whole held set after it (9front's kbdfs sends
// it so, which makes chords and focus changes trivial: 21 §2 item 6).
typedef struct vx_input_key {
  uint64_t time; // vx_clock's ns: when the driver saw it
  uint32_t usage;
  uint8_t action; // UP, DOWN, REPEAT
  uint8_t nheld;
  uint16_t reserved;
  uint32_t mods;
  uint32_t held[VX_INPUT_HELD];
} vx_input_key;
static_assert(sizeof(vx_input_key) == 72);

// One report of a pointer: where it is (absolute), how far it moved
// (relative), the wheel's turn, and the buttons held after it, bit n-1 for
// button n.
typedef struct vx_input_pointer {
  uint64_t time;
  int32_t x, y;   // absolute, in the device's range; else 0
  int32_t dx, dy; // relative
  int32_t wheel, hwheel;
  uint32_t buttons;
  uint32_t reserved;
} vx_input_pointer;
static_assert(sizeof(vx_input_pointer) == 40);

static constexpr uint32_t VX_INPUT_BATCH = 64; // records in an EVENTS message, at most

// EVENTS: count records, all of the device's kind.
typedef struct vx_input_events {
  vx_msg_header h;
  uint32_t count;
  uint32_t reserved;
  union {
    vx_input_key key[VX_INPUT_BATCH];
    vx_input_pointer pointer[VX_INPUT_BATCH];
  };
} vx_input_events;

// The bytes of an EVENTS message with count records of this kind.
[[maybe_unused]] static uint32_t vx_input_events_len(uint8_t kind, uint32_t count) {
  return (uint32_t)offsetof(vx_input_events, key) + count * (kind == VX_INPUT_KEYBOARD
                                                                 ? (uint32_t)sizeof(vx_input_key)
                                                                 : (uint32_t)sizeof(vx_input_pointer));
}

// The modifiers a held set gives, but caps lock, which is a toggle.
[[maybe_unused]] static uint32_t vx_input_mods(const uint32_t *held, uint32_t n) {
  uint32_t m = 0;
  for (uint32_t i = 0; i < n; i++) switch (held[i]) {
    case VX_HID_KEYBOARD | 0xe1:
    case VX_HID_KEYBOARD | 0xe5: m |= VX_MOD_SHIFT; break;
    case VX_HID_KEYBOARD | 0xe0:
    case VX_HID_KEYBOARD | 0xe4: m |= VX_MOD_CTRL; break;
    case VX_HID_KEYBOARD | 0xe2: m |= VX_MOD_ALT; break;
    case VX_HID_KEYBOARD | 0xe6: m |= VX_MOD_ALTGR; break;
    case VX_HID_KEYBOARD | 0xe3:
    case VX_HID_KEYBOARD | 0xe7: m |= VX_MOD_META; break;
    default: break;
    }
  return m;
}
