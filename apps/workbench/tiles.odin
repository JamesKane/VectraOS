/*
tiles -- the dock down the right edge, `docs/CHROME.md` section 12's H.

A column of tiles, each a raised square with its program's icon and an LED
in its corner. The LED is lit while a window of that program is up, which
the server's `ctl` says with an `up NAME` line per program. A click brings
that program's front window forward, `front NAME`, or runs it when none is
up. The tiles come from `/lib/wb/dock` and then `$home/lib/wb/dock`, one per
line:

    tile  rc      window rc -i
    clock
    load

`clock` is a readout of the time off `/dev/time`, hours and minutes. `load`
is a column of LEDs, lit bottom up. It shows the memory in use, off
`/dev/sysstat`, since the kernel reports no processor time yet.

The dock is a `bar right`, so the server keeps its strip clear of `zoom`,
the `snap` words and a new window's place.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

MAX_TILES :: 8
LOAD_LEDS :: 8
// The dock's width: a tile, and room either side for the clock's readout.
TILES_W :: 80

Tile :: struct {
	name: string,
	cmd:  string,
	obj:  ^libmui.Object,
}

tiles: [MAX_TILES]Tile
tile_n: int
tiles_win: ^libmui.Window
clock_obj: ^libmui.Object
clock_text: [8]u8
clock_minute: int
// Whether the dock files ask for a clock and a load column. Read once at
// start, so the backdrop knows the dock's strip before it opens.
want_clock, want_load: bool
load_leds: [LOAD_LEDS]^libmui.Object

@(private = "file")
dock_text: [2][2048]u8

/*
tiles_read reads the two dock files into `tiles`, the shipped one and then
the person's. A later `tile` of a name already there replaces its command.
It answers whether the files ask for a clock and a load column.
*/
tiles_read :: proc "contextless" () -> (clock: bool, load: bool) {
	context = wb_ctx
	tile_n = 0
	pb: [160]u8
	paths := [2]string{"/lib/wb/dock", libuser.cat_into(pb[:], home_path(), "/lib/wb/dock")}
	for path, k in paths {
		fd := libuser.open(path, abi.O_RDONLY)
		if fd < 0 {
			continue
		}
		n := libuser.read(int(fd), dock_text[k][:])
		_ = libuser.close(int(fd))
		text := string(dock_text[k][:max(int(n), 0)])
		for len(text) > 0 {
			eol := 0
			for eol < len(text) && text[eol] != '\n' {
				eol += 1
			}
			line := text[:eol]
			text = text[min(eol + 1, len(text)):]
			for c in 0 ..< len(line) {
				if line[c] == '#' {
					line = line[:c]
					break
				}
			}
			verb, rest := first_word(line)
			switch verb {
			case "clock":
				clock = true
			case "load":
				load = true
			case "tile":
				name, cmd := first_word(rest)
				if name == "" || cmd == "" {
					continue
				}
				at := tile_n
				for i in 0 ..< tile_n {
					if tiles[i].name == name {
						at = i
					}
				}
				if at == tile_n {
					if tile_n >= MAX_TILES {
						continue
					}
					tile_n += 1
				}
				tiles[at] = Tile{name = name, cmd = cmd}
			}
		}
	}
	return
}

// has_tiles answers whether the dock files name anything, so there is a dock.
has_tiles :: proc "contextless" () -> bool {
	return tile_n > 0 || want_clock || want_load
}

// open_tiles opens the dock down the right edge, below the bar, from what
// `tiles_read` found.
open_tiles :: proc "contextless" () -> bool {
	context = wb_ctx
	if !has_tiles() {
		return false
	}
	clock, load := want_clock, want_load
	col := libmui.group(false)
	for i in 0 ..< tile_n {
		t := libmui.tile(tiles[i].name, tiles[i].name)
		if t == nil {
			return false
		}
		t.id = i + 1
		tiles[i].obj = t
		libmui.add(col, t)
	}
	if clock {
		clock_obj = libmui.readout(clock_line(), 5)
		libmui.add(col, clock_obj)
	}
	if load {
		for i in 0 ..< LOAD_LEDS {
			load_leds[i] = libmui.led(libmui.LED_OFF)
			libmui.add(col, load_leds[i])
		}
	}
	libmui.add(col, libmui.space())
	tiles_win = new(libmui.Window)
	if tiles_win == nil {
		return false
	}
	w := tiles_win
	w.kind = .Bar
	w.bar_right = true
	w.bind_dev = false
	w.own_exit = false
	w.set_up = true
	w.placed = true
	w.at_x, w.at_y = screen_w - TILES_W, BAR_H
	w.want_w, w.want_h = TILES_W, screen_h - BAR_H
	w.handler = tile_press
	return libmui.window_open(w, "Dock", col)
}

// tile_press brings the tile's program forward, or runs it when none is up.
tile_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	_ = w
	i := id - 1
	if i < 0 || i >= tile_n {
		return
	}
	fd := libuser.open("/mnt/ctl", abi.O_WRONLY)
	if fd >= 0 {
		line: [96]u8
		req := libuser.cat_into(line[:], "front ", tiles[i].name)
		ok := libuser.write(int(fd), transmute([]u8)req) == i64(len(req))
		_ = libuser.close(int(fd))
		if ok {
			return
		}
	}
	run_action(tiles[i].cmd)
}

/*
tiles_thread keeps the dock's LEDs and clock true. Once a second it reads the
server's `ctl` for the programs that are up, the time and the memory. It
repaints when any of them changed.
*/
tiles_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil || tiles_win == nil {
		libthread.threadexits("")
	}
	for !tiles_win.done {
		if tiles_refresh() {
			libmui.window_paint(tiles_win)
		}
		_ = libthread.iosleep(io, 1000)
	}
	libthread.threadexits("")
}

// tiles_refresh sets each LED and the clock from what is so now, and answers
// whether anything changed.
tiles_refresh :: proc "contextless" () -> bool {
	changed := false
	report: [1024]u8
	text := ""
	if fd := libuser.open("/mnt/ctl", abi.O_RDONLY); fd >= 0 {
		n := libuser.read(int(fd), report[:])
		_ = libuser.close(int(fd))
		text = string(report[:max(int(n), 0)])
	}
	for i in 0 ..< tile_n {
		state := up_in(text, tiles[i].name) ? libmui.LED_OK : libmui.LED_OFF
		if tiles[i].obj != nil && tiles[i].obj.sel != state {
			tiles[i].obj.sel = state
			changed = true
		}
	}
	if clock_obj != nil {
		// The label is the clock's own buffer, so the minute says whether
		// it moved.
		was := clock_minute
		clock_obj.label = clock_line()
		if clock_minute != was {
			changed = true
		}
	}
	if load_leds[0] != nil {
		lit := memory_leds()
		for i in 0 ..< LOAD_LEDS {
			// Lit bottom up: the last LED is the first lit.
			state := LOAD_LEDS - i <= lit ? libmui.LED_OK : libmui.LED_OFF
			if lit >= LOAD_LEDS - 1 && state == libmui.LED_OK {
				state = libmui.LED_WARN
			}
			if load_leds[i].sel != state {
				load_leds[i].sel = state
				changed = true
			}
		}
	}
	return changed
}

// up_in answers whether the server's report has `up NAME`.
up_in :: proc "contextless" (report: string, name: string) -> bool {
	text := report
	for len(text) > 0 {
		eol := 0
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		line := text[:eol]
		text = text[min(eol + 1, len(text)):]
		if len(line) == len(name) + 3 && line[:3] == "up " && line[3:] == name {
			return true
		}
	}
	return false
}

// clock_line is the time off `/dev/time`, `HH:MM` in UTC, into a buffer the
// readout keeps. The first field is seconds since the epoch.
clock_line :: proc "contextless" () -> string {
	buf: [128]u8
	secs := 0
	if fd := libuser.open("/dev/time", abi.O_RDONLY); fd >= 0 {
		n := libuser.read(int(fd), buf[:])
		_ = libuser.close(int(fd))
		for k in 0 ..< max(int(n), 0) {
			c := buf[k]
			if c == ' ' && secs > 0 {
				break
			}
			if c >= '0' && c <= '9' {
				secs = secs * 10 + int(c - '0')
			}
		}
	}
	day := secs % 86400
	h, m := day / 3600, day % 3600 / 60
	clock_minute = day / 60
	clock_text[0] = u8('0' + h / 10)
	clock_text[1] = u8('0' + h % 10)
	clock_text[2] = ':'
	clock_text[3] = u8('0' + m / 10)
	clock_text[4] = u8('0' + m % 10)
	return string(clock_text[:5])
}

// memory_leds is how many of the load column's LEDs the memory in use lights,
// off `/dev/sysstat`'s `mem <usable> <free>`.
memory_leds :: proc "contextless" () -> int {
	buf: [128]u8
	fd := libuser.open("/dev/sysstat", abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	text := string(buf[:max(int(n), 0)])
	nums: [2]int
	got := 0
	i := 0
	for i < len(text) && got < 2 && text[i] != '\n' {
		if text[i] >= '0' && text[i] <= '9' {
			v := 0
			for i < len(text) && text[i] >= '0' && text[i] <= '9' {
				v = v * 10 + int(text[i] - '0')
				i += 1
			}
			nums[got] = v
			got += 1
			continue
		}
		i += 1
	}
	if got < 2 || nums[0] <= 0 {
		return 0
	}
	used := nums[0] - nums[1]
	return min((used * LOAD_LEDS + nums[0] - 1) / nums[0], LOAD_LEDS)
}
