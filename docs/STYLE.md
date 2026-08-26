# How this project writes

Vectra's comments are the design documents. `kernel/sync/sleep.odin` opens with
forty lines on why a spinlock cannot be held across a wait, and `docs/SYNC.md`
exists because that argument outgrew the file. Prose here is not decoration on
the code. It is the only place several of these decisions are written down.

That makes the prose worth a standard, so it has one. Vectra writes under
**ASD-STE100**, Simplified Technical English. The AeroSpace and Defense
Industries Association of Europe built it so that a maintenance technician on a
tarmac cannot misread an instruction. It is a good fit here for a different
reason. The people most likely to read this tree are not the person who wrote
it. A design note that admits two readings is worth less than one that admits
one.

## Two modes, and which text gets which

STE has a strict mode and a relaxed one. Both are in use here, and the split
follows the reader.

**Strict** applies to the strings the kernel itself prints:

- the reason in a `sync.fail` call
- a panic message
- an `Error` description in `sys/vectra9/errors.odin`
- the name of a check in a `verify_*` file
- every line that reaches `klog`

Nobody reads those with the source open. They arrive alone, on a framebuffer,
at the moment something went wrong. Every rule applies, including the 20-word
cap.

**STE-flavored** applies to everything else: doc comments, line comments, and
the markdown under `docs/`. It keeps every structural rule and drops the
one-word-one-meaning lockdown. That is the standard's own advice for
explanatory prose, and it is the right advice. A strict rewrite of a design note
reads as a personality transplant rather than a clarification. This tree would
lose the thing that makes it worth reading.

The two modes never disagree about a sentence. They disagree about how many
words a paragraph may spend making one point.

## The rules a program can check

`tools/ste-lint.py` checks seven of the standard's 53 rules. These seven are the
ones a program can decide with no dictionary and no judgement call.

    semicolon    Rule 8.1 bans the mark outright, not only as a clause join
    length       25 words for description, 20 for anything the kernel prints
    perfect      present and past perfect, unless a modal needs the compound
    passive      a be-verb, a past participle, and a "by" phrase naming an
                 actor the sentence could have used as its subject
    phrasal      two-word verbs whose meaning the parts do not predict
    marketing    adjectives that claim a quality instead of showing it
    paragraph    one topic, at most six sentences

Run it over the whole tree, or over one file:

    tools/ste-lint.py
    tools/ste-lint.py --show kernel/sync/sleep.odin
    tools/ste-lint.py --rule semicolon docs
    tools/ste-lint.py --strict kernel sys

It exits non-zero when it finds anything, so it works as a gate. `odin run
build.odin -file -- lint` runs the same thing as a build step.

The tree is at zero. A finding is a regression, and the fix is the sentence,
not the linter.

## The rules a program cannot check

STE's lexical rules are the other half of the standard. A dictionary of about
900 approved words defines them entirely, and pins each word to one meaning and
one part of speech. That dictionary is free to obtain and is not free to
redistribute. It is therefore not in this repository, and the linter does not
encode it. Issue 9 grants reproduction rights to eight categories of
organization, and a hobby kernel is in none of them.

What is left is the principle behind the rules: pick the plainest word that
works, and use it the same way every time. Applied by hand, checked by reading.
Anyone who needs real dictionary compliance should request Issue 9 from
<https://www.asd-ste100.org/STE_downloads.html> and check word by word.

One verb form is worth naming because the linter stays quiet about it. STE
permits an `-ing` word only as a technical noun, never as a verb form. So
`Retrying would be shorter` wants to be `A retry would be shorter`. Reliable
detection needs a part-of-speech tagger. Fix these by eye.

## The project dictionary

STE lets an organization define technical terms beyond its base dictionary, and
this one needs the allowance. Two kinds of entry earn a place here. The first
is a word this tree pins to one meaning. The second is a pair of words a reader
would otherwise take for synonyms.

**Pinned to one meaning.**

    check       one assertion in a self-test, and the verb for making it.
                Not "verify", "confirm", "assert" or "ensure". `verify_*` is
                a procedure-name prefix and is not affected.
    park        take a thread off every run queue until something wakes it.
                The prose word. `block` is the scheduler hook that does it and
                `sleep` is the `sync` call that asks for it.
    hold        a thread has a lock right now. `take` is how it got it and
                `release` is how it gives it back with nobody waiting.
    hand over   a lock moves straight to a waiter without ever being free.
                Kept as a two-word verb, against Rule 9.3, because it is the
                name of the mechanism -- see `docs/SYNC.md`.
    slot        one entry in a fixed-size pool, addressed by index.
    tick        one timer interrupt. The unit of every deadline in the tree.
    slice       the run of ticks a thread gets before the scheduler preempts
                it.

**Distinctions that look like synonyms and are not.**

    ready vs unpark     `ready` wakes a thread that waited on something
                        outside itself and gives its priority back. `unpark`
                        wakes a thread that queued for a lock and does not.
                        `docs/SCHED.md` and `kernel/sync/wait.odin`.
    chan vs fid         a `Chan` is this kernel's handle. A fid is the number
                        the 9P server knows it by. One chan holds one fid.
    Rendez vs Mutex     a mutex transfers the thing being waited for, so a
                        woken thread re-checks nothing. A rendezvous transfers
                        nothing, so a wake is only a hint and the sleeper
                        loops.
    check vs control    a check is an assertion that runs every boot. A
                        control is a deliberate mutation of the code, run once
                        by hand, to find out whether any check notices. See
                        `docs/TESTING.md`.

## Departures, stated rather than hidden

Three rules are relaxed on purpose. Each is a departure from the standard, and
naming them is cheaper than letting a reader find them and assume drift.

1. **The em dash stays.** STE bans the semicolon and permits every other
   standard mark, the em dash included. A dash here often does mark a sentence
   that wants splitting, so the linter's length rule usually catches it anyway.

2. **Present perfect stays where it carries information the simple past
   cannot.** `The job has completed` and `the job completed` are different
   claims. Status text needs the first. The same goes for a hedge. `may have
   failed` keeps its auxiliary, because the simple form asserts a failure
   nothing observed. Where the tense rule and the modality rule disagree,
   modality wins.

3. **Display tables are not sentences.** The aligned two-column blocks in doc
   comments are a layout, so the length rule skips them. Rule 8.1 does not skip
   them, which is why they separate their columns with commas now.

## Writing something new

Write it the way you would have anyway, then run the linter and fix what it
names. That order matters. STE fixes the form of a text and not its substance.
A hollow paragraph rewritten under these rules becomes a short, clean,
well-punctuated hollow paragraph. If a comment has nothing to say, no rewrite
saves it. Delete it instead.

Two habits do most of the work before the linter ever runs. Put one idea in one
sentence. Name the thing that acts, and make it the subject.

## Where the standard lives

`.claude/skills/asd-ste100/` holds the skill this project migrated under, from
<https://github.com/danyuchn/asd-ste100-skill> at `d5ce157`, MIT licensed. It
carries the rule summary, the worked before-and-after examples, and the
citations. It does not carry ASD's dictionary, for the reason above.

## See also

- `docs/TESTING.md` -- the self-test discipline these rules are modelled on. A
  rule that nothing checks is a rule that drifts.
- `docs/HANDOFF.md` -- what Vectra is, and which document answers which
  question.
