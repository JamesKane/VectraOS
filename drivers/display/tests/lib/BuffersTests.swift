// SPDX-License-Identifier: BSD-3-Clause

// A client's two images of an output: what each frame draws (D146).

import DisplayDevice
import Testing

@Test func eachFrameDrawsItsDamageAndWhatTheOtherImageGotAlone() {
  var b = Buffers(width: 100, height: 50)
  let whole = DisplayRect(x: 0, y: 0, width: 100, height: 50)
  // The first frame fills the image it shows.
  #expect(b.back == 0)
  #expect(b.draw(DisplayRect(x: 10, y: 10, width: 5, height: 5)) == whole)
  b.shown()
  #expect(b.front == 0 && b.back == 1)
  // The second fills the other, which lacks everything still.
  #expect(b.draw(DisplayRect(x: 20, y: 0, width: 5, height: 5)) == whole)
  b.shown()
  // The third: its damage and the second's, which image 0 lacks.
  #expect(b.draw(DisplayRect(x: 0, y: 40, width: 5, height: 20)) == DisplayRect(x: 0, y: 0, width: 25, height: 50))
  b.shown()
  // The fourth: its damage and the third's (clipped), which image 1 lacks.
  #expect(b.draw(DisplayRect(x: 90, y: 0, width: 10, height: 1)) == DisplayRect(x: 0, y: 0, width: 100, height: 50))
}
