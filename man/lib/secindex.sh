#!/bin/sh
# secindex.sh -- one line per name from the NAME sections of one manual
# section, sorted, the way Plan 9's /sys/lib/man/secindex does it.
#
#     sh man/lib/secindex.sh man/1 > man/1/INDEX
#
# Each line is `name page`, so `grep '^cat ' man/1/INDEX` says which page
# documents cat.
cd "$1" || exit 1
for page in [a-z0-9]*; do
	case $page in
	INDEX*) continue ;;
	esac
	sed -n '/^\.SH NAME/,/^\.SH/{
		/^\.SH/d
		s/ *\\-.*//
		s/, */\
/g
		p
	}' "$page" | sed "s/^ *//; /^\$/d; s/\$/ $page/"
	echo "$page $page"
done | sort -u
