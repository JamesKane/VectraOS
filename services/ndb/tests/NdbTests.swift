// SPDX-License-Identifier: BSD-3-Clause

// Names (ndb(8)): the database's entries, searches and ipinfo; DNS
// messages each way; the resolver against a server it is given, its
// cache, CNAMEs, failures and TCP; then cs and dns on host A, B a name
// server, used as a client would, through dial(2) and by hand.

import IPC
import Ndb
import Net
import Node
import Synchronization
import Sys
import Testing

// MARK: The database

let sample = """
  # a comment at the margin doesn't end an entry
  sys=gate ip=10.0.2.2
  \tdom=gate.lab
  # nor does one here
  \tvendor="a b" flag
  ipnet=lab ip=10.0.2.0 ipmask=255.255.255.0
  \tipgw=10.0.2.2 dns=10.0.2.3 dns=10.0.2.4
  ipnet=wide ip=10.0.0.0 ipmask=255.0.0.0
  \tdns=1.1.1.1 auth=keeper smtp=mail
  sys=pc ip=10.0.2.15 smtp=local # trailing comment
  tcp=echo port=7
  """

@Test func entriesSpanTheirIndentedLines() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  #expect(db.entries.count == 5)
  let gate = db.entries[0]
  #expect(gate.pairs.map { $0.attr } == ["sys", "ip", "dom", "vendor", "flag"])
  #expect(gate.value("vendor") == "a b")
  #expect(gate.value("flag") == "")
  #expect(gate.lines == ["sys=gate ip=10.0.2.2", "dom=gate.lab", "vendor=\"a b\" flag="])
  #expect(db.entries[3].value("smtp") == "local")
}

@Test func searchesAndValues() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  #expect(db.search("ip", "10.0.2.2").count == 1)
  #expect(db.value("sys", "gate", want: "dom") == "gate.lab")
  #expect(db.value("tcp", "echo", want: "port") == "7")
  #expect(db.value("tcp", "chargen", want: "port") == nil)
  // The value on the matching line first.
  let two = NdbDatabase(parsing: Array("sys=a ip=1.1.1.1\n\tsys=b ip=2.2.2.2\n".utf8))
  #expect(two.value("sys", "b", want: "ip") == "2.2.2.2")
  #expect(NdbDatabase(parsing: Array("database=\n\tfile=/lib/ndb/local\n\tfile=/lib/ndb/common\n".utf8)).files
    == ["/lib/ndb/local", "/lib/ndb/common"])
}

@Test func ipinfoInheritsFromTheMostSpecificNetwork() {
  let db = NdbDatabase(parsing: Array(sample.utf8))
  let info = db.ipinfo("10.0.2.15", ["smtp", "dns", "auth", "ipgw", "none"])
  // Its own smtp; the /24's name servers, both; the /8's auth.
  #expect(info.map { "\($0.attr)=\($0.value)" } == ["smtp=local", "dns=10.0.2.3", "dns=10.0.2.4", "ipgw=10.0.2.2",
                                                     "auth=keeper"])
  #expect(db.ipinfo("10.9.9.9", ["dns"]).map { $0.value } == ["1.1.1.1"])
  #expect(db.ipinfo("192.168.0.1", ["dns"]).isEmpty)
}

@Test func ipattrSaysWhatANameIs() {
  #expect(ipattr("10.0.2.2") == "ip")
  #expect(ipattr("fe80::1") == "ip")
  #expect(ipattr("plan9.bell-labs.com") == "dom")
  #expect(ipattr("gate") == "sys")
  #expect(ipattr("deadbeef") == "sys")
}

// MARK: Messages

@Test func aQueryOnTheWire() throws {
  let q = try #require(DNSMessage.query(id: 0xBEEF, "a.bc", DNSType.a).encode())
  #expect(q == [0xBE, 0xEF, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0x61, 2, 0x62, 0x63, 0, 0, 1, 0, 1])
  #expect(DNSMessage.query(id: 1, "a..b", DNSType.a).encode() == nil)
  #expect(DNSMessage.query(id: 1, String(repeating: "x", count: 64), DNSType.a).encode() == nil)
}

@Test func aReplyWithCompressedNames() throws {
  // Question a.bc A; answers a.bc CNAME x.bc (pointing back) and x.bc A.
  let reply: [UInt8] = [0xBE, 0xEF, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0,
                        1, 0x61, 2, 0x62, 0x63, 0, 0, 1, 0, 1,
                        0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 4, 1, 0x78, 0xC0, 14,
                        0xC0, 34, 0, 1, 0, 1, 0, 0, 1, 0, 0, 4, 10, 0, 0, 2]
  let m = try #require(DNSMessage(decoding: reply))
  #expect(m.isResponse && m.rcode == DNSMessage.ok)
  #expect(m.questions == [DNSQuestion("a.bc", DNSType.a)])
  #expect(m.answers == [DNSRecord("a.bc", DNSType.cname, ttl: 60, .name("x.bc")),
                        DNSRecord("x.bc", DNSType.a, ttl: 256, .address(IPv6Address(mapping: IPv4Address(10, 0, 0, 2))))])
  #expect(m.answers[1].text == "x.bc ip\t10.0.0.2")
  #expect(m.answers[1].pairs == "dom=x.bc ip=10.0.0.2")
  #expect(m.answers[0].pairs == "dom=a.bc cname=x.bc")
  // A pointer forward, or to itself, never ends: refused.
  var loop = reply
  loop[22] = 0xC0
  loop[23] = 22
  #expect(DNSMessage(decoding: loop) == nil)
  #expect(DNSMessage(decoding: Array(reply[..<30])) == nil)
}

@Test func messagesGoBothWays() throws {
  var m = DNSMessage(id: 7, flags: DNSMessage.response | DNSMessage.nameError)
  m.questions = [DNSQuestion("x.test", DNSType.mx)]
  m.answers = [DNSRecord("x.test", DNSType.mx, ttl: 5, .mx(preference: 10, exchange: "mail.test")),
               DNSRecord("x.test", DNSType.txt, ttl: 5, .strings([Array("hi".utf8)])),
               DNSRecord("x.test", DNSType.aaaa, ttl: 5, .address(IPv6Address("2001:db8::1")!)),
               DNSRecord("x.test", DNSType.srv, ttl: 5, .srv(priority: 1, weight: 2, port: 564, target: "fs.test"))]
  m.authority = [DNSRecord("test", DNSType.soa, ttl: 9, .soa(mname: "ns.test", rname: "root.test", serial: 1,
                                                             refresh: 2, retry: 3, expire: 4, minimum: 5))]
  let bytes = try #require(m.encode())
  let back = try #require(DNSMessage(decoding: bytes))
  #expect(back == m)
  #expect(back.answers.map { $0.text } == ["x.test mx\t10 mail.test", "x.test txt\thi", "x.test ipv6\t2001:db8::1",
                                           "x.test srv\t1 2 564 fs.test"])
  #expect(back.authority[0].text == "test soa\tns.test root.test 1 2 3 4 5")
}

@Test func reverseNames() {
  #expect(reverseName(IPv6Address(mapping: IPv4Address(10, 0, 2, 15))) == "15.2.0.10.in-addr.arpa")
  #expect(reverseName(IPv6Address("2001:db8::1")!).hasPrefix("1.0.0.0.0.0.0.0."))
  #expect(reverseName(IPv6Address("2001:db8::1")!).hasSuffix(".8.b.d.0.1.0.0.2.ip6.arpa"))
}

// MARK: The resolver

/// A server the resolver is given: what it answers each query with,
/// and what it was asked.
final class Fake: @unchecked Sendable {
  let lock = Lock()
  var asked: [(server: String, name: String, tcp: Bool)] = []
  var reply: (String, DNSMessage, Bool) -> DNSMessage? = { _, _, _ in nil }

  var exchange: Resolver.Exchange {
    return { [self] server, query, tcp, _ in
      guard let q = DNSMessage(decoding: query) else { return nil }
      let r = lock.withLock { () -> DNSMessage? in
        asked.append((server, q.questions[0].name, tcp))
        return reply(server, q, tcp)
      }
      return r?.encode()
    }
  }

  func resolver(_ servers: [String] = ["10.0.0.53"]) -> Resolver {
    let n = Atomic<UInt16>(0)
    return Resolver(servers: { servers }, exchange: exchange, random: { n.add(1, ordering: .relaxed).newValue })
  }
}

func respond(_ q: DNSMessage, _ rcode: UInt16 = 0, _ answers: [DNSRecord] = [], flags: UInt16 = 0) -> DNSMessage {
  var r = DNSMessage(id: q.id, flags: DNSMessage.response | rcode | flags)
  r.questions = q.questions
  r.answers = answers
  return r
}

let ten = DNSData.address(IPv6Address(mapping: IPv4Address(10, 0, 0, 2)))

@Test func answersAreKeptForTheirTTL() {
  let fake = Fake()
  fake.reply = { _, q, _ in respond(q, 0, [DNSRecord(q.questions[0].name, DNSType.a, ttl: 300, ten)]) }
  let r = fake.resolver()
  #expect(r.lookup("Bee.Test", DNSType.a) == .success([DNSRecord("Bee.Test", DNSType.a, ttl: 300, ten)]))
  #expect(r.lookup("bee.test", DNSType.a).map { $0.count } == .success(1))
  #expect(fake.asked.count == 1)
  // Kept for no time: asked again.
  fake.reply = { _, q, _ in respond(q, 0, [DNSRecord(q.questions[0].name, DNSType.a, ttl: 0, ten)]) }
  _ = r.lookup("zero.test", DNSType.a)
  _ = r.lookup("zero.test", DNSType.a)
  #expect(fake.asked.count == 3)
  r.flush()
  _ = r.lookup("bee.test", DNSType.a)
  #expect(fake.asked.count == 4)
}

@Test func cnamesAreFollowed() {
  let fake = Fake()
  fake.reply = { _, q, _ in
    switch q.questions[0].name {
    case "www.test": respond(q, 0, [DNSRecord("www.test", DNSType.cname, ttl: 60, .name("host.test")),
                                    DNSRecord("host.test", DNSType.a, ttl: 60, ten)])
    case "far.test": respond(q, 0, [DNSRecord("far.test", DNSType.cname, ttl: 60, .name("host.test"))])
    case "loop.test": respond(q, 0, [DNSRecord("loop.test", DNSType.cname, ttl: 60, .name("loop2.test"))])
    case "loop2.test": respond(q, 0, [DNSRecord("loop2.test", DNSType.cname, ttl: 60, .name("loop.test"))])
    default: respond(q, 0, [DNSRecord(q.questions[0].name, DNSType.a, ttl: 60, ten)])
    }
  }
  let r = fake.resolver()
  #expect(r.lookup("www.test", DNSType.a) == .success([DNSRecord("host.test", DNSType.a, ttl: 60, ten)]))
  // far.test's target kept from www.test's answer: no second query.
  #expect(r.lookup("far.test", DNSType.a) == .success([DNSRecord("host.test", DNSType.a, ttl: 60, ten)]))
  #expect(fake.asked.map { $0.name } == ["www.test", "far.test"])
  // The CNAME itself, asked for.
  #expect(r.lookup("www.test", DNSType.cname).map { $0.map { $0.data } } == .success([.name("host.test")]))
  #expect(r.lookup("loop.test", DNSType.a) == .failure(.failed))
}

@Test func failuresAreKeptAndSaid() {
  let fake = Fake()
  fake.reply = { server, q, _ in
    if server == "10.0.0.1" { return respond(q, DNSMessage.serverFailure) }
    if q.questions[0].name == "none.test" {
      var r = respond(q, DNSMessage.nameError)
      r.authority = [DNSRecord("test", DNSType.soa, ttl: 600, .soa(mname: "a", rname: "b", serial: 1, refresh: 1,
                                                                    retry: 1, expire: 1, minimum: 30))]
      return r
    }
    return respond(q)  // the name is there; no such records
  }
  let r = fake.resolver(["10.0.0.1", "10.0.0.2"])
  #expect(r.lookup("none.test", DNSType.a) == .failure(.noName))
  // The first server failed, the second said so: one of each.
  #expect(fake.asked.map { $0.server } == ["10.0.0.1", "10.0.0.2"])
  // No such name: none of any type, kept.
  #expect(r.lookup("none.test", DNSType.mx) == .failure(.noName))
  #expect(fake.asked.count == 2)
  #expect(r.lookup("some.test", DNSType.aaaa) == .failure(.noRecords(0)))
  #expect(DNSFailure.noRecords(0).text == "resource does not exist; negrcode 0")
  // No server: a failure, at once.
  #expect(fake.resolver([]).lookup("x.test", DNSType.a) == .failure(.failed))
}

@Test func aTruncatedReplyIsAskedOverTCP() {
  let fake = Fake()
  fake.reply = { _, q, tcp in
    tcp ? respond(q, 0, [DNSRecord("big.test", DNSType.a, ttl: 60, ten)]) : respond(q, flags: DNSMessage.truncated)
  }
  #expect(fake.resolver().lookup("big.test", DNSType.a).map { $0.count } == .success(1))
  #expect(fake.asked.map { $0.tcp } == [false, true])
}

@Test func aSilentServerIsAskedThreeTimesThenTheNext() {
  let fake = Fake()
  fake.reply = { server, q, _ in server == "10.0.0.2" ? respond(q, 0, [DNSRecord("x.test", DNSType.a, ttl: 60, ten)]) : nil }
  #expect(fake.resolver(["10.0.0.1"]).lookup("x.test", DNSType.a) == .failure(.failed))
  #expect(fake.asked.count == 3)
  #expect(fake.resolver(["10.0.0.1", "10.0.0.2"]).lookup("x.test", DNSType.a).map { $0.count } == .success(1))
  #expect(fake.asked.suffix(2).map { $0.server } == ["10.0.0.1", "10.0.0.2"])
}

// MARK: cs and dns on a host

@Test func dnsAnswersAsPlan9sDoes() throws {
  try pair { a, _, _, server in
    #expect(ask(a.ns, "/net/dns", "bee.test ip") == .success(["bee.test ip\t10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "!bee.test ip") == .success(["dom=bee.test ip=10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "bee.test. ip") == .success(["bee.test ip\t10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "alias.test ip") == .success(["bee.test ip\t10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "far.test ip") == .success(["other.test ip\t10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "v6.test ipv6") == .success(["v6.test ipv6\tfe80::2"]))
    #expect(ask(a.ns, "/net/dns", "big.test ip") == .success(["big.test ip\t10.0.0.2"]))
    #expect(server.tcpQueries.load(ordering: .relaxed) == 1)
    #expect(ask(a.ns, "/net/dns", "nobody.test ip") == .failure(.notFound))
    #expect(ask(a.ns, "/net/dns", "v6.test ip") == .failure(.notFound))
    #expect(ask(a.ns, "/net/dns", "bee.test") == .failure(.invalid))
    #expect(ask(a.ns, "/net/dns", "bee.test bogus") == .failure(.invalid))
    // Kept: asked again, nothing sent.
    let sent = server.queries.load(ordering: .relaxed)
    #expect(ask(a.ns, "/net/dns", "bee.test ip") == .success(["bee.test ip\t10.0.0.2"]))
    #expect(ask(a.ns, "/net/dns", "nobody.test ip") == .failure(.notFound))
    #expect(server.queries.load(ordering: .relaxed) == sent)
    // An address's ptr is asked by its reverse name.
    _ = ask(a.ns, "/net/dns", "10.0.0.9 ptr")
    #expect(server.asked.withLock { $0.last } == "9.0.0.10.in-addr.arpa")
  }
}

@Test func csTranslatesAsPlan9sDoes() throws {
  try pair { a, _, _, _ in
    // By the database: a sys name, a service name.
    #expect(ask(a.ns, "/net/cs", "tcp!bee!echo") == .success(["/net/tcp/clone 10.0.0.2!7"]))
    #expect(ask(a.ns, "/net/cs", "net!bee!7") == .success(["/net/tcp/clone 10.0.0.2!7"]))
    #expect(ask(a.ns, "/net/cs", "udp!bee!domain") == .success(["/net/udp/clone 10.0.0.2!53"]))
    // By dns: a domain name.
    #expect(ask(a.ns, "/net/cs", "tcp!alias.test!7") == .success(["/net/tcp/clone 10.0.0.2!7"]))
    // Addresses, any, our ipinfo's, and the rest passed on.
    #expect(ask(a.ns, "/net/cs", "tcp!10.0.0.9!80") == .success(["/net/tcp/clone 10.0.0.9!80"]))
    #expect(ask(a.ns, "/net/cs", "tcp!*!echo") == .success(["/net/tcp/clone 7"]))
    #expect(ask(a.ns, "/net/cs", "tcp!$auth!564") == .success(["/net/tcp/clone 10.0.0.2!564"]))
    #expect(ask(a.ns, "/net/cs", "tcp!bee!7!rem") == .success(["/net/tcp/clone 10.0.0.2!7!rem"]))
    #expect(ask(a.ns, "/net/cs", "ether0!ff!0806") == .success(["/net/ether0/clone ff!0806"]))
    // An IPv6 address, and we have none: left out.
    #expect(ask(a.ns, "/net/cs", "tcp!six!7") == .failure(.notFound))
    #expect(ask(a.ns, "/net/cs", "tcp!nobody.test!7") == .failure(.notFound))
    #expect(ask(a.ns, "/net/cs", "tcp!bee!chargen") == .failure(.invalid))
    // The database itself.
    #expect(ask(a.ns, "/net/cs", "!sys=bee") == .success(["sys=bee ip=10.0.0.2"]))
    #expect(ask(a.ns, "/net/cs", "!port=7 tcp=*") == .success(["tcp=echo port=7"]))
    #expect(ask(a.ns, "/net/cs", "!ipinfo dns auth") == .success(["dns=10.0.0.2 auth=bee"]))
    #expect(ask(a.ns, "/net/cs", "!sys=nobody") == .failure(.notFound))
  }
}

@Test func dialCallsByName() throws {
  try pair { a, _, _, _ in
    var c = try a.ns.dial("tcp!bee.test!echo")
    #expect(c.dir == "/net/tcp/0")
    #expect(try c.data.write(offset: 0, Array("hello".utf8)) == 5)
    #expect(try c.data.read(offset: 0, max: 64) == Array("hello".utf8))
    #expect(throws: DialError("can't translate address")) { _ = try a.ns.dial("tcp!nobody.test!7") }
    #expect(throws: DialError("can't translate service")) { _ = try a.ns.dial("tcp!bee!chargen") }
    // Announced by name, through cs: its port alone.
    let announced = try a.ns.announce("tcp!*!echo")
    #expect(text(a.ns, announced.dir + "/local") == "::!7\n")
  }
}

func text(_ ns: Namespace, _ path: String) -> String {
  guard var f = try? ns.open(path), let t = try? f.readText() else { return "" }
  return t
}
