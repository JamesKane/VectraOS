# The manual. `make check` renders every page and checks the cross
# references, `make index` rebuilds each section's INDEX, and
# `make show PAGE=1/cat` shows a page.

SECTIONS = 1 2 3 4 5 6 8 9
PAGES = $(foreach s,$(SECTIONS),$(filter-out $(s)/INDEX,$(wildcard $(s)/[a-z0-9]*)))

default: check

check:
	@for p in $(PAGES); do \
		mandoc -man -T lint -W error "$$p" || exit 1; \
	done
	@awk -f lib/checkman.awk $(PAGES)
	@echo "$(words $(PAGES)) pages, no errors"

index:
	@for s in $(SECTIONS); do sh lib/secindex.sh $$s > $$s/INDEX; done

show:
	@mandoc -man -T ascii "$(PAGE)" | less -R

.PHONY: default check index show
