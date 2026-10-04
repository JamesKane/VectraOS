# ADR-0028: The manual is written in guide, a line-typed hypertext format, and checked against the code

Status: accepted, 2026-10-04 (proposed 2026-10-03). The design is docs/12-manual.md; M6 step 6a builds it.

## Context

VectraOS has no manual. M1–M5 shipped programs, syscalls, servers, drivers, manifests and a disk format with no pages; what they do is in the blueprint, which records intent, and in the code.

Plan 9 is the baseline (00 §1), and its manual is part of it: eight sections, `intro` pages, fixed headings, `name(N)` references, `man`, `lookman`, `sig`, and plumbing that opens a page from any window. Its pages are troff with the `-man` macros. Dropping troff drops a Plan 9 property, so it needs this ADR.

What troff does not give:
- **Links.** A reference is an italic word. Nothing can follow it or check that it resolves.
- **Structure as data.** NAME, SYNOPSIS and the flag lists are macro calls, so a build cannot compare them with the code without a troff interpreter.
- **Readable source.** Raw `-man` is hard to read with `cat`, and an agent or a script reading the manual would have to render it first.
- **Navigation within a long page,** which AmigaGuide's nodes, Contents and Browse gave on the Amiga.

The alternatives are compared in 12 §10: mdoc, Markdown, AmigaGuide unchanged, Texinfo and HTML.

## Decision

1. **The manual's format is guide** (12 §4): UTF-8 text with an ndb header, line-typed blocks with no nesting, AmigaGuide's nodes as `@node=` directives, and four inline forms (literal, parameter, `name(N)` link, `{label|target}` link). Version 1 is permanent; later versions are declared with `@guide=N` (rule 9).
2. **Plan 9's manual is kept in every other respect:** its eight sections, with section 7 holding concept pages; its headings and their order; `man`, `lookman` and `sig`; plumbing of `name(N)`.
3. **One library parses it,** `lib/vx-guide`, host and target, fuzzed. `man`, `hv`, `build` and the index use it.
4. **The build checks the manual against the code** (12 §7): a page for every program, header declaration, syscall, server, driver, 9Px message and configuration key. Usage messages are generated from pages; declarations, `.schema` files and key tables are compared with them. `.help` is generated from the page.
5. **The undocumented backlog is a list that only shrinks,** `man/missing`, until it is empty; then the check has no list.
6. **Pages live in `man/<sect>/<page>`** in the repository and `/lib/man` installed, with packages' pages bound in as a union and indexed by `/lib/man/index/`.

## Consequences

- Every step from the one that lands this writes its pages, and the commit that changes behaviour changes the page.
- About 1,500 first-party lines (`lib/vx-guide`, `man`, `lookman`, `sig`, the check pass), and no import. No troff is ported.
- The manual cannot be typeset; it prints as its terminal rendering. Plan 9's papers in `/sys/doc` have no counterpart beyond section 7 and the blueprint.
- `hv` renders guide beside gemtext and Markdown. 12 §11 proposes a local-only `hv` at M7 so the manual has a viewer before M15.
- 02 §4's `.help` and 09 §5.11 are refined: `.help` comes from the page, `.schema` from the code.
