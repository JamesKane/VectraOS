import CroiRuntime

/// PixelKernels (D129) built as Embedded Swift and run on the target:
/// each kernel against its scalar reference, the same bytes from the same
/// inputs, over spans of 0 to 40 pixels from four starting offsets (a span
/// of one, of a vector less one, and ends a vector doesn't divide), with
/// sources whose alpha runs opaque, clear and in between, each run long
/// enough to fill a vector and starting where none begins; a colour at
/// coverages from none to past full, and a glyph's row of coverage at
/// three alphas and contrasts, over grounds in runs alike.
enum PixelsSuite {
    static func run() {
        let size = 64
        let source = UnsafeMutablePointer<UInt32>.allocate(capacity: size)
        let kernel = UnsafeMutablePointer<UInt32>.allocate(capacity: size)
        let reference = UnsafeMutablePointer<UInt32>.allocate(capacity: size)
        defer {
            unsafe source.deallocate()
            unsafe kernel.deallocate()
            unsafe reference.deallocate()
        }
        // An xorshift's words: colours, and the under's top bytes set too.
        var state: UInt32 = 0x9E37_79B9
        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
        // Alpha in runs: 11 opaque, 13 clear (premultiplied, all of it
        // zero), 9 in between, and again.
        func fillSource(premultiplied: Bool) {
            for i in 0..<size {
                let c = next()
                switch i % 33 {
                case 0..<11: unsafe source[i] = 0xFF00_0000 | c & 0xFF_FFFF
                case 11..<24: unsafe source[i] = premultiplied ? 0 : c & 0xFF_FFFF
                default:
                    let a = c >> 24
                    // Premultiplied: no channel above its alpha.
                    // (<< binds tighter than * and /.)
                    unsafe source[i] = premultiplied ? a << 24 | ((c >> 16 & 0xFF) * a / 255) << 16
                        | ((c >> 8 & 0xFF) * a / 255) << 8 | (c & 0xFF) * a / 255 : c
                }
            }
        }
        func fillTargets() {
            for i in 0..<size {
                let c = next()
                unsafe kernel[i] = c
                unsafe reference[i] = c
            }
        }
        func same() -> Bool {
            for i in 0..<size where unsafe kernel[i] != reference[i] { return false }
            return true
        }
        // A glyph's coverage: runs of clear (some a whole vector), full
        // and in between.
        let coverage = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { unsafe coverage.deallocate() }
        func fillCoverage() {
            for i in 0..<size {
                let c = next()
                switch i % 29 {
                case 0..<10: unsafe coverage[i] = 0
                case 10..<14: unsafe coverage[i] = 255
                default: unsafe coverage[i] = UInt8(truncatingIfNeeded: c)
                }
            }
        }
        // Targets in runs alike, as a ground under text is, and dark and
        // light under the same ink.
        func fillGround() {
            var c = next()
            for i in 0..<size {
                if i % 6 == 0 { c = next() & 0xFF_FFFF }
                unsafe kernel[i] = c
                unsafe reference[i] = c
            }
        }
        var colors = true, texts = true
        for count in 0...40 {
            for offset in [0, 1, 3, 7] as InlineArray<4, Int> {
                let color = next() & 0xFF_FFFF
                for coverageOf in [0, 1, 128, 254, 255, 300] as InlineArray<6, UInt32> {
                    fillGround()
                    unsafe PixelKernels.over(color, coverage: coverageOf, kernel + offset, count)
                    unsafe PixelKernels.Reference.over(color, coverage: coverageOf, reference + offset, count)
                    if !same() { colors = false }
                }
                for (alpha, step) in [(255, 12), (128, 0), (40, 20)] as InlineArray<3, (UInt32, Int)> {
                    fillCoverage()
                    fillGround()
                    let contrast = TextContrast(step: step)
                    unsafe PixelKernels.overText(color, coverage: coverage + 7 - offset, kernel + offset, count,
                                                 alpha: alpha, contrast: contrast)
                    unsafe PixelKernels.Reference.overText(color, coverage: coverage + 7 - offset, reference + offset,
                                                           count, alpha: alpha, contrast: contrast)
                    if !same() { texts = false }
                }
            }
        }
        check(colors, "pixels: over(_:coverage:) agrees with the reference")
        check(texts, "pixels: overText agrees with the reference")
        var fills = true, copies = true, premultiplied = true, straight = true
        for count in 0...40 {
            for offset in [0, 1, 3, 7] as InlineArray<4, Int> {
                let color = next()
                fillTargets()
                unsafe PixelKernels.fill(kernel + offset, count, color)
                unsafe PixelKernels.Reference.fill(reference + offset, count, color)
                if !same() { fills = false }

                fillSource(premultiplied: false)
                fillTargets()
                unsafe PixelKernels.copyOpaque(kernel + offset, source + 3, count)
                unsafe PixelKernels.Reference.copyOpaque(reference + offset, source + 3, count)
                if !same() { copies = false }

                fillSource(premultiplied: true)
                fillTargets()
                unsafe PixelKernels.over(premultiplied: source + offset, kernel + 7 - offset, count)
                unsafe PixelKernels.Reference.over(premultiplied: source + offset, reference + 7 - offset, count)
                if !same() { premultiplied = false }

                fillSource(premultiplied: false)
                fillTargets()
                unsafe PixelKernels.over(straight: source + offset, kernel + offset, count)
                unsafe PixelKernels.Reference.over(straight: source + offset, reference + offset, count)
                if !same() { straight = false }
            }
        }
        check(fills, "pixels: fill agrees with the reference")
        check(copies, "pixels: copyOpaque agrees with the reference")
        check(premultiplied, "pixels: over(premultiplied:) agrees with the reference")
        check(straight, "pixels: over(straight:) agrees with the reference")
        print("swift: pixels passed")
    }
}
