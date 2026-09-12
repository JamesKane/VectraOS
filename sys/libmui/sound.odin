/*
relay clicks -- the desktop's sound, `docs/HANDOFF.md` section 1's
"tracker-synthesised relay clicks". A MUI gadget that activates plays a short
click, the tick of a 1994 workstation's relay, synthesised here rather than
sampled, and written to `/dev/audio`. `activate` is the one place a gadget
acts, so it is the one place the click is played, and every program on the
toolkit gets it for free.

A machine with no sound card is silent: the device does not open, and a click
is a no-op. The device is shared -- any program may write it -- so a desktop of
several MUI programs each plays its own clicks, and two that land together only
overlap for the few milliseconds a click lasts.

`/dev/audio` drains at real time, so a write of the click is the click's own
length on whatever thread activated the gadget -- the mouse's or the
keyboard's, never a painter -- and a few milliseconds there is below noticing.
*/
package libmui

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libuser"

// ~6.7 ms at 48 kHz: a tick, not a tone.
CLICK_FRAMES :: 320

@(private = "file") audio_fd: int = -2 // -2 before the first click, -1 no card, else open
@(private = "file") click_pcm: [CLICK_FRAMES * 2]i16 // interleaved stereo, made once

// click_synth fills the buffer once: a xorshift for the grain of the noise, a
// linear fall for the envelope, both channels the same. A burst of noise under
// a fast fall is a tick; a tone would be a beep, which a relay is not.
@(private = "file")
click_synth :: proc "contextless" () #no_bounds_check {
	lfsr: u32 = 0x2545F491
	for i in 0 ..< CLICK_FRAMES {
		lfsr ~= lfsr << 13
		lfsr ~= lfsr >> 17
		lfsr ~= lfsr << 5
		noise := i32(i16(u16(lfsr & 0xFFFF)))
		s := noise * 6000 / 32768 // the burst's amplitude
		s = s * i32(CLICK_FRAMES - i) / CLICK_FRAMES // falling to nothing
		v := i16(clamp(s, -32768, 32767))
		click_pcm[i * 2 + 0] = v
		click_pcm[i * 2 + 1] = v
	}
}

// sound_open opens `/dev/audio` and reads its format, once. The card this
// system drives is 48000 2 16 or there is none; anything else, or no card at
// all, leaves clicks silent rather than writing samples a different shape
// would mangle.
@(private = "file")
sound_open :: proc "contextless" () #no_bounds_check {
	audio_fd = -1
	fd := libuser.open("/dev/audio", abi.O_RDWR)
	if fd < 0 {
		return
	}
	fbuf: [32]u8
	fn := libuser.read(int(fd), fbuf[:])
	at := 0
	hz, hz_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
	chn, chn_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
	bits, bits_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
	if !hz_ok || !chn_ok || !bits_ok || hz != 48000 || chn != 2 || bits != 16 {
		_ = libuser.close(int(fd))
		return
	}
	click_synth()
	audio_fd = int(fd)
}

// relay_click plays one click, the sound a gadget makes when it acts. Silent
// on a machine with no card, and never an error a caller checks: a desktop
// without its tick is a quieter desktop, not a broken one.
relay_click :: proc "contextless" () #no_bounds_check {
	if audio_fd == -2 {
		sound_open()
	}
	if audio_fd < 0 {
		return
	}
	bytes := ([^]u8)(raw_data(click_pcm[:]))[:len(click_pcm) * 2]
	_ = libuser.write(audio_fd, bytes)
}
