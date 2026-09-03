/*
 * The ring 3 programs, as bytes in the kernel's text, on arm64.
 *
 * Not ported yet. `kernel/user/programs_amd64.S` holds thirty-one programs
 * written in x86-64 assembly, one per self-test in `kernel/user/verify.odin`,
 * and each has to be written again in this architecture's own. Until then,
 * every one is a single trapping instruction under the same symbol, so the
 * kernel links, `program.odin`'s declarations resolve, and a program that
 * runs ends on its first instruction rather than on nothing. The self-test
 * that runs them will say so, loudly, and that is the point of keeping the
 * names: the list of what is missing is the list of symbols here.
 */
	.text
.balign 16
.globl vectra_user_anon
vectra_user_anon:
	brk #0
.globl vectra_user_anon_end
vectra_user_anon_end:

.balign 16
.globl vectra_user_binder
vectra_user_binder:
	brk #0
.globl vectra_user_binder_end
vectra_user_binder_end:

.balign 16
.globl vectra_user_bulkio
vectra_user_bulkio:
	brk #0
.globl vectra_user_bulkio_end
vectra_user_bulkio_end:

.balign 16
.globl vectra_user_catcher
vectra_user_catcher:
	brk #0
.globl vectra_user_catcher_end
vectra_user_catcher_end:

.balign 16
.globl vectra_user_child
vectra_user_child:
	brk #0
.globl vectra_user_child_end
vectra_user_child_end:

.balign 16
.globl vectra_user_dfltnote
vectra_user_dfltnote:
	brk #0
.globl vectra_user_dfltnote_end
vectra_user_dfltnote_end:

.balign 16
.globl vectra_user_execer
vectra_user_execer:
	brk #0
.globl vectra_user_execer_end
vectra_user_execer_end:

.balign 16
.globl vectra_user_fdforker
vectra_user_fdforker:
	brk #0
.globl vectra_user_fdforker_end
vectra_user_fdforker_end:

.balign 16
.globl vectra_user_forker
vectra_user_forker:
	brk #0
.globl vectra_user_forker_end
vectra_user_forker_end:

.balign 16
.globl vectra_user_grouper
vectra_user_grouper:
	brk #0
.globl vectra_user_grouper_end
vectra_user_grouper_end:

.balign 16
.globl vectra_user_hello
vectra_user_hello:
	brk #0
.globl vectra_user_hello_end
vectra_user_hello_end:

.balign 16
.globl vectra_user_jump
vectra_user_jump:
	brk #0
.globl vectra_user_jump_end
vectra_user_jump_end:

.balign 16
.globl vectra_user_mapper
vectra_user_mapper:
	brk #0
.globl vectra_user_mapper_end
vectra_user_mapper_end:

.balign 16
.globl vectra_user_memfork
vectra_user_memfork:
	brk #0
.globl vectra_user_memfork_end
vectra_user_memfork_end:

.balign 16
.globl vectra_user_namer
vectra_user_namer:
	brk #0
.globl vectra_user_namer_end
vectra_user_namer_end:

.balign 16
.globl vectra_user_niner
vectra_user_niner:
	brk #0
.globl vectra_user_niner_end
vectra_user_niner_end:

.balign 16
.globl vectra_user_noter
vectra_user_noter:
	brk #0
.globl vectra_user_noter_end
vectra_user_noter_end:

.balign 16
.globl vectra_user_nowaiter
vectra_user_nowaiter:
	brk #0
.globl vectra_user_nowaiter_end
vectra_user_nowaiter_end:

.balign 16
.globl vectra_user_painter
vectra_user_painter:
	brk #0
.globl vectra_user_painter_end
vectra_user_painter_end:

.balign 16
.globl vectra_user_parent
vectra_user_parent:
	brk #0
.globl vectra_user_parent_end
vectra_user_parent_end:

.balign 16
.globl vectra_user_peek
vectra_user_peek:
	brk #0
.globl vectra_user_peek_end
vectra_user_peek_end:

.balign 16
.globl vectra_user_poke
vectra_user_poke:
	brk #0
.globl vectra_user_poke_end
vectra_user_poke_end:

.balign 16
.globl vectra_user_poster
vectra_user_poster:
	brk #0
.globl vectra_user_poster_end
vectra_user_poster_end:

.balign 16
.globl vectra_user_priv
vectra_user_priv:
	brk #0
.globl vectra_user_priv_end
vectra_user_priv_end:

.balign 16
.globl vectra_user_probe
vectra_user_probe:
	brk #0
.globl vectra_user_probe_end
vectra_user_probe_end:

.balign 16
.globl vectra_user_reader
vectra_user_reader:
	brk #0
.globl vectra_user_reader_end
vectra_user_reader_end:

.balign 16
.globl vectra_user_refuser
vectra_user_refuser:
	brk #0
.globl vectra_user_refuser_end
vectra_user_refuser_end:

.balign 16
.globl vectra_user_shadow
vectra_user_shadow:
	brk #0
.globl vectra_user_shadow_end
vectra_user_shadow_end:

.balign 16
.globl vectra_user_sharedseg
vectra_user_sharedseg:
	brk #0
.globl vectra_user_sharedseg_end
vectra_user_sharedseg_end:

.balign 16
.globl vectra_user_sharer
vectra_user_sharer:
	brk #0
.globl vectra_user_sharer_end
vectra_user_sharer_end:

.balign 16
.globl vectra_user_spin
vectra_user_spin:
	brk #0
.globl vectra_user_spin_end
vectra_user_spin_end:

