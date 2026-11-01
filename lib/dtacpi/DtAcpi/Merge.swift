import Fdt

/// Which tree describes a machine whose firmware gives a devicetree, and
/// that tree with what only firmware knows copied in (D154 item 7). The
/// loader picks one of the ESP's trees, ours, by the firmware tree's root
/// `compatible`, or where firmware names the SoC and not the board, by a
/// known firmware identity; then merges a fixed list of values into it.
/// It allocates nothing.
public enum Devicetree {
    /// Firmware whose root `compatible` names no board of ours: its first
    /// root compatible and its `model`, and the root compatible of our tree
    /// for that board. An entry joins when a board needs it.
    static let identities: InlineArray<1, (compatible: StaticString, model: StaticString, ours: StaticString)> = [
        // The Orange Pi RV2's U-Boot 2022.10ky: "ky,x1", "riscv".
        ("ky,x1", "ky x1 orangepi-rv2 board", "xunlong,orangepi-rv2"),
    ]

    public enum Match { case compatible, identity }

    /// Whether `ours` is the tree for the machine `firmware` describes: its
    /// root compatible holds the firmware's first, or the firmware is a
    /// known identity whose board `ours` is.
    public static func matches(_ ours: borrowing Fdt, firmware: borrowing Fdt) -> Match? {
        guard let ourRoot = ours.root, let theirRoot = firmware.root,
              let theirs = firmware.property(theirRoot, "compatible"),
              ours.property(ourRoot, "compatible") != nil
        else { return nil }
        var end = theirs.lowerBound
        while end < theirs.upperBound, firmware.byte(end) != 0 { end += 1 }
        if end > theirs.lowerBound, containsString(ours, ourRoot, "compatible", firmware, theirs.lowerBound..<end) {
            return .compatible
        }
        for i in identities.indices {
            let id = identities[i]
            if firmware.contains(theirRoot, "compatible", id.compatible),
               let model = firmware.property(theirRoot, "model"), firmware.stringEquals(model.lowerBound, id.model),
               ours.contains(ourRoot, "compatible", id.ours) {
                return .identity
            }
        }
        return nil
    }

    /// `ours` written into `out` with, from `firmware`: the root's
    /// `serial-number`; `/chosen`'s `kaslr-seed` and `rng-seed`; each
    /// `ethernet@...` node's `local-mac-address` and `mac-address`; a
    /// `/cpus/cpu@...` node's `status` where firmware disabled it (a binned
    /// part); and `/reserved-memory`, if ours has none, with only the
    /// entries `keep` accepts (the UEFI memory map's check). With
    /// `network`, the board's addresses from where firmware keeps them
    /// outside its tree (the Orange Pi RV2's EEPROM, Onie), the
    /// `local-mac-address` of each node our `/aliases` names `ethernet<N>`,
    /// the base plus N, where firmware's tree gives that node none. Returns
    /// the merged tree's size, or nil if it doesn't fit.
    public static func merge(
        _ ours: borrowing Fdt, firmware: borrowing Fdt, keep: (_ address: UInt64, _ size: UInt64) -> Bool,
        network: NetworkAddresses? = nil, into out: inout MutableRawSpan
    ) -> Int? {
        guard let root = ours.root else { return nil }
        var writer = FdtWriter(capacity: out.byteCount)
        var given = Given(network: network)
        if let network, let aliases = ours.node("/aliases") {
            for n in 0..<min(network.count, given.nodes.count) {
                let path: Range<Int>? = switch n {
                case 0: ours.property(aliases, "ethernet0")
                case 1: ours.property(aliases, "ethernet1")
                case 2: ours.property(aliases, "ethernet2")
                default: ours.property(aliases, "ethernet3")
                }
                if let path { given.nodes[n] = ours.node(atPath: path) ?? -1 }
            }
        }
        emit(ours, root, depth: 0, parentIsCpus: false, firmware, keep, given, &writer, &out)
        return writer.finish(into: &out)
    }

    // MARK: Writing

    /// What the loader learned from firmware other than its tree.
    struct Given {
        var network: NetworkAddresses?
        /// Our nodes `ethernet0` to `ethernet3` name (-1: none).
        var nodes = InlineArray<4, Int>(repeating: -1)

        /// The address for `node`, if an alias names it.
        func address(_ node: Int) -> InlineArray<6, UInt8>? {
            guard let network else { return nil }
            for n in 0..<nodes.count where nodes[n] == node { return network.address(n) }
            return nil
        }
    }

    private static func emit(
        _ ours: borrowing Fdt, _ node: Int, depth: Int, parentIsCpus: Bool, _ firmware: borrowing Fdt,
        _ keep: (UInt64, UInt64) -> Bool, _ given: Given, _ w: inout FdtWriter, _ out: inout MutableRawSpan
    ) {
        let name = ours.name(of: node)
        // The firmware's node this one takes values from, and which.
        var theirs: Int? = nil
        var kind = Kind.plain
        if depth == 0 {
            theirs = firmware.root
            kind = .root
        } else if depth == 1, ours.equals(name, "chosen") {
            theirs = firmware.node("/chosen")
            kind = .chosen
        } else if parentIsCpus, startsWith(ours, name, "cpu@") {
            if let cpus = firmware.node("/cpus") { theirs = child(firmware, cpus, named: name, in: ours) }
            kind = .cpu
        } else if startsWith(ours, name, "ethernet@") {
            if let top = firmware.root { theirs = find(firmware, top, named: name, in: ours, depth: 0) }
            kind = .ethernet
        }

        // The board's network address, where firmware's tree gives this
        // node none.
        var theirsHaveAddress = false
        if let theirs { theirsHaveAddress = firmware.has(theirs, "local-mac-address") || firmware.has(theirs, "mac-address") }
        let network = theirsHaveAddress ? nil : given.address(node)
        w.beginNode(ours.bytes.extracting(name), into: &out)
        var p = ours.firstProperty(of: node)
        while let at = p {
            p = ours.nextProperty(after: at)
            guard let (pname, value) = ours.property(at: at) else { continue }
            if let theirs, replaced(kind, ours, pname, firmware, theirs) { continue }
            if network != nil, ours.equals(pname, "local-mac-address") || ours.equals(pname, "mac-address") { continue }
            w.property(ours.bytes.extracting(pname), ours.bytes.extracting(value), into: &out)
        }
        if let theirs { copyFixups(kind, firmware, theirs, &w, &out) }
        if let network {
            let label: StaticString = "local-mac-address"
            var bytes = InlineArray<17, UInt8>(repeating: 0)
            for i in 0..<17 { bytes[i] = unsafe label.utf8Start[i] }
            w.property(bytes.span.bytes, network.span.bytes, into: &out)
        }

        let isCpus = depth == 1 && ours.equals(name, "cpus")
        var hasChosen = false, hasReserved = false
        var c = ours.firstChild(of: node)
        while let child = c {
            c = ours.nextSibling(of: child)
            if depth == 0 {
                if ours.equals(ours.name(of: child), "chosen") { hasChosen = true }
                if ours.equals(ours.name(of: child), "reserved-memory") { hasReserved = true }
            }
            emit(ours, child, depth: depth + 1, parentIsCpus: isCpus, firmware, keep, given, &w, &out)
        }
        if depth == 0 {
            if !hasReserved, let reserved = firmware.node("/reserved-memory") {
                copyReserved(firmware, reserved, keep, &w, &out)
            }
            if !hasChosen, let chosen = firmware.node("/chosen"),
               firmware.has(chosen, "kaslr-seed") || firmware.has(chosen, "rng-seed") {
                w.beginNode(firmware.bytes.extracting(firmware.name(of: chosen)), into: &out)
                copyFixups(.chosen, firmware, chosen, &w, &out)
                w.endNode(into: &out)
            }
        }
        w.endNode(into: &out)
    }

    enum Kind { case plain, root, chosen, cpu, ethernet }

    /// Whether our property `name` gives way to the firmware node's.
    private static func replaced(
        _ kind: Kind, _ ours: borrowing Fdt, _ name: Range<Int>, _ firmware: borrowing Fdt, _ theirs: Int
    ) -> Bool {
        switch kind {
        case .root: return ours.equals(name, "serial-number") && firmware.has(theirs, "serial-number")
        case .chosen:
            return (ours.equals(name, "kaslr-seed") && firmware.has(theirs, "kaslr-seed"))
                || (ours.equals(name, "rng-seed") && firmware.has(theirs, "rng-seed"))
        case .ethernet:
            let theirsHave = firmware.has(theirs, "local-mac-address") || firmware.has(theirs, "mac-address")
            return theirsHave && (ours.equals(name, "local-mac-address") || ours.equals(name, "mac-address"))
        case .cpu: return ours.equals(name, "status") && !firmware.isEnabled(theirs)
        case .plain: return false
        }
    }

    /// The firmware node's values of `kind`'s list.
    private static func copyFixups(
        _ kind: Kind, _ firmware: borrowing Fdt, _ theirs: Int, _ w: inout FdtWriter, _ out: inout MutableRawSpan
    ) {
        var p = firmware.firstProperty(of: theirs)
        while let at = p {
            p = firmware.nextProperty(after: at)
            guard let (name, value) = firmware.property(at: at) else { continue }
            let wanted: Bool
            switch kind {
            case .root: wanted = firmware.equals(name, "serial-number")
            case .chosen: wanted = firmware.equals(name, "kaslr-seed") || firmware.equals(name, "rng-seed")
            case .ethernet: wanted = firmware.equals(name, "local-mac-address") || firmware.equals(name, "mac-address")
            case .cpu: wanted = firmware.equals(name, "status") && !firmware.isEnabled(theirs)
            case .plain: wanted = false
            }
            if wanted { w.property(firmware.bytes.extracting(name), firmware.bytes.extracting(value), into: &out) }
        }
    }

    /// Firmware's `/reserved-memory`, its entries `keep` refuses left out,
    /// and no phandles (ours number their own).
    private static func copyReserved(
        _ firmware: borrowing Fdt, _ node: Int, _ keep: (UInt64, UInt64) -> Bool,
        _ w: inout FdtWriter, _ out: inout MutableRawSpan
    ) {
        w.beginNode(firmware.bytes.extracting(firmware.name(of: node)), into: &out)
        copyProperties(firmware, node, &w, &out)
        var c = firmware.firstChild(of: node)
        while let child = c {
            c = firmware.nextSibling(of: child)
            if let reg = firmware.reg(child), !keep(reg.address, reg.size) { continue }
            w.beginNode(firmware.bytes.extracting(firmware.name(of: child)), into: &out)
            copyProperties(firmware, child, &w, &out)
            w.endNode(into: &out)
        }
        w.endNode(into: &out)
    }

    private static func copyProperties(
        _ fdt: borrowing Fdt, _ node: Int, _ w: inout FdtWriter, _ out: inout MutableRawSpan
    ) {
        var p = fdt.firstProperty(of: node)
        while let at = p {
            p = fdt.nextProperty(after: at)
            guard let (name, value) = fdt.property(at: at),
                  !fdt.equals(name, "phandle"), !fdt.equals(name, "linux,phandle")
            else { continue }
            w.property(fdt.bytes.extracting(name), fdt.bytes.extracting(value), into: &out)
        }
    }

    // MARK: Bytes across two trees

    private static func sameBytes(_ a: borrowing Fdt, _ ra: Range<Int>, _ b: borrowing Fdt, _ rb: Range<Int>) -> Bool {
        guard ra.count == rb.count else { return false }
        for i in 0..<ra.count where a.byte(ra.lowerBound + i) != b.byte(rb.lowerBound + i) { return false }
        return true
    }

    private static func startsWith(_ fdt: borrowing Fdt, _ range: Range<Int>, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard range.count >= n else { return false }
        return fdt.equals(range.lowerBound..<(range.lowerBound + n), prefix)
    }

    /// The first node under `node`, in document order, whose name is `name`
    /// in `other`.
    private static func find(_ fdt: borrowing Fdt, _ node: Int, named name: Range<Int>, in other: borrowing Fdt, depth: Int) -> Int? {
        guard depth < 32 else { return nil }
        var c = fdt.firstChild(of: node)
        while let child = c {
            if sameBytes(fdt, fdt.name(of: child), other, name) { return child }
            if let found = find(fdt, child, named: name, in: other, depth: depth + 1) { return found }
            c = fdt.nextSibling(of: child)
        }
        return nil
    }

    /// `parent`'s child in `fdt` whose name is `name` in `other`.
    private static func child(_ fdt: borrowing Fdt, _ parent: Int, named name: Range<Int>, in other: borrowing Fdt) -> Int? {
        var c = fdt.firstChild(of: parent)
        while let child = c {
            if sameBytes(fdt, fdt.name(of: child), other, name) { return child }
            c = fdt.nextSibling(of: child)
        }
        return nil
    }

    /// Whether `fdt`'s string-list property `property` of `node` holds the
    /// string at `range` of `other`.
    private static func containsString(
        _ fdt: borrowing Fdt, _ node: Int, _ property: StaticString, _ other: borrowing Fdt, _ range: Range<Int>
    ) -> Bool {
        guard let list = fdt.property(node, property) else { return false }
        var start = list.lowerBound
        while start < list.upperBound {
            var end = start
            while end < list.upperBound, fdt.byte(end) != 0 { end += 1 }
            if sameBytes(fdt, start..<end, other, range) { return true }
            start = end + 1
        }
        return false
    }
}
