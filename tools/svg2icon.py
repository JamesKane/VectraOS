#!/usr/bin/env python3
"""Convert the chrome study's SVG icons into `.icon` files, docs/CHROME.md section 6.

The study draws sixteen icons as SVG symbols in a 32 unit box: paths,
ellipses, circles, rectangles, strokes, gradients and a little text. The target
fills outlines and nothing else, with `sys/libraster.path_paint`. So this does
every other job on the host: it flattens curves and arcs, turns an ellipse or a
circle into a polygon, expands a stroke into filled quads and round joins, and
applies a transform. What comes out is a file of shapes, one a line:

    view 32 32
    shape solid #000000 alpha 97 : x,y x,y ... | x,y ...
    shape lin 0 7 0 28 0:#ffe08a 115:warn 255:#c26f00 alpha 255 : ...
    shape rad 10 9 22 0:#9ff4ff 127:#2a8fd6 255:#1c2466 alpha 255 : ...

A colour is six hex digits, a colour name, or a name mixed toward black,
`violet*55`. The names are the study's tokens, which the schemes define with
`colour` lines: `violet`, `cyan`, `amber`, `green`, `mag`, and the metal as
`metal.hi` and `metal.lo`. So a scheme repaints the icons. Points are in the view's units,
two decimals, and contours are split by `|`. A gradient's line or circle is in
the view's units too, resolved from the shape's bounding box on the host.

A text element is left out: the only one is the terminal's `rc%`, which the
icon reads as a screen without.

    python3 tools/svg2icon.py [study.html]
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "lib", "icons")
STUDY = os.path.expanduser("~/Development/c/pneo/docs/design/chrome-study.html")

# The study's symbol, and the file it becomes.
NAMES = {
    "i-folder": "folder", "i-union": "union", "i-served": "served",
    "i-file": "file", "i-ctl": "ctl", "i-scheme": "scheme", "i-srv": "srv",
    "i-home": "home", "i-remote": "remote", "i-recycle": "recycler",
    "i-viewer": "viewer", "i-prefs": "prefs", "i-term": "rc", "i-acme": "acme",
    "i-page": "page", "i-page-fx": "tool",
}

def role(token):
    """A study token as a colour name the scheme defines: `--metal-hi` is
    `metal.hi`, the rest keep their names."""
    return token.replace("-", ".")


CURVE_STEPS = 8
CIRCLE_STEPS = 24


def colour(value):
    """A colour as the icon file writes it, or None for none."""
    if value is None:
        return None
    v = value.strip()
    if v in ("none", "transparent"):
        return None
    m = re.fullmatch(r"var\(--([\w-]+)\)", v)
    if m:
        return role(m.group(1))
    m = re.fullmatch(r"color-mix\(in oklch,\s*var\(--([\w-]+)\)\s*(\d+)%,\s*black\)", v)
    if m:
        return f"{role(m.group(1))}*{m.group(2)}"
    if v.startswith("#"):
        h = v[1:]
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return "#" + h.lower()
    if v in ("white",):
        return "#ffffff"
    if v in ("black",):
        return "#000000"
    return "#ff00ff"


def attrs(tag):
    out = dict(re.findall(r'([\w:-]+)="([^"]*)"', tag))
    for decl in out.get("style", "").split(";"):
        if ":" in decl:
            k, v = decl.split(":", 1)
            out[k.strip()] = v.strip()
    return out


# -- Gradients ------------------------------------------------------------------

def gradients(html):
    grads = {}
    for m in re.finditer(r"<(linearGradient|radialGradient)([^>]*)>(.*?)</\1>", html, re.S):
        a = attrs(m.group(2))
        stops = []
        for st in re.finditer(r"<stop([^>]*)/?>", m.group(3)):
            sa = attrs(st.group(1))
            off = sa.get("offset", "0")
            off = float(off[:-1]) / 100 if off.endswith("%") else float(off)
            stops.append((off, colour(sa.get("stop-color", "#000"))))
        grads[a["id"]] = (m.group(1), a, stops)
    return grads


# -- Geometry -------------------------------------------------------------------

def arc_points(x0, y0, rx, ry, rot, large, sweep, x1, y1):
    """SVG's endpoint arc as points, after its first."""
    if rx == 0 or ry == 0:
        return [(x1, y1)]
    phi = math.radians(rot)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x0 - x1) / 2, (y0 - y1) / 2
    x1p = cp * dx + sp * dy
    y1p = -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p ** 2 / rx ** 2 + y1p ** 2 / ry ** 2
    if lam > 1:
        rx *= math.sqrt(lam)
        ry *= math.sqrt(lam)
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    co = math.sqrt(max(num / den, 0)) if den else 0
    if large == sweep:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x0 + x1) / 2
    cy = sp * cxp + cp * cyp + (y0 + y1) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(4, int(abs(dt) / (math.pi / 8)))
    pts = []
    for i in range(1, n + 1):
        t = t1 + dt * i / n
        x = cx + rx * math.cos(t) * cp - ry * math.sin(t) * sp
        y = cy + rx * math.cos(t) * sp + ry * math.sin(t) * cp
        pts.append((x, y))
    return pts


def path_contours(d):
    """An SVG path's contours, each a list of points, and which were closed."""
    tokens = re.findall(r"[MmLlHhVvCcSsQqAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?", d)
    contours, closed = [], []
    cur, start = (0.0, 0.0), (0.0, 0.0)
    pts = []
    i, cmd = 0, None

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    def flag():
        # Arc flags may run together with no separator: `0 1` or `01`.
        nonlocal i
        t = tokens[i]
        i += 1
        return int(float(t))

    while i < len(tokens):
        t = tokens[i]
        if re.fullmatch(r"[A-Za-z]", t):
            cmd = t
            i += 1
            if cmd in "Zz":
                if pts:
                    contours.append(pts)
                    closed.append(True)
                pts = []
                cur = start
                continue
        rel = cmd.islower()
        c = cmd.upper()
        if c == "M":
            x, y = num(), num()
            if rel:
                x, y = cur[0] + x, cur[1] + y
            if pts:
                contours.append(pts)
                closed.append(False)
            pts = [(x, y)]
            cur = start = (x, y)
            cmd = "l" if rel else "L"
        elif c == "L":
            x, y = num(), num()
            if rel:
                x, y = cur[0] + x, cur[1] + y
            pts.append((x, y))
            cur = (x, y)
        elif c == "H":
            x = num()
            x = cur[0] + x if rel else x
            pts.append((x, cur[1]))
            cur = (x, cur[1])
        elif c == "V":
            y = num()
            y = cur[1] + y if rel else y
            pts.append((cur[0], y))
            cur = (cur[0], y)
        elif c == "C":
            x1, y1, x2, y2, x, y = num(), num(), num(), num(), num(), num()
            if rel:
                x1, y1, x2, y2, x, y = (cur[0] + x1, cur[1] + y1, cur[0] + x2,
                                        cur[1] + y2, cur[0] + x, cur[1] + y)
            for k in range(1, CURVE_STEPS + 1):
                s = k / CURVE_STEPS
                u = 1 - s
                pts.append((u ** 3 * cur[0] + 3 * u * u * s * x1 + 3 * u * s * s * x2 + s ** 3 * x,
                            u ** 3 * cur[1] + 3 * u * u * s * y1 + 3 * u * s * s * y2 + s ** 3 * y))
            cur = (x, y)
        elif c == "A":
            rx, ry, rot = num(), num(), num()
            large, sweep = flag(), flag()
            x, y = num(), num()
            if rel:
                x, y = cur[0] + x, cur[1] + y
            pts.extend(arc_points(cur[0], cur[1], rx, ry, rot, large, sweep, x, y))
            cur = (x, y)
        else:
            raise ValueError("path command " + cmd)
    if pts:
        contours.append(pts)
        closed.append(False)
    return contours, closed


def ellipse(cx, cy, rx, ry):
    return [(cx + rx * math.cos(2 * math.pi * k / CIRCLE_STEPS),
             cy + ry * math.sin(2 * math.pi * k / CIRCLE_STEPS)) for k in range(CIRCLE_STEPS)]


def area(pts):
    return sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1]
               for i in range(len(pts))) / 2


def ccw(pts):
    return pts if area(pts) >= 0 else list(reversed(pts))


def stroke(contour, closed, width):
    """A stroke as filled polygons: a quad per segment and a disc per joint,
    each wound the same way, so nonzero filling takes their union."""
    w = width / 2
    out = []
    n = len(contour)
    segs = range(n if closed else n - 1)
    for k in segs:
        (x0, y0), (x1, y1) = contour[k], contour[(k + 1) % n]
        dx, dy = x1 - x0, y1 - y0
        ln = math.hypot(dx, dy)
        if ln == 0:
            continue
        nx, ny = -dy / ln * w, dx / ln * w
        out.append(ccw([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)]))
    if w >= 0.4:
        for (x, y) in contour:
            out.append(ccw([(x + w * math.cos(2 * math.pi * k / 8), y + w * math.sin(2 * math.pi * k / 8)) for k in range(8)]))
    return out


def transform(tf):
    """A transform list as a function of a point: translate and skewY."""
    fs = []
    for name, args in re.findall(r"(\w+)\(([^)]*)\)", tf or ""):
        a = [float(v) for v in re.split(r"[\s,]+", args.strip()) if v]
        if name == "translate":
            tx, ty = a[0], a[1] if len(a) > 1 else 0
            fs.append(lambda p, tx=tx, ty=ty: (p[0] + tx, p[1] + ty))
        elif name == "skewY":
            k = math.tan(math.radians(a[0]))
            fs.append(lambda p, k=k: (p[0], p[1] + k * p[0]))
    def apply(p):
        for f in reversed(fs):
            p = f(p)
        return p
    return apply


# -- Paint ----------------------------------------------------------------------

def paint(fill, grads, bbox):
    m = re.fullmatch(r"url\(#([\w-]+)\)", fill or "")
    if not m:
        c = colour(fill)
        return None if c is None else f"solid {c}"
    kind, a, stops = grads[m.group(1)]
    x0, y0, x1, y1 = bbox
    w, h = x1 - x0, y1 - y0
    sl = " ".join(f"{int(round(off * 255))}:{c}" for off, c in stops)
    if kind == "linearGradient":
        gx1 = x0 + float(a.get("x1", "0")) * w
        gy1 = y0 + float(a.get("y1", "0")) * h
        gx2 = x0 + float(a.get("x2", "1")) * w
        gy2 = y0 + float(a.get("y2", "0")) * h
        return f"lin {gx1:.2f} {gy1:.2f} {gx2:.2f} {gy2:.2f} {sl}"
    cx = x0 + float(a.get("cx", ".5")) * w
    cy = y0 + float(a.get("cy", ".5")) * h
    r = float(a.get("r", ".5")) * max(w, h)
    return f"rad {cx:.2f} {cy:.2f} {r:.2f} {sl}"


def bbox_of(contours):
    xs = [p[0] for c in contours for p in c]
    ys = [p[1] for c in contours for p in c]
    return min(xs), min(ys), max(xs), max(ys)


def fmt(contours):
    return " | ".join(" ".join(f"{x:.2f},{y:.2f}" for x, y in c) for c in contours)


def element_contours(tag, a, apply):
    if tag == "path":
        cs, closed = path_contours(a["d"])
    elif tag == "ellipse":
        cs, closed = [ellipse(float(a["cx"]), float(a["cy"]), float(a["rx"]), float(a["ry"]))], [True]
    elif tag == "circle":
        r = float(a["r"])
        cs, closed = [ellipse(float(a["cx"]), float(a["cy"]), r, r)], [True]
    elif tag == "rect":
        x, y, w, h = float(a.get("x", 0)), float(a.get("y", 0)), float(a["width"]), float(a["height"])
        cs, closed = [[(x, y), (x + w, y), (x + w, y + h), (x, y + h)]], [True]
    else:
        return [], []
    return [[apply(p) for p in c] for c in cs], closed


def convert(body, grads):
    lines = []
    # Groups: a transform and an opacity that every element inside takes.
    stack = [(transform(""), 1.0)]
    for m in re.finditer(r"<(/?)(\w+)([^>]*?)(/?)>", body):
        close, tag, rest, selfclose = m.groups()
        if tag == "g":
            if close:
                stack.pop()
            else:
                a = attrs(rest)
                outer_f, outer_o = stack[-1]
                inner = transform(a.get("transform"))
                stack.append((lambda p, i=inner, o=outer_f: o(i(p)), outer_o * float(a.get("opacity", 1))))
            continue
        if close or tag == "text":
            continue
        a = attrs(rest)
        apply, group_o = stack[-1]
        cs, closed = element_contours(tag, a, apply)
        if not cs:
            continue
        op = float(a.get("opacity", 1)) * group_o
        fill = a.get("fill", "#000" if tag != "path" or "fill" not in a else a.get("fill"))
        if tag == "path" and "fill" not in a:
            fill = "#000"
        p = paint(fill, grads, bbox_of(cs))
        if p is not None:
            fo = op * float(a.get("fill-opacity", 1))
            lines.append(f"shape {p} alpha {int(round(fo * 255))} : {fmt([c for c in cs if len(c) >= 3])}")
        sc = colour(a.get("stroke"))
        if sc is not None:
            sw = float(a.get("stroke-width", 1))
            so = op * float(a.get("stroke-opacity", 1))
            polys = []
            for c, cl in zip(cs, closed):
                polys.extend(stroke(c, cl or tag != "path", sw))
            if polys:
                lines.append(f"shape solid {sc} alpha {int(round(so * 255))} : {fmt(polys)}")
    return lines


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else STUDY
    html = open(src).read()
    grads = gradients(html)
    os.makedirs(OUT, exist_ok=True)
    for sym in re.finditer(r'<symbol[^>]*id="(i-[^"]+)"([^>]*)>(.*?)</symbol>', html, re.S):
        name = NAMES.get(sym.group(1))
        if name is None:
            continue
        vb = re.search(r'viewBox="([^"]+)"', sym.group(2))
        vw, vh = (float(v) for v in vb.group(1).split()[2:4]) if vb else (32.0, 32.0)
        lines = convert(sym.group(3), grads)
        with open(os.path.join(OUT, name + ".icon"), "w") as f:
            f.write(f"# {name}: from the chrome study's {sym.group(1)}, by tools/svg2icon.py\n")
            f.write(f"view {vw:g} {vh:g}\n")
            for ln in lines:
                f.write(ln + "\n")
        print(f"{name}.icon  {len(lines)} shapes  {os.path.getsize(os.path.join(OUT, name + '.icon'))} bytes")


if __name__ == "__main__":
    main()
