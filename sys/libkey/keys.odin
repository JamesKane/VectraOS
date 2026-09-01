/*
The keys that have no character, as the runes Plan 9 gives them.

**A key that is not a character still has to arrive somehow.** An arrow key
produces no byte: `kernel/drivers/kbd` consumed the `0xE0` prefix and dropped
the key, because an extended scancode shares its second byte with an ordinary
one and translating it would make an arrow type a letter.

`sys/include/keyboard.h` answers that by putting every such key in the
**private Unicode space**. `KF` is where it begins, and every value below is
above `0x7F` -- so a stream carrying UTF-8 carries them, and no byte of ASCII
can ever be mistaken for one. That is the whole trick: the encoding is what
lets a keyboard say something a byte cannot.

**The encoding itself is not here.** `core:unicode/utf8` is UTF-8, it compiles
freestanding, and a second copy of `chartorune`'s arithmetic would be a second
thing to keep right. What this package is for is the half the standard library
cannot have: which numbers Plan 9 assigns to which keys.

They are copied from `keyboard.h` rather than derived, because they are a wire
format. A program on either side of `/dev/cons` has to agree with this list,
and that file is where the agreement is written down.
*/
package libkey

KF :: rune(0xF000) // The beginning of the private space

KHOME :: KF | 0x0D
KUP :: KF | 0x0E
KLEFT :: KF | 0x11
KRIGHT :: KF | 0x12
KEND :: KF | 0x18

// `Kview` in `keyboard.h`, which is what a down arrow is an alias for.
KDOWN :: rune(0xF800)
