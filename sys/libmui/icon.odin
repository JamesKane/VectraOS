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
MAX_ICONS :: 24
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
	path:   [FACE_PATH + 32]u8,
	n:      int,
	ready:  bool,
	view:   int, // The view's width, in hundredths of a unit
	text:   []u8,
	pts:    []libraster.Point, // In hundredths of a unit
	ends:   []int,
	shapes: [MAX_ICON_SHAPES]Icon_Shape,
	count:  int,
}

@(private = "file")
icons_loaded: [MAX_ICONS]Icon

@(private = "file")
icons_n: int

/*
icon_of is the icon a theme names `name`, read from its `icons` directory on
first use. It is nil when the theme names no directory, or the file will not
read or parse. The caller then draws the chassis picture in its place.
*/
@(private = "file")
icon_of :: proc "contextless" (t: ^Theme, name: string) -> ^Icon #no_bounds_check {
	if t.icons_n == 0 {
		return nil
	}
	pb: [FACE_PATH + 32]u8
	path := libuser.cat_into(pb[:], string(t.icons[:t.icons_n]), "/")
	w := len(path)
	w += copy(pb[w:], name)
	w += copy(pb[w:], ".icon")
	path = string(pb[:w])
	for i in 0 ..< icons_n {
		if string(icons_loaded[i].path[:icons_loaded[i].n]) == path {
			return icons_loaded[i].ready ? &icons_loaded[i] : nil
		}
	}
	if icons_n >= MAX_ICONS {
		return nil
	}
	ic := &icons_loaded[icons_n]
	icons_n += 1
	ic.n = copy(ic.path[:], path)
	scratch := libuser.heap_alloc(ICON_FILE_MAX)
	if scratch == nil {
		return nil
	}
	got := text_read(nil, path, ([^]u8)(scratch)[:ICON_FILE_MAX])
	if got <= 0 || got >= ICON_FILE_MAX {
		libuser.heap_free(scratch)
		return nil
	}
	keep := libuser.heap_alloc(got)
	if keep == nil {
		libuser.heap_free(scratch)
		return nil
	}
	ic.text = ([^]u8)(keep)[:got]
	copy(ic.text, ([^]u8)(scratch)[:got])
	libuser.heap_free(scratch)
	ic.ready = icon_parse(ic)
	return ic.ready ? ic : nil
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
