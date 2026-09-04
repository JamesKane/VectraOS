# checkman.awk -- check the manual's pages.
#
#     awk -f man/lib/checkman.awk man/[0-9]/*
#
# Checks that the first line is a proper .TH naming the file, that the
# sections come in the order man(6) gives, that every .EX is closed, and that
# every cross reference `.IR name (n)` names a page that exists.

BEGIN {
	Weight["NAME"] = 1
	Weight["SYNOPSIS"] = 2
	Weight["DESCRIPTION"] = 4
	Weight["EXAMPLE"] = 8
	Weight["EXAMPLES"] = 16
	Weight["FILES"] = 32
	Weight["SOURCE"] = 64
	Weight["SEE ALSO"] = 128
	Weight["DIAGNOSTICS"] = 256
	Weight["BUGS"] = 512
	status = 0
}

FNR == 1 {
	n = split(FILENAME, part, "/")
	section = part[n-1]
	name = part[n]
	if (name ~ /^INDEX/)
		nextfile
	if ($1 != ".TH" || NF != 3)
		fail(FILENAME " does not start with .TH NAME n")
	else if ((name == "0intro" && $2 != "INTRO") || (name != "0intro" && $2 != toupper(name)) || $3 != section)
		fail(FILENAME ": .TH " $2 " " $3 " does not match the file name")
	else
		Pages[section "/" $2] = 1
	Sh = 0
	inex = 0
}

$1 == ".SH" {
	if (inex)
		fail(FILENAME ":" FNR ": .SH inside .EX")
	inex = 0
	title = $2
	for (i = 3; i <= NF; i++)
		title = title " " $i
	gsub(/"/, "", title)
	if (Sh == 0 && title != "NAME")
		fail(FILENAME ": first section is not NAME")
	w = Weight[title]
	if (w == 0)
		fail(FILENAME ":" FNR ": unknown section " title)
	else if (w < Sh)
		fail(FILENAME ":" FNR ": section " title " out of order")
	Sh += w
}

$1 == ".EX" {
	if (inex)
		fail(FILENAME ":" FNR ": nested .EX")
	inex = 1
}

$1 == ".EE" {
	if (!inex)
		fail(FILENAME ":" FNR ": .EE without .EX")
	inex = 0
}

$1 == ".TF" || $1 == ".L" || $1 == ".LR" || $1 == ".RL" {
	fail(FILENAME ":" FNR ": Plan 9 macro " $1 " is not rendered here")
}

/^\.[A-Z][A-Z]? .*\([0-9]\)/ {
	if ($1 == ".IR" && $3 ~ /^\([0-9]\)/) {
		ref = $3
		gsub(/[^0-9]/, "", ref)
		Refs[ref "/" toupper($2)] = FILENAME ":" FNR
	} else if ($1 == ".IR") {
		fail(FILENAME ":" FNR ": cross reference not of the form .IR name (n)")
	}
}

END {
	for (r in Refs)
		if (!(r in Pages))
			fail(Refs[r] ": reference to " tolower(r) ", which has no page")
	exit status
}

function fail(s) {
	print s
	status = 1
}
