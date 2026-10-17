import CroiRuntime

/// 9gate's codec and transport (D77, D78) built as Embedded Swift and run
/// on the target: intro(5)'s bytes for a walk, read back and refused
/// short, a stat through and back, and cacophony's Noise IK vector, both
/// sides, to its handshake hash and first transport message. GateTests
/// runs all of them, every vector and 9front's fcall(2) on the host.
enum GateSuite {
    static func run() {
        messages()
        noise()
        print("swift: gate passed")
    }

    static func messages() {
        let walk = Message(tag: 1, .twalk(fid: 2, newfid: 3, names: ["a", "bc"]))
        let bytes: [UInt8] = [24, 0, 0, 0, 110, 1, 0, 2, 0, 0, 0, 3, 0, 0, 0, 2, 0, 1, 0, 0x61, 2, 0, 0x62, 0x63]
        check(walk.encode() == bytes, "9p: a walk's bytes")
        check(Message.decode(bytes)?.encode() == bytes, "9p: read back")
        check(Message.decode(Array(bytes.dropLast())) == nil, "9p: refused short")
        let dir = Dir(qid: Qid(type: QidType.dir, path: 7), mode: DirMode.dir | 0o755, name: "net", uid: "glenda")
        let stat = dir.encode() ?? []
        check(Dir.decode(stat)?.encode() == stat, "9p: a stat")
        let reply = Message(tag: 1, .rstat(stat: stat)).encode() ?? []
        check(Message.decode(reply)?.encode() == reply, "9p: Rstat")
    }

    static func noise() {
        let initiatorStatic: [UInt8] = [
            0xe6, 0x1e, 0xf9, 0x91, 0x9c, 0xde, 0x45, 0xdd, 0x5f, 0x82, 0x16, 0x64, 0x04, 0xbd, 0x08, 0xe3,
            0x8b, 0xce, 0xb5, 0xdf, 0xdf, 0xde, 0xd0, 0xa3, 0x4c, 0x8d, 0xf7, 0xed, 0x54, 0x22, 0x14, 0xd1]
        let initiatorEphemeral: [UInt8] = [
            0x89, 0x3e, 0x28, 0xb9, 0xdc, 0x6c, 0xa8, 0xd6, 0x11, 0xab, 0x66, 0x47, 0x54, 0xb8, 0xce, 0xb7,
            0xba, 0xc5, 0x11, 0x73, 0x49, 0xa4, 0x43, 0x9a, 0x6b, 0x05, 0x69, 0xda, 0x97, 0x7c, 0x46, 0x4a]
        let responderStatic: [UInt8] = [
            0x4a, 0x3a, 0xcb, 0xfd, 0xb1, 0x63, 0xde, 0xc6, 0x51, 0xdf, 0xa3, 0x19, 0x4d, 0xec, 0xe6, 0x76,
            0xd4, 0x37, 0x02, 0x9c, 0x62, 0xa4, 0x08, 0xb4, 0xc5, 0xea, 0x91, 0x14, 0x24, 0x6e, 0x48, 0x93]
        let responderEphemeral: [UInt8] = [
            0xbb, 0xdb, 0x4c, 0xdb, 0xd3, 0x09, 0xf1, 0xa1, 0xf2, 0xe1, 0x45, 0x69, 0x67, 0xfe, 0x28, 0x8c,
            0xad, 0xd6, 0xf7, 0x12, 0xd6, 0x5d, 0xc7, 0xb7, 0x79, 0x3d, 0x5e, 0x63, 0xda, 0x6b, 0x37, 0x5b]
        let hash: [UInt8] = [
            0x0b, 0x0f, 0x68, 0xfb, 0x0c, 0x27, 0xe0, 0x3c, 0xe9, 0xb9, 0x75, 0x65, 0x99, 0x5e, 0xd4, 0x83,
            0x8c, 0xc0, 0x58, 0x1b, 0x76, 0x2e, 0xf7, 0x2b, 0x06, 0x2f, 0x6a, 0x54, 0x64, 0x19, 0xfa, 0xd7]
        let prologue = Array("John Galt".utf8)
        let ik = StaticKey(privateKey: initiatorStatic), rk = StaticKey(privateKey: responderStatic)
        var i = Handshake(initiator: ik, remote: rk.publicKey, ephemeral: initiatorEphemeral, prologue: prologue)
        var r = Handshake(responder: rk, ephemeral: responderEphemeral, prologue: prologue)
        let first = i.write(Array("Ludwig von Mises".utf8)) ?? []
        check(first.prefix(8) == [0xca, 0x35, 0xde, 0xf5, 0xae, 0x56, 0xce, 0xc3], "noise: message 1")
        check(r.read(first) == Array("Ludwig von Mises".utf8) && r.remoteStatic == ik.publicKey,
              "noise: the responder reads it, and knows the initiator")
        let second = r.write(Array("Murray Rothbard".utf8)) ?? []
        check(second.prefix(8) == [0x95, 0xeb, 0xc6, 0x0d, 0x2b, 0x1f, 0xa6, 0x72], "noise: message 2")
        check(i.read(second) == Array("Murray Rothbard".utf8), "noise: the initiator reads it")
        check(i.hash == hash && r.hash == hash, "noise: the handshake hash")
        guard var a = i.split(), var b = r.split() else { return check(false, "noise: the sessions") }
        let sealed = a.seal(Array("F. A. Hayek".utf8)) ?? []
        check(sealed.prefix(8) == [0x05, 0x0e, 0x9f, 0x3c, 0x8f, 0xac, 0x16, 0xb6], "noise: transport")
        check(b.open(sealed) == Array("F. A. Hayek".utf8) && b.open(sealed) == nil, "noise: opened once")
    }
}
