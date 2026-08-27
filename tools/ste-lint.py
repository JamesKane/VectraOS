#!/usr/bin/env python3
"""
Check the prose in this tree against the structural rules of ASD-STE100.

What it reads is prose, not code: the block and line comments in `*.odin`, the
body text of `README.md` and `docs/*.md`, and -- in strict mode -- the runtime
strings the kernel prints. Code inside those regions is skipped, because a `::` declaration
quoted in a doc comment is not a sentence and has no opinion about semicolons.

The standard has 53 rules. This checks the seven that a program can decide on
its own, with no dictionary and no judgement call:

    semicolon        banned outright by rule 8.1
    length           20 words for an instruction, 25 for description
    perfect          present and past perfect, unless a modal needs them
    passive          a be-verb and a past participle, in prose that is not a
                     description of something with no actor
    phrasal          two-word verbs whose meaning the parts do not predict
    marketing        adjectives that claim quality instead of showing it
    paragraph        one topic, six sentences

The rules it cannot check are the lexical ones. They are defined by ASD's
approved-word dictionary, which is not redistributable and is not here. See
`docs/STYLE.md` for what this project does about that.

Usage:
    tools/ste-lint.py [--strict] [--show] [--rule NAME] [PATH ...]
"""

import argparse
import os
import re
import sys

# ---------------------------------------------------------------- vocabulary

# Two-word verbs whose meaning the parts do not predict (rule 9.3). Only the
# ones that actually turn up in a systems codebase are listed. A pair like
# "hand back" is a phrasal verb too, but it names a real thing here -- a mutex
# handing ownership back -- so it stays and is not in this list.
PHRASAL = [
    (r"\bspin(s|ning)? up\b", "start"),
    (r"\bkick(s|ed|ing)? off\b", "start"),
    (r"\bfire(s|d)? up\b", "start"),
    (r"\breach(es|ed)? out\b", "contact"),
    (r"\bdive(s|d)? into\b", "read"),
    (r"\btake(s|n)? off\b", "remove"),
    (r"\bfigure(s|d)? out\b", "determine"),
    (r"\bcome(s)? up with\b", "propose"),
    (r"\bend(s|ed)? up\b", "become"),
    (r"\bcarr(y|ies|ied) out\b", "do"),
    (r"\bput(s)? in place\b", "install"),
    (r"\bget(s)? rid of\b", "remove"),
    (r"\bsort(s|ed)? out\b", "resolve"),
    (r"\bpull(s|ed)? in\b", "import"),
]

# Adjectives that claim a quality instead of showing it, plus the two verbs
# that are always a plainer verb in disguise.
MARKETING = [
    r"\bseamless(ly)?\b", r"\brobust(ly)?\b", r"\bpowerful(ly)?\b",
    r"\bcutting[- ]edge\b", r"\beffortless(ly)?\b", r"\bblazing(ly)?\b",
    r"\bdramatic(ally)?\b", r"\bincredibl[ey]\b", r"\bleverag(e|es|ed|ing)\b",
    r"\butiliz(e|es|ed|ing)\b", r"\bstate[- ]of[- ]the[- ]art\b",
    r"\bbest[- ]in[- ]class\b", r"\bworld[- ]class\b", r"\brich(ly)? featured\b",
]

# Irregular past participles. Regular ones are caught by the -ed suffix.
IRREGULAR = set("""
been begun bound bought brought built burnt caught chosen come cost cut dealt
done drawn driven fallen fed felt fought found forgotten given gone got gotten
grown had heard held hidden hit hurt kept known laid led left lent let lost
made meant met paid put read run said seen sent set shown shut slept sold sent
spent split spread stood struck sung sunk swept taken taught thought thrown
told torn understood woken won withdrawn written woven wound
""".split())

MODALS = {"may", "might", "could", "would", "should", "must", "can", "will",
          "shall", "cannot", "could", "wo"}

BE = {"is", "are", "was", "were", "be", "been", "being", "am"}

ADVERB_OK = re.compile(r"^\w+ly$")

# Abbreviations whose full stop does not end a sentence.
# "no." for "number" is deliberately absent: in this tree "the answer is no."
# ends a sentence far more often than it abbreviates anything.
ABBREV = {"e.g.", "i.e.", "etc.", "vs.", "cf.", "al.", "fig.", "sec.",
          "ch.", "approx.", "dr.", "mr.", "ms.", "st."}


def is_participle(word: str) -> bool:
    w = word.lower().strip(".,;:!?()\"'")
    if w in IRREGULAR:
        return True
    if len(w) > 3 and w.endswith("ed"):
        return True
    return False


# ------------------------------------------------------------- prose regions

CODEISH = re.compile(
    r"(::|:=|->|\+\+|\|\||&&|\bproc\b|\bstruct\b|\benum\b|^\s*[#@]|"
    r"[{}]\s*$|;\s*$|\bpackage\b|\bimport\b|^\s*\$|^\s*\d+\s*[|]|"
    r"^\s*[-+*]\s*$|^\s*[|+][-=|+ ]*[|+]\s*$)"
)


# Inside a `...` span, a full stop is part of an identifier rather than the end
# of a sentence. Hide those characters behind private-use codepoints for the
# duration of the checks, and put them back before anything is printed, so a
# finding quotes the source verbatim.
HIDDEN = {".": "\ue000", ";": "\ue001", "!": "\ue002", "?": "\ue003"}
SHOWN = {v: k for k, v in HIDDEN.items()}


def strip_inline_code(text: str) -> str:
    def hide(m):
        s = m.group(0)
        for ch, sub in HIDDEN.items():
            s = s.replace(ch, sub)
        return s
    return re.sub(r"`[^`]*`", hide, text)


def unhide(text: str) -> str:
    for sub, ch in SHOWN.items():
        text = text.replace(sub, ch)
    return text


def odin_prose(path):
    """Yield (lineno, text) for every prose line in an Odin file.

    Leading whitespace inside a block comment is kept, because this tree uses
    it for aligned display tables and `is_table_row` needs to see it. Tabs
    become four spaces so an indent inside a tab-indented doc comment measures
    the same as one at the top of a file."""
    out = []
    in_block = False
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip().replace("\t", "    ")
            stripped = line.strip()
            if not in_block:
                if stripped.startswith("/*"):
                    in_block = True
                    body = line.split("/*", 1)[1]
                    if "*/" in body:
                        in_block = False
                        body = body.split("*/")[0]
                    if body.strip():
                        out.append((n, body))
                    continue
                if stripped.startswith("//"):
                    out.append((n, line.split("//", 1)[1]))
                continue
            # inside a block comment
            if "*/" in line:
                in_block = False
                line = line.split("*/")[0]
            out.append((n, line))
    return [(n, t) for n, t in out if t.strip()]


def md_prose(path):
    """Yield (lineno, text) for every prose line in a markdown file."""
    out = []
    fenced = False
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line.strip().startswith("```"):
                fenced = not fenced
                continue
            if fenced:
                continue
            out.append((n, line))
    return [(n, t) for n, t in out if t.strip()]


def is_code_line(text: str) -> bool:
    """A prose-region line that is really a quoted fragment of code."""
    if text.startswith("    ") and CODEISH.search(text) \
            and not DISPLAY_ROW.match(text):
        return True
    if CODEISH.search(text) and not text.strip().startswith("`"):
        # a bare declaration on its own, e.g. in an indented display block
        if len(text.split()) <= 12 and not text.strip().endswith("."):
            return True
    return False


DISPLAY_ROW = re.compile(r"^\s{4,}\S.*?\S\s{2,}\S")


def is_table_row(text: str) -> bool:
    """A row of a table rather than a sentence.

    Two shapes count. A markdown pipe table, and the aligned two-column block
    that this tree uses inside doc comments -- four spaces of indent, then a
    term, then a run of spaces, then its gloss. Both are a layout, so the
    length and paragraph rules skip them. Rule 8.1 does not skip them: a
    semicolon between two columns is still a semicolon."""
    s = text.strip()
    if s.startswith("|") or re.match(r"^[|:\- ]+$", s):
        return True
    return bool(DISPLAY_ROW.match(text))


# -------------------------------------------------------------- the sentences

# A sentence may end inside markdown emphasis -- "...at once.** A worker..." --
# so the trailing set has to allow the marks that close it.
SENT_END = re.compile(r"(?<=[.!?])[\"')\]*_]*\s+")


def sentences(text: str):
    """Split prose into sentences, keeping identifiers with dots intact."""
    text = strip_inline_code(text)
    parts = SENT_END.split(text)
    merged = []
    for p in parts:
        if merged and merged[-1].split() and \
                merged[-1].split()[-1].lower() in ABBREV:
            merged[-1] = merged[-1] + " " + p
        else:
            merged.append(p)
    return [m.strip() for m in merged if m.strip()]


# ------------------------------------------------------------------ the rules

def check_semicolon(sent, ctx):
    # A semicolon inside a quoted string that the kernel prints is code, and
    # is caught by the strict pass instead.
    if ";" in sent:
        return "rule 8.1 bans the semicolon"
    return None


def check_length(sent, ctx):
    words = [w for w in re.split(r"\s+", sent) if re.search(r"\w", w)]
    n = len(words)
    cap = 20 if ctx["imperative"] else 25
    if n > cap:
        return f"{n} words, cap is {cap}"
    return None


def check_perfect(sent, ctx):
    words = sent.split()
    for i, w in enumerate(words):
        lw = w.lower().strip(".,:!?()\"'")
        if lw in ("have", "has", "had"):
            # a modal in front means the compound form is carrying a hedge
            if i > 0 and words[i - 1].lower().strip(".,") in MODALS:
                continue
            j = i + 1
            if j < len(words) and ADVERB_OK.match(words[j].lower()):
                j += 1
            if j < len(words) and is_participle(words[j]):
                if words[j].lower().strip(".,") == "to":
                    continue
                return f'"{w} {words[j]}"'
    return None


def check_passive(sent, ctx):
    words = sent.split()
    for i, w in enumerate(words):
        lw = w.lower().strip(".,:!?()\"'")
        if lw in BE:
            j = i + 1
            if j < len(words) and ADVERB_OK.match(words[j].lower()):
                j += 1
            if j < len(words) and is_participle(words[j]):
                nxt = words[j + 1].lower().strip(".,") if j + 1 < len(words) else ""
                # "is held by the caller" is passive with a named actor;
                # "is held" with no actor is the allowed descriptive form only
                # when the actor is genuinely unknown, which a program cannot
                # decide. Flag the one with a "by" phrase -- that one always
                # has an actor to promote.
                if nxt == "by":
                    return f'"{w} {words[j]} by"'
    return None


def check_phrasal(sent, ctx):
    low = sent.lower()
    for pat, better in PHRASAL:
        m = re.search(pat, low)
        if m:
            return f'"{m.group(0)}" -> "{better}"'
    return None


def check_marketing(sent, ctx):
    low = sent.lower()
    for pat in MARKETING:
        m = re.search(pat, low)
        if m:
            return f'"{m.group(0)}"'
    return None


RULES = [
    ("semicolon", check_semicolon),
    ("length", check_length),
    ("perfect", check_perfect),
    ("passive", check_passive),
    ("phrasal", check_phrasal),
    ("marketing", check_marketing),
]

IMPERATIVE_HINT = re.compile(
    r"^(Do|Use|Set|Call|Add|Remove|Keep|Write|Read|Run|Check|Make|Put|Give|"
    r"Take|Note|See|Prefer|Avoid|Never|Always|Start|Stop|Open|Close)\b")


# ------------------------------------------------------------------ the blocks

def blocks(lines):
    """Join consecutive prose lines into one block, so a sentence that wraps
    over three lines is measured as one sentence. Yields (first_line, text,
    is_table)."""
    out = []
    buf, start, prev, table = [], None, None, False

    def flush():
        if buf:
            out.append((start, " ".join(buf), table))

    for n, t in lines:
        s = t.strip()
        if is_code_line(t):
            flush(); buf, start, prev = [], None, None; continue
        row = is_table_row(t)
        head = s.startswith("#")
        body = s.lstrip("#>").strip()
        body = re.sub(r"^[-*+]\s+|^\d+\.\s+", "", body)
        if not body:
            flush(); buf, start, prev = [], None, None; continue
        # a heading, a table row, or a list item each stand alone
        starts_own = head or row or s != body
        if starts_own or (prev is not None and n > prev + 1) or table != row:
            flush(); buf, start, prev = [], None, None
        if start is None:
            start, table = n, row
        buf.append(body)
        prev = n
        if starts_own:
            flush(); buf, start, prev = [], None, None
    flush()
    return out


# ------------------------------------------------------------- paragraph rule

def check_paragraphs(lines, report, path):
    """Six sentences to a paragraph, one topic each. Only the count is
    checkable."""
    para, start = [], None
    def flush():
        if not para:
            return
        text = " ".join(para)
        sents = sentences(text)
        if len(sents) > 6:
            report(path, start, "paragraph",
                   f"{len(sents)} sentences, cap is 6", text[:70])
    prev = None
    for n, t in lines:
        s = t.strip()
        # A heading, a table row, a quoted fragment of code, or a list item
        # each stand outside the paragraph they sit next to. A bulleted list
        # is a list, and the six-sentence cap does not apply to it.
        if is_code_line(t) or is_table_row(t) or s.startswith("#") \
                or re.match(r"^([-*+]\s+|\d+\.\s+)", s):
            flush(); para, start = [], None; prev = n; continue
        if prev is not None and n > prev + 1:
            flush(); para, start = [], None
        if start is None:
            start = n
        para.append(t.strip())
        prev = n
    flush()


# ---------------------------------------------------------------- strict mode

# Strings the kernel prints, or panics with. These are the error-message and
# status-report case the standard was built for, so they get the full rules.
STRICT_CALLS = re.compile(
    r'\b(fail|panic|die|scheck|check|vcheck|mcheck|fcheck|rcheck|put_str)\s*\('
)
STRING_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')


def strict_strings(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not STRICT_CALLS.search(line):
                continue
            for m in STRING_LIT.finditer(line):
                s = m.group(1)
                if len(s.split()) >= 3:
                    out.append((n, s))
    return out


# ---------------------------------------------------------------------- main

def walk(paths):
    files = []
    for p in paths:
        if os.path.isfile(p):
            files.append(p)
            continue
        for root, dirs, names in os.walk(p):
            dirs[:] = [d for d in dirs
                       if d not in (".git", "build", ".claude", "tools")]
            for nm in sorted(names):
                if nm.endswith(".odin") or nm.endswith(".md"):
                    files.append(os.path.join(root, nm))
    return sorted(set(files))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("paths", nargs="*",
                    default=["README.md", "docs", "kernel", "sys"])
    ap.add_argument("--show", action="store_true", help="print every finding")
    ap.add_argument("--full", action="store_true",
                    help="print the whole sentence, not the first 70 characters")
    ap.add_argument("--strict", action="store_true",
                    help="also check the strings the kernel prints")
    ap.add_argument("--rule", action="append", help="limit to these rules")
    args = ap.parse_args()
    paths = args.paths or ["README.md", "docs", "kernel", "sys"]

    findings = []

    def report(path, line, rule, detail, sample):
        findings.append((path, line, rule, detail, sample))

    for path in walk(paths):
        lines = md_prose(path) if path.endswith(".md") else odin_prose(path)
        for start, block, table in blocks(lines):
            for sent in sentences(block):
                # Doc comments and design notes are descriptive text, which
                # takes the 25-word cap. The 20-word procedure cap applies to
                # the strings the kernel prints -- see the strict pass.
                ctx = {"imperative": False}
                for name, fn in RULES:
                    if args.rule and name not in args.rule:
                        continue
                    # a markdown table cell is not a sentence; only the
                    # lexical rules apply to it
                    if table and name in ("length", "passive", "perfect"):
                        continue
                    d = fn(sent, ctx)
                    if d:
                        report(path, start, name, d,
                               unhide(sent if args.full else sent[:70]))
        if not (args.rule and "paragraph" not in args.rule):
            check_paragraphs(lines, report, path)

    if args.strict:
        for path in walk([p for p in paths if not p.endswith(".md")]):
            if not path.endswith(".odin"):
                continue
            for n, s in strict_strings(path):
                ctx = {"imperative": True}
                for name, fn in RULES:
                    if args.rule and name not in args.rule:
                        continue
                    d = fn(s, ctx)
                    if d:
                        report(path, n, "strict/" + name, d, s[:70])

    findings.sort()
    if args.show:
        cur = None
        for path, line, rule, detail, sample in findings:
            if path != cur:
                print(f"\n{path}")
                cur = path
            print(f"  {line:>5}  {rule:<18} {detail}")
            for chunk in [sample[i:i + 76] for i in range(0, len(sample), 76)]:
                print(f"         {chunk}")

    # summary
    by_file, by_rule = {}, {}
    for path, line, rule, detail, sample in findings:
        by_file[path] = by_file.get(path, 0) + 1
        by_rule[rule] = by_rule.get(rule, 0) + 1
    print()
    for rule in sorted(by_rule, key=lambda r: -by_rule[r]):
        print(f"  {by_rule[rule]:>5}  {rule}")
    print(f"  {'-' * 5}")
    print(f"  {len(findings):>5}  total in {len(by_file)} files")
    if not args.show and findings:
        print("\n  (--show to list them, --rule NAME to narrow)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
