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

// The keys that move a cursor.
KHOME :: KF | 0x0D
KUP :: KF | 0x0E
KPGUP :: KF | 0x0F
KLEFT :: KF | 0x11
KRIGHT :: KF | 0x12
KPGDOWN :: KF | 0x13
KINS :: KF | 0x14
KEND :: KF | 0x18

// `Kview` in `keyboard.h`, which is what a down arrow is an alias for.
KDOWN :: rune(0xF800)

// The modifiers, which a `kbd` file reports as keys held and a `cons`
// file never delivers. `KMOD4` is the key with a flag on it.
KALT :: KF | 0x15
KSHIFT :: KF | 0x16
KCTL :: KF | 0x17
KCAPS :: KF | 0x64
KNUM :: KF | 0x65
KMOD4 :: KF | 0x68

// The keys that are neither. Print screen, scroll lock, and the twelve
// function keys, `KF1` through `KF12` in order.
KPRINT :: KF | 0x10
KSCROLL :: KF | 0x19
KF1 :: KF | 0x01
KF12 :: KF | 0x0C

// Three keys that are characters after all, named here because a key
// table wants a name for every position. Delete is what `keyboard.h`
// says it is, and escape and backspace are ASCII's.
KESC :: rune(0x1B)
KBS :: rune(0x08)
KDEL :: rune(0x7F)
