/*
snapshot -- an icon's position, kept across sessions, `docs/WORKBENCH.md`
step 5. A drag places an icon freely (`libmui`'s `place`); Snapshot writes the
placed positions to `$home/lib/wb/snapshot`, and a window loads them when it
opens, so the desktop a person arranged comes back. Clean Up drops the
placement and the grid lays the icons out again; a Snapshot after that forgets
them.

The file is one text line per placed icon: `key<tab>name<tab>x<tab>y`. The key
is a drawer's path, or `backdrop` for the desktop -- a real path starts with a
slash, so the two never collide. A save merges: it keeps every line that is
not the key's and writes the key's afresh, so one window's Snapshot leaves the
others' alone. The positions are offsets in the icon well, not pixels on the
glass, so they hold when a window opens at a different size.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

SNAP_MAX :: 4096
BACKDROP_KEY :: "backdrop"

@(private = "file") snap_path_buf: [256]u8

// snapshot_path is `$home/lib/wb/snapshot`.
snapshot_path :: proc "contextless" () -> string {
	n := copy(snap_path_buf[:], home_path())
	n += copy(snap_path_buf[n:], "/lib/wb/snapshot")
	return string(snap_path_buf[:n])
}

/*
snapshot_save writes `grid`'s placed positions under `key`, merged into the one
file so the other windows' lines are kept. Nothing placed writes nothing for
the key, which is how Clean Up then Snapshot forgets an arrangement.
*/
snapshot_save :: proc "contextless" (key: string, grid: ^libmui.Object, names: []string) #no_bounds_check {
	context = wb_ctx
	old: [SNAP_MAX]u8
	on := 0
	if fd := libuser.open(snapshot_path(), abi.O_RDONLY); fd >= 0 {
		on = int(max(libuser.read(int(fd), old[:]), 0))
		_ = libuser.close(int(fd))
	}
	out: [SNAP_MAX]u8
	w := 0
	// Keep every line that is not this key's.
	i := 0
	for i < on {
		e := i
		for e < on && old[e] != '\n' {e += 1}
		if e < on {e += 1} // take the newline with the line
		if !snap_line_is(old[i:e], key) && w + (e - i) <= SNAP_MAX {
			w += copy(out[w:], old[i:e])
		}
		i = e
	}
	// Write this key's placed lines afresh.
	if grid != nil && grid.place != nil {
		m := min(len(names), len(grid.place))
		for c in 0 ..< m {
			if w + 300 > SNAP_MAX {
				break
			}
			w += snap_put(out[w:], key, names[c], grid.place[c][0], grid.place[c][1])
		}
	}
	snap_mkdirs()
	_ = libuser.remove(snapshot_path())
	if fd := libuser.create(snapshot_path(), abi.O_WRONLY, 0o644); fd >= 0 {
		_ = libuser.write(int(fd), out[:w])
		_ = libuser.close(int(fd))
	}
}

// snapshot_load applies the saved positions for `key` to `grid`, matching each
// saved name to its cell. A name no longer in the window is skipped.
snapshot_load :: proc "contextless" (key: string, grid: ^libmui.Object, names: []string) #no_bounds_check {
	context = wb_ctx
	buf: [SNAP_MAX]u8
	n := 0
	if fd := libuser.open(snapshot_path(), abi.O_RDONLY); fd >= 0 {
		n = int(max(libuser.read(int(fd), buf[:]), 0))
		_ = libuser.close(int(fd))
	}
	i := 0
	for i < n {
		e := i
		for e < n && buf[e] != '\n' {e += 1}
		lk, nm, x, y, ok := snap_parse(buf[i:e])
		i = e + 1
		if !ok || lk != key {
			continue
		}
		for c in 0 ..< len(names) {
			if names[c] == nm {
				t := libmui.default_theme
				libmui.icons_set(grid, c, x, y, &t)
				break
			}
		}
	}
}

// snap_line_is reports whether a line (newline and all) is `key`'s: the key,
// then a tab.
@(private = "file")
snap_line_is :: proc "contextless" (line: []u8, key: string) -> bool {
	return len(line) > len(key) && string(line[:len(key)]) == key && line[len(key)] == '\t'
}

// snap_put writes one `key<tab>name<tab>x<tab>y` line, and answers its length.
@(private = "file")
snap_put :: proc "contextless" (out: []u8, key: string, name: string, x: int, y: int) -> int #no_bounds_check {
	w := copy(out, key)
	out[w] = '\t';w += 1
	w += copy(out[w:], name)
	out[w] = '\t';w += 1
	tmp: [16]u8
	w += copy(out[w:], libuser.itoa(tmp[:], i64(x)))
	out[w] = '\t';w += 1
	w += copy(out[w:], libuser.itoa(tmp[:], i64(y)))
	out[w] = '\n';w += 1
	return w
}

// snap_parse splits one line into its four fields. False if it has not three
// tabs and two numbers.
@(private = "file")
snap_parse :: proc "contextless" (line: []u8) -> (key: string, name: string, x: int, y: int, ok: bool) #no_bounds_check {
	t0, t1, t2 := -1, -1, -1
	for i in 0 ..< len(line) {
		if line[i] == '\t' {
			if t0 < 0 {t0 = i} else if t1 < 0 {t1 = i} else if t2 < 0 {t2 = i}
		}
	}
	if t0 < 0 || t1 < 0 || t2 < 0 || t2 <= t1 || t1 <= t0 {
		return "", "", 0, 0, false
	}
	xv, xok := snap_int(line[t1 + 1:t2])
	yv, yok := snap_int(line[t2 + 1:])
	if !xok || !yok {
		return "", "", 0, 0, false
	}
	return string(line[:t0]), string(line[t0 + 1:t1]), xv, yv, true
}

// snap_int reads a non-negative integer. False on no digit or a stray byte.
@(private = "file")
snap_int :: proc "contextless" (s: []u8) -> (int, bool) #no_bounds_check {
	if len(s) == 0 {
		return 0, false
	}
	v := 0
	for c in s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + int(c - '0')
	}
	return v, true
}

// snap_mkdirs makes `$home/lib` and `$home/lib/wb`, so the file has somewhere
// to land. An existing directory is left alone.
@(private = "file")
snap_mkdirs :: proc "contextless" () #no_bounds_check {
	b: [256]u8
	n := copy(b[:], home_path())
	n += copy(b[n:], "/lib")
	_ = libuser.mkdir(string(b[:n]))
	n += copy(b[n:], "/wb")
	_ = libuser.mkdir(string(b[:n]))
}
