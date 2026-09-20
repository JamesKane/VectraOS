/*
Dates, for every network that writes one: RFC 3339 (`2026-09-18T10:20:30Z`,
an offset, a fraction) as Atom and the social networks write it, and RFC
822 (`Thu, 18 Sep 2026 10:20:30 GMT`, a numeric zone, the North American
zone names, a two-digit year) as RSS and mail write it. Both to seconds
since the epoch, in UTC, and back again through `calendar`.
*/
package libmsg

/*
parse_date reads RFC 3339 (`2026-09-18T10:20:30Z`, `+02:00`, a fraction)
and RFC 822 (`Thu, 18 Sep 2026 10:20:30 GMT`, `+0200`, the North
American zone names) to seconds since the epoch. False for anything else.
*/
parse_date :: proc "contextless" (text: string) -> (secs: i64, ok: bool) #no_bounds_check {
	s := trim_space(text)
	if len(s) >= 10 && s[4] == '-' && s[7] == '-' {
		return parse_3339(s)
	}
	return parse_822(s)
}

@(private = "file")
parse_3339 :: proc "contextless" (s: string) -> (secs: i64, ok: bool) #no_bounds_check {
	y, i1 := digits(s, 0, 4)
	mo, i2 := digits(s, i1 + 1, 2)
	d, i3 := digits(s, i2 + 1, 2)
	if i1 < 0 || i2 < 0 || i3 < 0 {
		return 0, false
	}
	h, mi, sec := 0, 0, 0
	i := i3
	if i < len(s) && (s[i] == 'T' || s[i] == 't' || s[i] == ' ') {
		i4 := 0
		h, i4 = digits(s, i + 1, 2)
		if i4 < 0 {
			return 0, false
		}
		mi, i4 = digits(s, i4 + 1, 2)
		if i4 < 0 {
			return 0, false
		}
		i = i4
		if i < len(s) && s[i] == ':' {
			sec, i = digits(s, i + 1, 2)
			if i < 0 {
				return 0, false
			}
		}
		if i < len(s) && s[i] == '.' {
			i += 1
			for i < len(s) && s[i] >= '0' && s[i] <= '9' {
				i += 1
			}
		}
	}
	offset := 0
	if i < len(s) {
		switch s[i] {
		case 'Z', 'z':
		case '+', '-':
			oh, j := digits(s, i + 1, 2)
			om := 0
			if j > 0 && j < len(s) && s[j] == ':' {
				om, j = digits(s, j + 1, 2)
			} else if j > 0 {
				om, j = digits(s, j, 2)
			}
			if j < 0 {
				return 0, false
			}
			offset = oh * 3600 + om * 60
			if s[i] == '-' {
				offset = -offset
			}
		}
	}
	return civil(y, mo, d, h, mi, sec) - i64(offset), true
}

@(private = "file")
parse_822 :: proc "contextless" (s: string) -> (secs: i64, ok: bool) #no_bounds_check {
	i := 0
	// An optional day name and its comma.
	for i < len(s) && s[i] != ',' && !(s[i] >= '0' && s[i] <= '9') {
		i += 1
	}
	if i < len(s) && s[i] == ',' {
		i += 1
	}
	i = skip_space(s, i)
	d, j := number(s, i)
	if j < 0 {
		return 0, false
	}
	i = skip_space(s, j)
	mo := 0
	if i + 3 <= len(s) {
		mo = month_of(s[i:i + 3])
	}
	if mo == 0 {
		return 0, false
	}
	i = skip_space(s, i + 3)
	y := 0
	y, j = number(s, i)
	if j < 0 {
		return 0, false
	}
	if y < 100 {
		y += y < 50 ? 2000 : 1900
	}
	i = skip_space(s, j)
	h, mi, sec := 0, 0, 0
	h, j = number(s, i)
	if j < 0 || j >= len(s) || s[j] != ':' {
		return 0, false
	}
	mi, j = number(s, j + 1)
	if j < 0 {
		return 0, false
	}
	if j < len(s) && s[j] == ':' {
		sec, j = number(s, j + 1)
		if j < 0 {
			return 0, false
		}
	}
	i = skip_space(s, j)
	offset := 0
	if i < len(s) {
		switch s[i] {
		case '+', '-':
			v, k := number(s, i + 1)
			if k < 0 {
				return 0, false
			}
			offset = (v / 100) * 3600 + (v % 100) * 60
			if s[i] == '-' {
				offset = -offset
			}
		case:
			e := i
			for e < len(s) && is_alpha(s[e]) {
				e += 1
			}
			switch s[i:e] {
			case "GMT", "UT", "UTC", "Z":
			case "EST":
				offset = -5 * 3600
			case "EDT":
				offset = -4 * 3600
			case "CST":
				offset = -6 * 3600
			case "CDT":
				offset = -5 * 3600
			case "MST":
				offset = -7 * 3600
			case "MDT":
				offset = -6 * 3600
			case "PST":
				offset = -8 * 3600
			case "PDT":
				offset = -7 * 3600
			}
		}
	}
	return civil(y, mo, d, h, mi, sec) - i64(offset), true
}

// civil is the seconds since the epoch of a proleptic Gregorian date,
// Howard Hinnant's days-from-civil.
civil :: proc "contextless" (y, m, d, h, mi, s: int) -> i64 {
	y := y
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) % 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := i64(era) * 146097 + i64(doe) - 719468
	return days * 86400 + i64(h) * 3600 + i64(mi) * 60 + i64(s)
}

@(private = "file")
month_of :: proc "contextless" (s: string) -> int {
	switch s {
	case "Jan":
		return 1
	case "Feb":
		return 2
	case "Mar":
		return 3
	case "Apr":
		return 4
	case "May":
		return 5
	case "Jun":
		return 6
	case "Jul":
		return 7
	case "Aug":
		return 8
	case "Sep":
		return 9
	case "Oct":
		return 10
	case "Nov":
		return 11
	case "Dec":
		return 12
	}
	return 0
}

// digits reads exactly `n` digits at `at`, answering the value and where
// they end, or -1 for an end when they are not there.
@(private = "file")
digits :: proc "contextless" (s: string, at: int, n: int) -> (v: int, end: int) #no_bounds_check {
	if at < 0 || at + n > len(s) {
		return 0, -1
	}
	for i in at ..< at + n {
		if s[i] < '0' || s[i] > '9' {
			return 0, -1
		}
		v = v * 10 + int(s[i] - '0')
	}
	return v, at + n
}

@(private = "file")
number :: proc "contextless" (s: string, at: int) -> (v: int, end: int) #no_bounds_check {
	i := at
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + int(s[i] - '0')
		i += 1
	}
	if i == at {
		return 0, -1
	}
	return v, i
}

@(private = "file")
skip_space :: proc "contextless" (s: string, at: int) -> int #no_bounds_check {
	i := at
	for i < len(s) && is_space(s[i]) {
		i += 1
	}
	return i
}


@(private = "file")
is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private = "file")
is_alpha :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// trim_space answers `s` without its leading and trailing white space.
trim_space :: proc "contextless" (s: string) -> string #no_bounds_check {
	a, b := 0, len(s)
	for a < b && is_space(s[a]) {
		a += 1
	}
	for b > a && is_space(s[b - 1]) {
		b -= 1
	}
	return s[a:b]
}

// format_822 writes `secs` as mail writes a date, `Sat, 19 Sep 2026
// 07:00:00 +0000`, into `into`, thirty-one bytes.
format_822 :: proc "contextless" (secs: i64, into: []u8) -> string #no_bounds_check {
	if len(into) < 31 {
		return ""
	}
	days_text := "SunMonTueWedThuFriSat"
	months_text := "JanFebMarAprMayJunJulAugSepOctNovDec"
	y, mo, d, h, mi, s := calendar(secs)
	days := secs / 86400
	if secs < 0 && secs % 86400 != 0 {
		days -= 1
	}
	wd := int((days + 4) % 7)
	if wd < 0 {
		wd += 7
	}
	copy(into[0:3], days_text[wd * 3:wd * 3 + 3])
	into[3], into[4] = ',', ' '
	pad2(into[5:7], d)
	into[7] = ' '
	copy(into[8:11], months_text[(mo - 1) * 3:(mo - 1) * 3 + 3])
	into[11] = ' '
	pad2(into[12:14], y / 100)
	pad2(into[14:16], y % 100)
	into[16] = ' '
	pad2(into[17:19], h)
	into[19] = ':'
	pad2(into[20:22], mi)
	into[22] = ':'
	pad2(into[23:25], s)
	copy(into[25:31], " +0000")
	return string(into[:31])
}

// format_3339 writes `secs` as the social networks write a date,
// `2026-09-18T12:30:00.000Z`, into `into`, twenty-four bytes.
format_3339 :: proc "contextless" (secs: i64, into: []u8) -> string #no_bounds_check {
	if len(into) < 24 {
		return ""
	}
	y, mo, d, h, mi, s := calendar(secs)
	pad2(into[0:2], y / 100)
	pad2(into[2:4], y % 100)
	into[4] = '-'
	pad2(into[5:7], mo)
	into[7] = '-'
	pad2(into[8:10], d)
	into[10] = 'T'
	pad2(into[11:13], h)
	into[13] = ':'
	pad2(into[14:16], mi)
	into[16] = ':'
	pad2(into[17:19], s)
	copy(into[19:24], ".000Z")
	return string(into[:24])
}

@(private = "file")
pad2 :: proc "contextless" (into: []u8, v: int) #no_bounds_check {
	into[0] = u8('0' + v / 10 % 10)
	into[1] = u8('0' + v % 10)
}
