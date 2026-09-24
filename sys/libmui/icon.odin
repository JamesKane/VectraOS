/*
icon -- a picture drawn from outlines, `docs/CHROME.md` section 6.

An icon is a file of filled shapes in a square view, which
`tools/svg2icon.py` writes from the chrome study's drawings. Each line is one
shape: its paint, an alpha, and its contours as points in the view's units.

    view 32 32
    shape solid #000000 alpha 97 : 28.50,28.60 28.11,29.14 ... | ...
    shape lin 4.50 7.00 4.50 27.00 0:#e3a32a 255:amber alpha 255 : ...
    shape rad 10 9 22 0:#9ff4ff 255:#1c2466 alpha 255 : ...

A colour is `#` and six hex digits, or a name the theme defines with a
`colour` line, which is how a scheme repaints the icons. `name*55` is that
colour at 55 parts in 100, toward black. The outlines are filled with
`sys/libraster.path_paint` at any size, so one file is every size an icon is
drawn at.

The theme's `icons` role names the directory the files are in. A theme that
names none keeps the chassis's pictures, `draw.odin`'s `icon_picture`. So a
program never has to ask which it is: a missing file is the chassis picture
too.
*/
package libmui

import "vsys:libpal"
import "vsys:libraster"
import "vsys:libuser"

ICON_FILE_MAX :: 24 * 1024
MAX_ICON_SHAPES :: 24
// The largest an icon is drawn, in pixels, and the most points one shape
// holds. `tools/svg2icon.py` writes none larger.
ICON_MAX_SIZE :: 128
ICON_SHAPE_POINTS :: 1024

// How big an icon grid draws its pictures, in pixels square.
ICON_PICTURE :: 36

@(private = "file")
Icon_Shape :: struct {
	kind:    libraster.Paint_Kind,
	colours: [libraster.MAX_STOPS]string,
	at:      [libraster.MAX_STOPS]u32,
	n:       int,
	// A gradient's line or centre and radius, in hundredths of a unit.
	a, b:    libraster.Point,
	r:       int,
	alpha:   u32,
	// Its points in the icon's `pts`, and its contours' ends in `ends`,
	// counted from its first point.
	p0, p1:  int,
	e0, e1:  int,
}

@(private = "file")
Icon :: struct {
	view:   int, // The view's width, in hundredths of a unit
	text:   []u8,
	pts:    []libraster.Point, // In hundredths of a unit
	ends:   []int,
	shapes: [MAX_ICON_SHAPES]Icon_Shape,
	count:  int,
}

/*
The icons a program asks for, by the hash of their paths. An entry
remembers a path with no file as well as one with. So a grid of tools with no
icons of their own opens each missing file once. The icons are on the heap
for the program's life: a program draws few.
*/
ICON_TABLE :: 256

@(private = "file")
Icon_Entry :: struct {
	hash: u64,
	used: bool,
	icon: ^Icon,
}

@(private = "file")
icon_table: [ICON_TABLE]Icon_Entry

@(private = "file")
icon_home_buf: [128]u8

@(private = "file")
icon_home_n: int

/*
icon_of is the icon named `name`, read on first use. A person's
`$home/lib/icons` is read first, so a file there replaces the scheme's. Then
the directory the theme's `icons` line names. It is nil when the theme names
no directory, or no file reads and parses. The caller then draws the next
picture it has.
*/
@(private = "file")
icon_of :: proc "contextless" (t: ^Theme, name: string) -> ^Icon #no_bounds_check {
	if t.icons_n == 0 || name == "" {
		return nil
	}
	if icon_home_n == 0 {
		icon_home_n = len(libuser.cat_into(icon_home_buf[:], theme_home(), "/lib/icons"))
	}
	pb: [FACE_PATH + 64]u8
	if ic := icon_at(libuser.cat_into(pb[:], string(icon_home_buf[:icon_home_n]), "/", name, ".icon")); ic != nil {
		return ic
	}
	return icon_at(libuser.cat_into(pb[:], string(t.icons[:t.icons_n]), "/", name, ".icon"))
}

// icon_at is the icon in one file, from the table or read now.
@(private = "file")
icon_at :: proc "contextless" (path: string) -> ^Icon #no_bounds_check {
	h := u64(0xcbf29ce484222325)
	for k in 0 ..< len(path) {
		h = (h ~ u64(path[k])) * 0x100000001b3
	}
	for probe in 0 ..< ICON_TABLE {
		e := &icon_table[(int(h % ICON_TABLE) + probe) % ICON_TABLE]
		if e.used && e.hash == h {
			return e.icon
		}
		if !e.used {
			e.used = true
			e.hash = h
			e.icon = icon_load(path)
			return e.icon
		}
	}
	return nil
}

// icon_load reads and parses one file onto the heap, or answers nil. A file
// that reads and will not parse keeps its memory, which is small and rare.
@(private = "file")
icon_load :: proc "contextless" (path: string) -> ^Icon #no_bounds_check {
	scratch := libuser.heap_alloc(ICON_FILE_MAX)
	if scratch == nil {
		return nil
	}
	defer libuser.heap_free(scratch)
	got := text_read(nil, path, ([^]u8)(scratch)[:ICON_FILE_MAX])
	if got <= 0 || got >= ICON_FILE_MAX {
		return nil
	}
	keep := libuser.heap_alloc(got)
	mem := libuser.heap_alloc(size_of(Icon))
	if keep == nil || mem == nil {
		return nil
	}
	ic := (^Icon)(mem)
	ic^ = {}
	ic.text = ([^]u8)(keep)[:got]
	copy(ic.text, ([^]u8)(scratch)[:got])
	return icon_parse(ic) ? ic : nil
}

/*
icon_parse reads an icon's text: a count of its points and contours first, so
the two arrays are sized once, then the lines. A line it cannot read, or a
shape past the most it holds, fails the icon, and the chassis picture stands
in for it.
*/
@(private = "file")
icon_parse :: proc "contextless" (ic: ^Icon) -> bool #no_bounds_check {
	text := string(ic.text)
	npts, nends := 0, 0
	for k in 0 ..< len(text) {
		switch text[k] {
		case ',':
			npts += 1
		case '|', ':':
			nends += 1
		}
	}
	// A stop's `at:colour` counts as a contour too, which only oversizes.
	pts := libuser.heap_alloc(max(npts, 1) * size_of(libraster.Point))
	ends := libuser.heap_alloc(max(nends, 1) * size_of(int))
	if pts == nil || ends == nil {
		return false
	}
	ic.pts = ([^]libraster.Point)(pts)[:npts]
	ic.ends = ([^]int)(ends)[:nends]
	np, ne := 0, 0
	i := 0
	for i < len(text) {
		start := i
		for i < len(text) && text[i] != '\n' {
			i += 1
		}
		line := text[start:i]
		if i < len(text) {
			i += 1
		}
		kw, rest := word(line)
		switch kw {
		case "view":
			v, _ := word(rest)
			ic.view = hundredths(v)
		case "shape":
			if ic.count >= MAX_ICON_SHAPES {
				return false
			}
			sh := &ic.shapes[ic.count]
			if !shape_parse(sh, rest) {
				return false
			}
			// The points, after the colon that stands alone. A stop's colon
			// is inside its word.
			at := 0
			for at + 2 < len(rest) && rest[at:at + 3] != " : " {
				at += 1
			}
			at += 2
			sh.p0 = np
			sh.e0 = ne
			body := rest[min(at + 1, len(rest)):]
			for {
				w: string
				w, body = word(body)
				if w == "" {
					break
				}
				if w == "|" {
					if np > sh.p0 && (ne == sh.e0 || ic.ends[ne - 1] != np - sh.p0) {
						ic.ends[ne] = np - sh.p0
						ne += 1
					}
					continue
				}
				comma := 0
				for comma < len(w) && w[comma] != ',' {
					comma += 1
				}
				if comma >= len(w) || np >= len(ic.pts) {
					return false
				}
				ic.pts[np] = libraster.Point{hundredths(w[:comma]), hundredths(w[comma + 1:])}
				np += 1
			}
			if np > sh.p0 && (ne == sh.e0 || ic.ends[ne - 1] != np - sh.p0) {
				ic.ends[ne] = np - sh.p0
				ne += 1
			}
			sh.p1 = np
			sh.e1 = ne
			if sh.p1 - sh.p0 > ICON_SHAPE_POINTS {
				return false
			}
			ic.count += 1
		}
	}
	return ic.view > 0 && ic.count > 0
}

// shape_parse reads a shape's paint and alpha, the words before its colon.
@(private = "file")
shape_parse :: proc "contextless" (sh: ^Icon_Shape, s: string) -> bool #no_bounds_check {
	kind, rest := word(s)
	nums: [5]int
	want := 0
	switch kind {
	case "solid":
		sh.kind = .Solid
	case "lin":
		sh.kind = .Linear
		want = 4
	case "rad":
		sh.kind = .Radial
		want = 3
	case:
		return false
	}
	for k in 0 ..< want {
		w: string
		w, rest = word(rest)
		nums[k] = hundredths(w)
	}
	sh.a = libraster.Point{nums[0], nums[1]}
	if sh.kind == .Linear {
		sh.b = libraster.Point{nums[2], nums[3]}
	} else {
		sh.r = nums[2]
	}
	sh.alpha = 255
	for {
		w: string
		w, rest = word(rest)
		if w == "" || w == ":" {
			break
		}
		if w == "alpha" {
			v: string
			v, rest = word(rest)
			sh.alpha = u32(min(hundredths(v) / 100, 255))
			continue
		}
		if sh.kind == .Solid {
			sh.colours[0] = w
			sh.n = 1
			continue
		}
		// A stop, `at:colour`.
		colon := 0
		for colon < len(w) && w[colon] != ':' {
			colon += 1
		}
		if colon >= len(w) || sh.n >= libraster.MAX_STOPS {
			continue
		}
		sh.at[sh.n] = u32(min(hundredths(w[:colon]) / 100, 255))
		sh.colours[sh.n] = w[colon + 1:]
		sh.n += 1
	}
	return sh.n > 0
}

// hundredths reads a decimal, `-12.5`, as a whole number of hundredths.
@(private = "file")
hundredths :: proc "contextless" (s: string) -> int {
	neg := false
	i := 0
	if i < len(s) && s[i] == '-' {
		neg = true
		i += 1
	}
	v := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + int(s[i] - '0')
		i += 1
	}
	v *= 100
	if i < len(s) && s[i] == '.' {
		i += 1
		scale := 10
		for i < len(s) && s[i] >= '0' && s[i] <= '9' && scale > 0 {
			v += int(s[i] - '0') * scale
			scale /= 10
			i += 1
		}
	}
	return neg ? -v : v
}

// icon_colour is a colour an icon names: `#` and hex, a theme colour, or one
// at some parts in 100 toward black. A name the theme lacks is its ink.
@(private = "file")
icon_colour :: proc "contextless" (s: string, t: ^Theme) -> u32 {
	name := s
	part := 100
	for k in 0 ..< len(s) {
		if s[k] == '*' {
			name = s[:k]
			part = hundredths(s[k + 1:]) / 100
			break
		}
	}
	if len(name) > 0 && name[0] == '#' {
		name = name[1:]
	}
	c, ok := theme_colour(name)
	if !ok {
		c = t.ink
	}
	if part < 100 {
		c = libpal.mix(libpal.RGB{}, c, u8(clamp(part * 255 / 100, 0, 255)))
	}
	return libraster.rgb(c)
}

/*
icon_draw draws `ic` into a square `size` pixels across at `(x, y)` of `c`,
cut at the canvas's edges.
*/
@(private = "file")
icon_draw :: proc "contextless" (c: ^libraster.Canvas, ic: ^Icon, x: int, y: int, size: int, t: ^Theme) #no_bounds_check {
	@(static) scaled: [ICON_SHAPE_POINTS]libraster.Point
	@(static) scratch: [ICON_MAX_SIZE]u32
	side := min(size, ICON_MAX_SIZE)
	if x < 0 || y < 0 || x + side > c.w || y + side > c.h {
		return
	}
	sub := libraster.canvas(c.pix[y * c.stride + x:], c.stride, side, side)
	// A point in hundredths of a unit to sixteenths of a pixel.
	to := proc "contextless" (v: int, px_across: int, view: int) -> int {
		return v * px_across * libraster.SUB / view
	}
	for k in 0 ..< ic.count {
		sh := &ic.shapes[k]
		n := sh.p1 - sh.p0
		for j in 0 ..< n {
			p := ic.pts[sh.p0 + j]
			scaled[j] = libraster.Point{to(p.x, side, ic.view), to(p.y, side, ic.view)}
		}
		paint := libraster.Paint{kind = sh.kind, alpha = sh.alpha}
		paint.color = icon_colour(sh.colours[0], t)
		if sh.kind != .Solid {
			paint.n = sh.n
			for s in 0 ..< sh.n {
				paint.stops[s] = libraster.Stop{sh.at[s], icon_colour(sh.colours[s], t)}
			}
			paint.a = libraster.Point{to(sh.a.x, side, ic.view), to(sh.a.y, side, ic.view)}
			paint.b = libraster.Point{to(sh.b.x, side, ic.view), to(sh.b.y, side, ic.view)}
			paint.r = to(sh.r, side, ic.view)
		}
		libraster.path_paint(&sub, scaled[:n], ic.ends[sh.e0:sh.e1], &paint, scratch[:])
	}
}

/*
icon_named draws the icon a theme names `name` at `(x, y)`, `size` pixels
square. False when the theme names no icons or the file will not read, and
the caller draws its own picture.
*/
icon_named :: proc "contextless" (c: ^libraster.Canvas, name: string, x: int, y: int, size: int, t: ^Theme) -> bool {
	ic := icon_of(t, name)
	if ic == nil {
		return false
	}
	icon_draw(c, ic, x, y, size, t)
	return true
}

// icon_kind_name is the icon a grid cell of a kind shows. A drawer is a
// folder, a tool a page with a mark, and a project a page.
icon_kind_name :: proc "contextless" (kind: u8) -> string {
	switch kind {
	case ICON_DRAWER:
		return "folder"
	case ICON_TOOL:
		return "tool"
	}
	return "file"
}
