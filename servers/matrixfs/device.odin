/*
The devices this one has learned the keys of, and the requester that
verifies one: `docs/WEB.md` section 8's "a device is verified in a
requester". A device is known from a key query when a room key goes
to it, or from a room key that came from it. Each is a directory:

    /mnt/matrix/devices/<device>/user          whose it is
    /mnt/matrix/devices/<device>/curve25519    its identity key
    /mnt/matrix/devices/<device>/ed25519       its signing key
    /mnt/matrix/devices/<device>/fingerprint   the signing key in groups of four, as the other screen shows it
    /mnt/matrix/devices/<device>/verified      yes or no

`verify <device>` on `ctl` is the requester: the fingerprint goes on
`ctl` as `verify <device> <fingerprint>`, into `notify/` as a message
from the device's user, and to Workbench's notice file when the desktop
is up, asking the person to compare it with what the other screen shows.
`verified <device>` is the person's yes. A sealed message from a device
not verified carries a subject that says so, every one it sent.
*/
package matrixfs

import "vsys:abi"
import "vsys:libmsg"
import "vsys:libuser"

MAX_DEVICES :: 32

Known_Device :: struct {
	used:     bool,
	user:     [NAME_MAX]u8,
	ulen:     int,
	id:       [64]u8,
	ilen:     int,
	verified: bool,
}

devices: [MAX_DEVICES]Known_Device
asking: [64]u8 // The device a verify is pending for, or none
asking_len: int

// note_device keeps a device's keys, under its id in `devices/`, and
// answers its record. A device seen before keeps whether it was verified.
note_device :: proc(user: string, id: string, curve_b64: string, ed_b64: string) -> ^Known_Device {
	if id == "" || len(id) > 63 || len(user) > NAME_MAX {
		return nil
	}
	d := device_by_id(id)
	if d == nil {
		for &k in devices {
			if !k.used {
				d = &k
				break
			}
		}
		if d == nil {
			return nil
		}
		d^ = Known_Device{used = true}
		d.ilen = copy(d.id[:], id)
	}
	d.ulen = copy(d.user[:], user)
	x := libmsg.xsub(libmsg.extra(&net, "devices"), id)
	libmsg.xset(x, "user", user)
	libmsg.xset(x, "curve25519", curve_b64)
	libmsg.xset(x, "ed25519", ed_b64)
	fp: [64]u8
	libmsg.xset(x, "fingerprint", fingerprint(ed_b64, fp[:]))
	libmsg.xset(x, "verified", d.verified ? "yes" : "no")
	return d
}

device_by_id :: proc "contextless" (id: string) -> ^Known_Device {
	for &k in devices {
		if k.used && string(k.id[:k.ilen]) == id {
			return &k
		}
	}
	return nil
}

// fingerprint writes a signing key's base64 in groups of four, which is
// how the other screen shows a session key, so the eyes can compare.
fingerprint :: proc "contextless" (ed_b64: string, into: []u8) -> string {
	n := 0
	for i in 0 ..< len(ed_b64) {
		if i > 0 && i % 4 == 0 && n < len(into) {
			into[n] = ' '
			n += 1
		}
		if n >= len(into) {
			break
		}
		into[n] = ed_b64[i]
		n += 1
	}
	return string(into[:n])
}

// ask_verify is the requester for a device: the fingerprint on ctl, in
// notify/, and on the desktop's notice when there is one.
ask_verify :: proc(id: string) -> bool {
	d := device_by_id(id)
	if d == nil {
		return false
	}
	x := libmsg.xsub(libmsg.extra(&net, "devices"), id)
	fp, _ := libmsg.xget(x, "fingerprint")
	asking_len = copy(asking[:], id)
	rebuild_status()
	user := string(d.user[:d.ulen])
	m: libmsg.Msg
	m.date = libmsg.now_seconds()
	when_: [32]u8
	m.date_text = libmsg.clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(m.date, id, idbuf[:]))
	m.from = libmsg.clone(user)
	m.subject = libmsg.clone("verify")
	body := make([dynamic]u8, 0, 256)
	defer delete(body)
	libmsg.put(&body, "device ")
	libmsg.put(&body, id)
	libmsg.put(&body, "\n")
	libmsg.put(&body, fp)
	libmsg.put(&body, "\n")
	m.body = libmsg.clone(string(body[:]))
	m.type = libmsg.clone("text/plain")
	m.raw = libmsg.clone(id)
	libmsg.add(&net, libmsg.conv(&net, "notify"), m)
	// The desktop's toast, when there is a desktop: the source, the text.
	if fd := libuser.open("/mnt/wb/notice", abi.O_WRONLY); fd >= 0 {
		line: [512]u8
		text := libuser.cat_into(line[:], "matrixfs verify ", user, "'s device ", id, ": ", fp, " -- compare with the other screen, then say verified ", id, "\n")
		_ = libuser.write(int(fd), transmute([]u8)text)
		_ = libuser.close(int(fd))
	}
	return true
}

// set_verified is the person's yes for a device.
set_verified :: proc(id: string) -> bool {
	d := device_by_id(id)
	if d == nil {
		return false
	}
	d.verified = true
	libmsg.xset(libmsg.xsub(libmsg.extra(&net, "devices"), id), "verified", "yes")
	if string(asking[:asking_len]) == id {
		asking_len = 0
	}
	rebuild_status()
	return true
}

// device_subject answers what a sealed message from a device is marked
// with: nothing for one verified, else that it is not, or not known.
device_subject :: proc "contextless" (id: string) -> string {
	d := device_by_id(id)
	if d == nil {
		return "unknown device"
	}
	return d.verified ? "" : "unverified device"
}
