# Web: the federated networks as files, and a reader with two-way links

**Written before the code.** Every plan before this one stops at the
edge of the fleet. `docs/FLEET.md` gives the machine a network and a
name for itself, and `docs/GHOST.md` dials one host in the cloud. This
is the plan for the rest of the world: the pages, the posts, the mail
and the rooms a person reads every day. And a program to read them in.
`docs/HANDOFF.md` section 6 points here.

Two people said what a web should be before there was one. Ted Nelson
asked for links that go both ways, quotes that stay live, and addresses
that outlast an edit. Joe Armstrong asked for three webs at once. One of
names, one of ids that follow a thing through its changes, and one of
hashes that name content exactly. The web that won has one-way links,
copied quotes and names that rot.

The popular federated networks have rebuilt most of what the two asked
for, one piece each, and none of them is the whole. This plan takes them
as they are. No protocol is invented here. What is built is the one
thing every one of them lacks and this tree has, a namespace. In it a
network is a directory, a message is a directory, and a union of them is
a timeline.

**What a person sees.** A window with a page in it, and beside the page
a column of what points at it. The replies, the mentions, the quotes,
and the pages on this machine that linked there. One timeline holds the
posts of two social networks and the entries of a dozen feeds, sorted by
time. A mailbox that is a chat, sealed end to end, with Delta Chat users
and plain mail users in it, and a room on Matrix. Every one of those is
a directory, and `ls` reads it.

## 1. What is taken, and from where

**From Ted Nelson, the shape of the reader.** Xanadu's transclusion is a
quote that is the original, shown in place. Its two-way link is one the
target knows about. Its permanent address names content rather than a
position in a file, and a document keeps every version it had. The
transpointing window shows two documents side by side with the
connections drawn between them. Section 5's reader is that window, and
section 3's store is the permanent address.

**From Joe Armstrong, the three webs.** Names for people, and UUIDs so a
thing that changes can be followed. Hashes, so content can be named
exactly and a man in the middle is a checksum that does not tally. The
AT Protocol is all three at once. A handle, a DID under it, and a
repository of records under that, each addressed by the hash of its
bytes. Section 3 gives this machine the web of hashes for everything it
reads, whether or not the network it came from has one.

**From Plan 9, the shape of everything.** `upas/fs` mounted a mailbox as
a directory of numbered directories, one per message. `from`, `date`,
`subject` and `body` are files in it, and each attachment is a directory
under it. That is the message shape here, for mail and for every other
kind of message.

**And from Plan 9, the programs.** `webfs` is HTTP as files, and
`docs/GHOST.md` section 6 already plans it. `mothra` was Tom Duff's
browser of 1995. It drew the text of a page and none of its pictures
until asked, and it is the name here. The `plumber` routes a URL to the
program that reads it.

**From email, as Delta Chat uses it.** The oldest federated network
there is, IMAP and SMTP on every server in the world. OpenPGP is the
seal, and Autocrypt is the key exchange that needs no key server. Delta
Chat made that the secure messenger, and chatmail relays are mail
servers that refuse cleartext and hand out an account in one request. A
person here talks to a Delta Chat user with no bridge, and to a plain
mail user with the seal left off. Section 6 is that.

**From ActivityPub, and from Mastodon.** The W3C standard the fediverse
runs on, in which a reply is an activity delivered to the author's
inbox. That is Nelson's link that comes back, as a standard. Its client
half went unused, and the world's clients speak Mastodon's REST API
instead. The server here speaks that API for a person's own account and
fetches any public actor or object as ActivityPub JSON by its URL.

**From the AT Protocol.** A record is signed, addressed by CID, and held
in a repository the person can move between hosts. A quote post is an
embed by strong reference, URI and CID together, so the reader can fetch
the original and check it. XRPC is JSON over HTTPS with a schema per
method, and the schemas are published. Section 7.

**From Matrix.** The federated room, with end-to-end encryption a third
party may implement and a client-server API that is JSON over HTTPS. Olm
and Megolm today, and MLS the day Matrix finishes it. Section 8.

**From Gemini.** A page is text with a line type per line, the wire is
TLS and nothing else, and a client certificate is an identity. About six
thousand capsules use it and nothing can track a reader on it. It costs
a page of code and it fits this tree's taste exactly.

**From feeds and Webmention.** RSS and Atom are the federated model that
worked first and never stopped. Webmention is a W3C Recommendation that
makes a link two-way with one POST, and the IndieWeb community keeps it
alive. A feed is a directory of messages, and a mention is a message in
`notify/`.

**Kept as it is.** The wire, the namespace, `/srv`, `factotum`, the draw
server, the application contract, and the sandbox rule. Nothing below
this document changes for a machine that never reads a page.

**Not taken.** A JavaScript engine, an app per network, a messenger with
one vendor, and a bridge. A protocol of this tree's own, a pod, IPFS,
and a second chat protocol. Section 2 says why.

## 2. The models this refuses, and what each got wrong

**The browser as an operating system.** A modern browser is a script
engine, a compositor, a sandbox and a process model, which is an
operating system with a worse namespace. The web that needs all of it is
the web that tracks its readers, because the script is what does the
tracking. The reader here draws documents and messages, and a page that
is a program is a page it cannot show. Section 12 names the reversal and
its cost.

**An app per network.** A Mastodon client, a Bluesky client, a mail
client and a chat client. Each has an inbox of its own, a notification
list of its own, and a compose window that knows one network. The
message is the same shape in all of them. Here every network serves one
shape and one reader shows all of it. A union directory is the merged
inbox, with no code written for the merge.

**The walled messenger.** Signal, WhatsApp and iMessage are sealed and
secure, and a person may not write a client for them. A messenger a
person cannot federate or reimplement is a service rather than a
protocol, and this tree is for protocols.

**The bridge.** Bridgy Fed carries a post from one network to another
and loses whatever the far side cannot say. A reader that speaks every
network natively loses nothing, and the namespace does the join.

**A protocol of this tree's own.** The temptation of every hobby system
is a network only it speaks. There is nobody on it. Every wire in this
document is one a person can already reach from a phone.

**The pod.** Solid had the right idea, a person's data as files under
their own control. Its substrate of linked data and access control never
found its readers. A person's data here is files under `$home` because
everything is, and the store in section 3 is the pod.

**IPFS.** The web of hashes as a network. Its funded team stops work
this month, and the content it holds is reached in practice through HTTP
gateways, which are URLs. The hash web here is local, section 3, and an
`ipfs://` name is a gateway URL until the day changes.

**XMPP.** A federated chat protocol with a longer record than Matrix and
a hundred extensions to choose among. It is not wrong. The homelab's
rooms are on Matrix, and a second chat server behind the same shape
waits for a person who has an XMPP server.

## 3. The wire, and the web of hashes

`servers/webfs` is `docs/GHOST.md` section 6's HTTP client as files, and
`cmd/tlsclient` is its TLS 1.3. They are built once, here, and the
ghost's cloud backend is their second client. `docs/HANDOFF.md` lists
the rewrite this refuses.

    /mnt/web/clone         read it for a conversation's number
    /mnt/web/N/ctl         url, method, header, cookies off, hangup
    /mnt/web/N/postbody    what a POST sends
    /mnt/web/N/body        the response, a read that streams
    /mnt/web/N/headers     the response's headers
    /mnt/web/N/status      the code and the reason
    /mnt/web/N/hash        sha256 of the body, once it ended
    /mnt/web/N/ws          the same conversation as a WebSocket, after
                           `ctl upgrade`: a frame per read and write
    /mnt/web/cookies       the jar, one line per cookie, which `rm` edits

**HTTP/1.1, and no more.** Persistent connections, chunked bodies and
gzip, from `core:compress`. HTTP/2 and 3 buy a busy page milliseconds
and cost a multiplexer and QUIC. Every server on the internet still
answers 1.1. A reader that opens ten conversations for ten images is
fine on a LAN and on a homelab's uplink.

**TLS 1.3 is a handshake and a record layer.** `core:crypto` has X25519,
the AEADs, HKDF, the signatures, and an X.509 parser with chain
verification. What is written is the state machine, the key schedule and
the records, about three and a half thousand lines. The root store is
`/lib/tls/roots`, staged by the build from the host's. Client
certificates are for Gemini and for nothing else.

**Gemini is a scheme.** A `gemini://` URL on `ctl` is one TLS
connection, one request line, one response with a status and a media
type. `webfs` serves it through the same files, and a certificate in
`factotum` under `proto=x509` is the identity a capsule asked for.

**Every body goes into the store under its hash, which is Armstrong's
web of hashes as a cache.** `$home/lib/web/store` is a directory of
bodies named by their sha256. `$home/lib/web/names` is an index, one
line per fetch: the URL, the time, the media type and the hash. A page
that vanished can be read as it was, and a page that changed as it was
on any day it was read. A quote can be checked against the bytes it
quotes. The store is a directory, so `grep` searches every page a person
ever read and the ghost can too.

**Every link is kept, both ways.** `$home/lib/web/links` is a second
index, one line per link the reader found: the page it was on and the
page it names. Read backwards it is a backlink. So every document on
this machine has a list of what pointed at it, built from the person's
own reading. The web has no such list. Nelson said every link must be
two-way, and the answer here is that the reader keeps the other
direction itself.

**The cookie jar is a file.** A site's cookies are lines in it, `rm`
forgets a site, and `cookies off` on a conversation sends none. There is
no third-party cookie because there is no script to want one.

**Names.** `/net/dns` from `docs/FLEET.md` answers the name, and `webfs`
dials through `/net/tcp`. A URL is `core:net/url`'s.

Proves, offline. RFC 8448's handshake trace runs through `tlsclient` and
every key in it matches. `tests/tlssrv` stands a scripted TLS 1.3 server
on this machine's own stack, over `sys/libtls`'s server side, and
`tests/web.rc` has `tlsclient` dial it by this machine's name, verify its
chain against `/lib/tls/roots` and the clock, and relay a line each way.
`webfs` fetches a chunked body from `tests/websrv` over http and a body
from `tlssrv` over https, each read to its end off `body` and landing in
the store under the hash `hash` answers, with a line in `names`. A
second fetch of the same URL adds a line to `names` and no file to the
store. By hand: `ipconfig ether0`, then a GET piped into `tlsclient
example.com 443` answers with the page.

**What `webfs` does today, and what it does not yet.** HTTP/1.1 over
`/net/tcp`, `https` over `sys/libtls`, a body by Content-Length, chunked
or to the close, gzip inflated whole before it is served, `method`,
`header` and `postbody`, the cookie jar at `/mnt/web/cookies` (a line per
cookie, a write adds one, a remove forgets them all, `ctl cookies off`
sends none, and the jar persists in the store), the Gemini scheme through
the same files (`status` is the `20 text/gemini` line), and the store
with `names`. A conversation outlives its descriptors, as `netfs`'s do,
so a shell writes `ctl`, reads `body` and reads `hash` as three commands;
a finished one with no descriptor is reclaimed when the table is full,
and `hangup` frees it at once. The first open of `body`, `headers`,
`status` or `hash` starts the fetch, on a thread with an io proc of its
own, and the dial's parking calls go through that io proc too
(`libnet.dial_dir_via`), so the serve loop never waits on the network.
The boot line fetches, from `tests/websrv` over http, a chunked body, a
gzipped one, a response that sets a cookie and one that echoes the
cookie sent (and does not when `cookies off`), and from `tests/tlssrv` a
body over https and a capsule over gemini. Not yet: a connection kept
for the next request, the WebSocket, and Gemini's trust-on-first-use.
A capsule's self-signed certificate today must chain to
`/lib/tls/roots` like any other. The `links` index is the reader's, and
step 1 keeps it.

## 4. The message shape, and the union that is a timeline

A message is a directory, `upas/fs`'s way, and every network in this
document serves it.

    <id>/from        the author, as the network names them
    <id>/date        when, as seconds since the epoch, then the network's text
    <id>/subject     a title, a room's name, or empty
    <id>/body        the text, as text
    <id>/type        the body's media type, and the parts' after it
    <id>/raw         what the network sent: the RFC 5322 message, the
                     activity, the record, the event, the feed entry
    <id>/hash        sha256 of `raw`, which is its name in the store
    <id>/replyto     the id this answers, or empty
    <id>/replies/    what answered it, the same shape, one level down
    <id>/links       what the body points at, one per line
    <id>/N/          a part, an attachment, an image, the same shape

An id sorts by time. It is the date in sixteen hex digits, a dot and the
network's own id, so `ls` puts a directory in order without sorting
anything.

**A conversation is a directory of messages, and a network is a
directory of conversations.** A mailbox, a chat, a room, a timeline and
a feed are the same thing at this level. A program that reads one reads
all of them.

    /mnt/mail/inbox/         the mailbox, or a chat as Delta Chat sees it
    /mnt/matrix/<room>/      a room
    /mnt/fedi/home/          the fediverse timeline
    /mnt/at/home/            the other timeline
    /mnt/feed/<site>/        a feed
    /mnt/mention/            what pointed at this person's own pages

**And every network has the same six files above its conversations.**

    ctl        login, logout, follow, unfollow, join, leave, fetch <id>
    me         who this person is here: a name, an id, a key
    new        write a message: header lines, an empty line, the body
    notify/    what came back: replies, mentions, likes, quotes, invites
    event      a read that parks, and answers a line when a message lands
    dict       the vocabulary, `docs/GHOST.md` section 5's contract

`new` takes the same header block on every network. `to` is an address,
a room, a thread or nothing. `replyto` is an id. `attach` is a path. A
network that cannot honour a header refuses the write by name.

**The union is the timeline.** `bind -a /mnt/fedi/home /mnt/all` and
`bind -a /mnt/at/home /mnt/all` and a feed or ten, and `/mnt/all` is one
timeline. It is in time order because the ids are. The reader shows a
directory of messages and does not know how many servers are under it.
That is the whole of the merge, and it is a namespace doing what a
namespace is for.

**`sys/libmsg` serves the shape.** A network server is a translator. It
turns bytes from the wire into a record, and `libmsg` serves the record
as the tree above on `sys/lib9p`. `replies/` is walked on demand, and
`event` is a read that parks. A server is then its wire, its record, and
nothing about 9P. `sys/libmime` parses RFC 2045 parts and RFC 5322
headers, for mail and for everything that borrowed mail's shape.

**`servers/feedfs` is the first, because it needs no login.** A feed's
URL on `ctl` makes a conversation, `webfs` fetches it, and
`core:encoding/xml` reads Atom and RSS into entries. A poll is a proc
with a timer. A feed is the smallest network there is, and it proves the
shape before any network with a password does.

Proves, offline. A saved Atom file through a pipe becomes a directory of
entries in time order. Two feed directories bound together list as one,
in order. A write to `new` on a feed answers permission denied, because
a feed is read only and the refusal names it.

## 5. `mothra`: the reader

`apps/mothra` is a `sys/libmui` program and a `/srv/draw` client, one
window per page. It draws documents and directories of messages, and it
does not run programs.

**What it draws.** Eight kinds of thing, and the theme says how.

    text/gemini      a page
    text/markdown    a page, through a few hundred lines of `sys/libmark`
    text/html        a page, as far as the subset below goes
    text/plain       a page
    an image         through `core:image`, on the page or on its own
    a message        a thread, with the parts inline
    a directory of messages
                     a timeline, one row per message with its author,
                     its time and its first line, and the message opens
                     in place
    a directory      a listing

**The HTML subset is the readable web.** `sys/libhtml` is the WHATWG
tokenizer, about nine hundred lines, and a tree builder that keeps the
elements a reader needs and drops the rest. What it keeps is headings,
paragraphs, lists, links, images, emphasis, preformatted text, tables
and block quotes. And forms, with text fields, password fields, check
boxes, selects and buttons. No stylesheet is read, and no script is run.
What a reader-mode view keeps is what this draws, and the theme says
how.

**Forms exist because logins are forms.** Mastodon's authorization page
is HTML with a password field and a button, and every OAuth flow in
section 7 opens such a page. A `GET` form is a URL and a `POST` form is
a body, both through `webfs`. The jar keeps the session cookie the page
set.

**The page and its column.** A window is two panes, the page on the left
and its column on the right. The column is what points at the page:
`replies/` for a message, `notify/` lines that name it, and mentions for
the person's own page. And the backlinks section 3's index has for it.
That is Nelson's transpointing window, drawn from the machine's own
index over networks that never agreed to it. A link in the column opens
on the left, and the column follows.

**A quote is fetched, and checked.** A message whose `raw` embeds a
strong reference, URI and CID together, is shown with the original in
place. `mothra` fetches the original by its URI and checks it against
the CID. A quote that fails the check is drawn with the difference
marked. That is transclusion as the AT Protocol makes it possible, and
the check is Armstrong's checksum that does not tally.

**History is the store.** Back is the previous line in `names`. A page
is never fetched twice for a back. `mothra` shows the date a page was
read beside its title, and a menu offers every day it was.

**Every link goes through the plumber.** A click writes the URL to
`/mnt/plumb/send`, and `/lib/plumb/rules` says where it goes. A `https:`
or `gemini:` URL comes back to `mothra`, and a `mailto:` opens section
6's compose window with the address filled. An `at://` URI walks
`/mnt/at/obj`, and a `.odin:31` opens the editor, as the ghost's plan
has it. So a script, the ghost and a click are one mechanism.

**Compose is one window.** A message to any network is the header block
and a body, written to that network's `new`. The window is the same for
a toot, a post, a mail and a room message. Its `to` field knows which
network an address belongs to. A reply is the same window with `replyto`
filled.

**The font is this plan's first dependency.** `sys/libfont` is an 8x16
table of 128 glyphs, and `docs/HANDOFF.md` defers a wider one with its
reason. A reader of the world's pages needs Latin with its accents,
Greek, Cyrillic, the symbols people post, and the emoji they end a
sentence with. So this plan owns the deferral.

`sys/libfont` grows Plan 9's `.font` file. That is a text file of rune
ranges, each naming a subfont file, loaded on first use and kept in a
small cache. The build bakes the subfonts from a host font with
`tools/genfont.py`, which already bakes the one. A glyph the font lacks
draws as a box, and nothing is dropped. `sys/libedit` then stores every
rune, and the line that dropped them stops.

Proves. A saved page of every kind above lays out at two widths and the
geometry matches the numbers in the test. An injected click on a link
plumbs its URL and the test's port receives it. A page read twice shows
the earlier date in the menu. A message with a strong reference to a
record the test altered draws the difference. A rune past 128 lands on
the glass as a glyph, and one the font lacks as a box.

## 6. Mail, and the messenger it already is

`servers/mailfs` serves a person's mail as section 4's shape, on IMAP
and SMTP, and seals it with OpenPGP the way Delta Chat does. A person
with a chatmail account has a secure messenger. A person with any mail
account has mail, sealed when the far side can open it.

    /mnt/mail/ctl            account <name>, fetch, send, seal on|off
    /mnt/mail/me             the address, and the key's fingerprint
    /mnt/mail/new            a message: to, subject, replyto, attach, body
    /mnt/mail/inbox/         the mailbox, every message a directory
    /mnt/mail/<chat>/        a chat: the thread with one person or group
    /mnt/mail/contacts/      one file per address: name, key, verified
    /mnt/mail/notify/        a new message, a join, a read receipt

**The wire is IMAP4rev1 with IDLE, and SMTP submission.** Both over
`tlsclient`. `IDLE` is the read that parks, so `event` answers the
moment the server has something. The account's password is a line in
`factotum`, `key proto=pass server=imap.example user=... !password=...`,
which is what Plan 9's `factotum` held for its `upas`. `mailfs` asks for
it at login and never keeps it.

**The seal is OpenPGP, RFC 9580, and no more of it than Autocrypt
needs.** `sys/libpgp` reads and writes the packets. Keys of version 4
and 6 on Ed25519 and X25519, a signature, a sealed session key, and
sealed data in versions 1 and 2. The version 2 packet is AES-256 in OCB
mode, which is two hundred lines over `core:crypto/aes`. Autocrypt v2
adds a fallback subkey on ML-KEM-768 with X25519 for the day the world
wants a post-quantum seal, and `core:crypto/mlkem` is there for it. RSA
keys are read and verified, so a plain mail user's signature checks, and
never made.

**`factotum` holds the key and does the arithmetic.** `proto=openpgp` is
a key derived from the passphrase and a label, `docs/FLEET.md` section
4's way. It lives nowhere, and a second machine has the same identity. A
decrypt is an `rpc` conversation: `mailfs` writes the session key packet
and reads the session key. A sign is the same with a hash. `mailfs`
never holds the private key, and a tool in the ghost's sandbox cannot
reach `factotum` at all.

**Autocrypt is the key exchange.** Every message out carries the
person's public key in an `Autocrypt:` header. Every message in with one
updates `contacts/`. A message to a contact with a key is sealed, and
one to a contact without is not, and `me` says which. A person who wants
only sealed mail writes `seal on` and the unsealed refuse.

**Chatmail is an account in one request.** A `dcaccount:` URL from a
relay, typed or scanned, is a POST that answers an address and a
password. `ctl account` takes it, writes the password to `factotum`, and
the person has a messenger. The relay refuses cleartext, so `seal` is on
and cannot go off.

**SecureJoin is the verification.** An invite, as a URL or a QR code the
reader draws as an image, carries a fingerprint. The handshake Delta
Chat specifies runs as sealed messages, and at the end
`contacts/<address>/verified` reads `yes`. A group is a chat with a
member list and a shared secret the same handshake carries. The version
of the handshake is Delta Chat's current, version 3, and a message from
an older client is answered as it was.

**Metadata stays inside.** The subject, the references and the reply
headers go inside the sealed part, RFC 9788's way. The outer message
carries a date and a placeholder subject. A relay then sees who wrote to
whom and when, and nothing else. A plain mail server sees the same,
which is more than a relay should, and it is what mail has always shown.

**A chat is a thread.** `mailfs` groups messages by the sealed
`Chat-Group-ID` header and by the pair of addresses. So
`/mnt/mail/<chat>/` is the conversation as Delta Chat shows it, and
`inbox/` is the same messages as mail shows them. Both views are the
same directories under two names.

Proves, offline. RFC 9580's test vectors seal and open through `libpgp`.
A saved IMAP session through a pipe becomes an `inbox/` of the right
shape. A message with an `Autocrypt:` header lands a key in `contacts/`.
A message written to `new` for a contact with a key comes out of a
scripted SMTP sealed, and opens with the contact's test key. A
SecureJoin between two `mailfs` on a pipe ends with `verified` on both
sides, and one control, a wrong fingerprint, ends with `no`.

## 7. The two social networks, and the links that come back

Two servers, one shape, and a union that is one timeline.

**`servers/fedifs` is a Mastodon client, and an ActivityPub reader.** A
person's own account is Mastodon's REST API: `home`, `notifications`,
`statuses`, `follow`, with the access token from `factotum` under
`proto=oauth`. The login is the authorization code flow with the
out-of-band redirect. `mothra` opens the instance's page, the person
approves, and the code pastes into `ctl login`. The password grant is
gone from Mastodon and is not missed.

Anything public on any instance is a GET with `Accept:
application/activity+json`. So `/mnt/fedi/obj/<url>` is any actor or
object in the fediverse as a message directory, whether or not the
person's instance knows it. A reply activity that reaches the inbox is a
file in `notify/` and a message under `replies/` of what it answered.
That is the link that came back.

**`servers/atfs` is an AT Protocol client.** XRPC is JSON over HTTPS,
one method per URL, and the schemas name the fields. The timeline, the
notifications, a post, a follow and a like are the `app.bsky` methods,
and a record by URI is `com.atproto.repo.getRecord`. Login is an app
password on `createSession` first, because the protocol still accepts
one for a command-line tool, and OAuth second. OAuth on AT is PAR, PKCE
and DPoP, and DPoP is an ES256 signature per request, which
`core:crypto/ecdsa` signs on P-256. The tokens live in `factotum`, and
`webfs` adds the header when the host matches, the way the ghost's plan
adds an API key.

**A record checks against its hash.** A record's CID is the hash of its
DAG-CBOR bytes, and `getRecord` answers the record as JSON with the CID
beside it. `sys/libcid` turns the JSON back into canonical DAG-CBOR on
`core:encoding/cbor` and hashes it. So `hash` on a record is the
network's own name for it, and a quote's strong reference checks against
what arrived. A record that fails the check is served with `hash` empty
and a line in `notify/`.

**The reply graph is two-way on both networks.** `replies/` under a post
is `getPostThread` on AT and the context call on Mastodon. `notify/` is
what came back. A quote on AT is `getQuotes`, and a quote on the
fediverse is a mention that carries the URL, which `links` finds. The
reader's column shows all of it beside the post.

**Media.** An image in a post is a part directory, fetched on first read
through `webfs` and kept in the store. A post with an image is written
to `new` with `attach`, and the server uploads it first and embeds the
answer.

**What the person owns.** Every post read is in the store by hash. Every
post written is in `$home/lib/web/sent`, as the record or the activity
the server sent, before the network has it. An account on either network
exports with `cp -r` of its directory. A person's AT repository can be
fetched whole as a CAR file, which is a `ctl fetch` and a directory
under `obj/`.

Proves, offline. A saved timeline from each network through a pipe
becomes a directory of the right shape. The two bound together list as
one in time order. A record whose JSON the test altered checks false and
`hash` reads empty. A scripted authorization page through `mothra` ends
with a token in `factotum`. A DPoP proof the test verifies with the
public key carries the right method and URL.

By hand: a post lands on each network, and a reply to it appears in
`notify/`.

## 8. Chat, on Matrix

`servers/matrixfs` serves a person's rooms as section 4's shape, and
seals them with Olm and Megolm, which every Matrix client speaks today.

    /mnt/matrix/ctl          login, join, leave, invite, verify <device>
    /mnt/matrix/me           the user id, the device id, the keys
    /mnt/matrix/new          a message: to <room>, replyto, attach, body
    /mnt/matrix/<room>/      the room, one message directory per event
    /mnt/matrix/<room>/members
    /mnt/matrix/<room>/typing    a read that parks, and answers who
    /mnt/matrix/notify/      an invite, a mention, a verification request
    /mnt/matrix/devices/     this person's devices, and whether each is verified

**The wire is the client-server API.** `/login` with the password from
`factotum`, then `/sync` with a long poll, or simplified sliding sync
where the server has it. Either is the read that parks behind `event`. A
room is its events, and a message event is a message directory. A state
event that names the room is the directory's name, and a redaction is a
directory that goes. `matrixfs` sees no federation and no state
resolution, because a client never does, and that is what keeps it a
client.

**The seal is Olm and Megolm.** `sys/libolm` is Olm's triple
Diffie-Hellman and double ratchet on X25519, HMAC-SHA-256 and AES-256 in
CBC mode, and Megolm's outbound ratchet for a room. CBC is a page over
`core:crypto/aes`, and everything else is in `core:crypto`. The device
keys and one-time keys go up and come down through the API. A room key
arrives as an Olm message and goes into `$home/lib/keys/matrix`, sealed
under a key derived from the passphrase.

**A device is verified in a requester.** `ctl verify <device>` shows the
far device's key fingerprint and asks the person to compare it with what
the other screen shows. That is the whole of verification in this plan.
The emoji handshake and cross-signing are deferred with their reason,
and a device left unverified is marked so in every message it sent.

**MLS is the reversal.** Matrix is moving its seal to MLS, and its
proposal is in review. `libolm` is behind `matrixfs`. The day a person's
rooms speak MLS is the day `sys/libmls` sits beside it behind the same
files. `core:crypto` has the primitives. The message shape does not
change, and the reader does not notice.

Proves, offline. Olm's and Megolm's published test vectors seal and open
through `libolm`. A saved sync through a pipe becomes rooms of the right
shape with a sealed message opened by a test key. A message written to
`new` comes out of a scripted server as a Megolm event the test opens.
By hand: two machines on the fleet's bench, each with a `matrixfs`
against one homeserver, exchange a sealed line.

## 9. Publishing: the other direction

Nelson's web has no readers who are not also authors. A person here
publishes from a directory, and the links to what they wrote come back
to a directory.

**A site and a capsule from `$home/www`.** `cmd/httpd` serves a
directory as HTTP, static and nothing else, and `cmd/gemd` serves the
same directory as Gemini. Both are scripts in `/rc/bin/service`, so
`docs/FLEET.md` section 5's `listen` starts them on the file server. A
person's site is then the machine that holds the tree. A `.md` file is
served as it is on Gemini and rendered to HTML on the web by
`sys/libmark`, so a page is written once.

**A feed out.** `cmd/mkfeed` writes an Atom file for a directory, so a
site is a feed the moment it exists. A person with `feedfs` follows it
as they follow anything.

**Webmention, both ways.** On publish, `cmd/webmention` reads the new
page's links, finds each target's endpoint, and sends the mention.
`httpd` accepts one at `/mention`, verifies that the source links here,
and writes it as a message directory under `/mnt/mention`. A page of the
person's own then has a `notify/` like a post does, and the reader's
column shows who wrote about it. That is the two-way link as a W3C
standard, and it costs four hundred lines.

**Not a fediverse server, and not a PDS.** A person's own ActivityPub
actor or AT Protocol host is a server that must be up, must federate,
and must be moderated. A homelab's file server can run one the day
someone ports it, under `docs/DEVTOOLS.md`'s POSIX library, and the
shape here does not change.

Proves. A page written into `$home/www` is fetched back through `httpd`
and through `gemd` with the same body. A mention sent from a test page
to a scripted endpoint carries source and target. A mention received
from a scripted source lands in `/mnt/mention`, and one control, a
source that does not link here, is refused.

## 10. The ghost, and the sandbox

Every server here serves `dict`. So the ghost can read a person's
timeline, summarise a thread, draft a reply, and find the page that said
a thing. The store is a directory, so the ghost's `read` and `run grep`
work on every page a person ever read. Its memory can point at a hash
rather than at a URL that will rot.

**None of it is in the sandbox by default.** `docs/GHOST.md` section 4's
classes name what a task may reach, and `/mnt/mail`, `/mnt/matrix`,
`/mnt/fedi` and `/mnt/at` are in none of the classes the tree ships. A
class `social` adds them read-only, and a class `post` adds `new` with
the requester in front of it. A task that talks the model into posting
finds no `new`, and one in the `post` class finds a person who must say
yes.

**The store is in every class.** It is the person's own reading. A model
that can search it answers from what the person saw rather than from
what it guesses. `factotum` stays out of every class, so the keys stay
where they are.

## 11. The order

Each step ends with a boot line that runs with no network, on saved
conversations through pipes and on published test vectors. A by-hand
line runs live. Steps 3, 4 and 5 are independent of one another.

### Step 0: the wire

`cmd/tlsclient`, `servers/webfs`, the store, the link index, the jar,
the Gemini scheme, the WebSocket. About 6,400 lines, most of it TLS.
Needs `docs/FLEET.md` step 0. Takes over `docs/GHOST.md` step 4's
`tlsclient` and `webfs`, so the ghost's cloud is a client of this.

Boot line: RFC 8448's trace runs, and a body from a pipe lands in the
store under its hash.

### Step 1: the reader

`sys/libfont`'s subfonts and `tools/genfont.py`, `sys/libhtml`,
`sys/libmark`, `sys/libgemtext`, `apps/mothra`, the plumber rules. About
7,300 lines. Needs step 0, `docs/WORKBENCH.md` step 3 for the toolkit,
and `docs/GHOST.md` step 2 for the plumber.

Boot line: a page of each kind lays out to the numbers, a click plumbs,
and a rune past 128 is a glyph.

**Where it stands.** The font past 128 is done. `sys/libdoc` is the page
as blocks, the shape every parser makes, and one layout turns it into
rows of a width. The blocks are gemtext's line types, since they are the
readable minimum a richer format reduces to. `sys/libgemtext` and
`sys/libmark` parse into it, and `tests/doc` lays a page of each out to
the numbers every boot.

`apps/mothra` is the reader's first cut. A page from a URL through
`/mnt/web` or a file is laid out to the window's columns and shown as
the toolkit's list. A press on a link's row follows it, `b` goes back,
`j`, `k`, `n` and `p` scroll, and the boot line opens it on a gemtext
page.

`sys/libhtml` is the tokenizer above and a reader's builder rather than
a tree. Text gathers into a paragraph, a block element flushes it, and
the element it sits in says the kind. A link follows its paragraph as a
block. A paragraph that is nothing but a link is the link, a heading's
own `#` anchor goes, and a table row is its cells parted by a bar. It
reads example.com, a Wikipedia article and the Odin overview to rows
that read, and `tests/doc` holds a page of it. A click plumbs: the URL
goes to `/mnt/plumb/send`, the rules route it to the `web` port, and the
reader, which holds that port open, reads it back and opens it. So
`plumb URL` from any shell opens a page in the running reader, or
starts one. A PNG on its own is a page too: `sys/libimage` decodes it,
since Odin's own `core:image` cannot build for ring 3, and the toolkit's
picture gadget loads the pixels into the window fitted to it. On a page,
a picture is fetched the way the page was and stood on rows of its own
under its caption, and the rows wear the ink their kind says: a heading
hot, a link cyan, a quote dim, a rule a line. The boot line decodes a
PNG of each shape to its pixels, opens the reader on one, and opens it
on a markdown page that names one and finds its corners on the glass.

Forms are in. `libhtml` reads a form's parts into blocks of their own,
each knowing its form. A field, a secret, a check, a hidden value, a
select reduced to its chosen value, and a button. `libdoc` encodes a
form as a query. The reader draws the parts as rows on a recessed bar.
Tab selects the next part, typing fills a field, Space turns a check,
and Return sends the form, as a query on the action or as a POST body
through `webfs`.

The boot line parses a form to its parts and its query. It POSTs a
login to the fixture server through `webfs` and reads the welcome back.
The reader's own typing is not on the boot line. A reader started
inside the network tests hangs in a write to the draw server, which is
the open stale-wake race the handoff names. That path is hand-tested
until the race is found.

JPEG is in. `sys/libimage` decodes the baseline kind, with its restart
intervals and its subsampled chroma. That is what a camera and a page
hand out. The progressive kind is refused.

The host's own decoder agrees with it to within a few levels on the
same file. The boot line decodes two fixtures to the numbers. The
reader and its rules take `.jpg` beside `.png`, on the page and on
their own.

The column is in. The window is two panes, the page and a third of the
width beside it. For a message the column is what it answers, its
replies, and its network's `notify/` messages that answer it. For a
page it is the backlinks. The reader keeps section 3's `links` index
itself, one line per link it laid out, and reads it backwards. A press
in the column opens on the left, and the column follows.

The boot line sees the gemtext page's links land in the index. Then it
sees the backlink in the column of the page that link names, and a
reply in the column of the message it answers. Step 1 is complete, but
for the mentions and quotes that wait on their networks.

### Step 2: the shape, and feeds

`sys/libmsg`, `sys/libmime`, `servers/feedfs`, the union, the timeline
view and the compose window in `mothra`. About 2,900 lines. Needs step
1.

Boot line: two saved feeds bound together list as one timeline in order,
and `mothra` shows it.

**Where it stands.** The shape is served and the first network reads
it. `sys/libmsg` is the record and the tree. The record is a message
and a conversation in id order. The tree is the six files above the
conversations and the handler that serves them all on `sys/lib9p`. A
server fills a `Net` and two callbacks, one for `ctl` and one for
`new`, and is then its wire and its record.

An id is the date in sixteen hex digits, a dot, and the network's id.
A network id that is no file name gives way to its hash. `replies/`
is walked on demand from `replyto`. A read of `event` parks and answers
one `conv/id` line. A message's parts are not served yet.

`sys/libfeed` reads Atom and RSS into records, over a scanner of its own,
since `core:encoding/xml` wants `core:os`. It reads both date forms. An
entry's content or summary is the body, with the type the feed
declares. Its links and enclosures are the links, and its own markup is
the raw text.

`servers/feedfs` is the network. `fetch [name] url-or-path` on `ctl`
makes a conversation, through `webfs` for a URL and the file for a
path. The fetch runs on a thread and the write waits for it, so the
shell knows when the entries are in, or why not. `new` is refused, as
the proof asks.

`poll N` fetches every feed again each N seconds, on a thread with a
timer. The shell proves it: a feed file changed under a one-second poll
gains its entry with no fetch asked for.

Compose is in, one window for every network. It is a form whose action
is the network's `new`: the address, the subject, a hidden `replyto`,
the body and a Send button. It opens on `compose:/mnt/mail`, or on a
`mailto:` address with the address filled. On `c` over a message it
opens as a reply, with the address, the subject and `replyto` filled.
Sent, the reader shows the network's `sent/`. Refused, the page says
why.

The boot line opens it on a `mailto:` address, types a subject and a
body, and reads the message back from the scripted submission server.
The body is one line, until the toolkit has a text editor. Step 2 is
complete.

`sys/libmime` is in. It unfolds RFC 5322 headers and cuts RFC 2045
parts at their boundaries, one level down at a time. A part's bytes
come out of quoted-printable or base64, a Latin-1 part comes to UTF-8,
and a header's encoded words decode. `address` parts a sender into a
name and a box, and `text_body` picks the part a reader shows.

The dates every network writes now parse in `libmsg`, RFC 3339 and RFC
822 both. `libmsg.parse_new` reads a write to `new` with the same
header reader, and names a header no network knows for the refusal.
The boot line parses a saved two-part mail with an attachment to its
values.

The reader shows it. `libmsg`'s reading half turns a message directory
back into a record and a conversation into rows, from any network's
files. `mothra` on a directory of messages is the timeline, one row a
message with its time, its author and its first line. A press opens the
message in place. A message is a page: subject, sender, date, the
body by its type, its links, and its replies as rows. A plain directory
is a listing.

The boot line runs the proof above on two saved feeds. It reads an
entry's files and walks a reply under the entry it answers. It binds
the two under `/mnt/all` and lists five entries as one. Then the shell
reads the union first to last with `ls` and `cat`. A program reads the
conversation back through the reading half, and the reader opens it as
a timeline, its link rows on the glass.

### Step 3: mail

`servers/mailfs`, `sys/libpgp`, `factotum`'s `openpgp` and `pass`
protocols, Autocrypt, chatmail, SecureJoin. About 8,000 lines. Needs
step 2 and `docs/FLEET.md` step 2 for `factotum`.

Boot line: RFC 9580's vectors, a saved IMAP session, a sealed message
out, and a SecureJoin over a pipe with its control.

**Where it stands.** `servers/mailfs` is the first cut. The account is
a line on `ctl`. The password is asked of `factotum`'s new `proto=pass`
at login and never kept. `fetch` is IMAP4rev1, TLS unless `plain` is
said.

Every message of the inbox is a directory of the shape. Its sender and
subject are decoded off its headers by `libmime`, the plain part is the
body, and `In-Reply-To` resolves to `replyto`.

The boot line runs it plain against `tests/imapsrv`, a scripted server
on the machine's own stack. The saved two-part mail and its reply land
as an inbox. A wrong password is refused, and the fetch says so.

`new` is in, over SMTP submission. The block written becomes a message.
From is the account, Date is now, a Message-ID is made, and In-Reply-To
is the inbox message `replyto` names. The body goes as text, or as a
multipart with a base64 part per `attach`. `AUTH PLAIN` uses the same
password from `factotum`.

The write returns once the server takes the message, or says why not.
What went out is a message of `sent/`. The boot line submits a reply to
`tests/smtpsrv` and reads it back whole from the file the server wrote.
Not yet: IDLE, STARTTLS, Autocrypt, contacts, chats, chatmail and
SecureJoin.

`sys/libpgp` opens. It reads the packets: keys of version 4 and 6 on
Ed25519 and X25519, with their fingerprints. It reads a signature of
either version, the X25519 session key packet and version 2 sealed
data. OCB is two hundred lines over `core:crypto/aes`, and the key wrap
is RFC 3394's. It verifies a signature over a key, a user id or a
document.

It opens a message in four steps. The session key comes by
X25519 and HKDF. The message key and nonce come by HKDF again. Each
chunk opens in OCB, and the final tag last.

The boot line runs RFC 9580's own vectors through it from ring 3. The
sample certificate gives its fingerprints and its signatures verify.
The sample message opens to its text, and is refused with a byte
flipped. The sample signed message verifies.

The sealing side is in. `seal_message` writes the session key packet,
then version 2 sealed data holding the literal and a padding packet.
`sign_message` writes a one-pass packet, the literal and the signature.
Each takes its random octets as parameters.

So the boot line makes the RFC's sample message again from the RFC's
own ephemeral secret, session key, salt and padding, octet for octet.
It makes the sample signed message the same way from its salt and time.
A message sealed on random parameters opens again, and
not with its final tag bent. Not yet: RSA and ECDSA keys and the locked
secret key.

`factotum` holds the key. `proto=openpgp` derives an identity from the
passphrase and a label, the fleet's way with `openpgp.` before the
domain. `libpgp` derives the seeds, the creation time and the signature
salts from it. So the certificate is the same octets on any machine. The rpc verbs are `cert`, `decrypt` of a session key packet to
the session key, and `sign` of a digest. `libpgp` signs in two halves
for it: `sign_begin` hashes and lays the packet out, and `sign_finish`
takes the sixty-four octets from whoever holds the secret.

The boot line proves the identity lives nowhere: the same passphrase
derived in a program gives factotum's fingerprint and certificate. A
message sealed to it opens with the session key factotum hands back,
and a signature factotum makes verifies against the certificate.

Autocrypt is in. `identity DOM` on `mailfs`'s `ctl` names the key
factotum holds, and `me` gains its fingerprint. Every message out
carries the certificate in an `Autocrypt:` header. Every message in
with one lands its key under `contacts/<address>/`: the name, the key
armored, its fingerprint, and `verified` as `no`.

A message to contacts that all have a key is sealed. The content goes
as the literal inside version 2 sealed data to their keys and the
person's own, so `sent/` reads. The outer message is
`multipart/encrypted` with a placeholder subject, and the real subject
is inside. A sealed message in opens with the session key factotum
hands back.

The boot line sees Bob's header make a contact. It sees a message
sealed to the identity open in the inbox. It sees a reply to Bob sealed
to his key, and a program that holds the key opens it. `libpgp` gained
armor and sealing to several keys, and `libmsg` a tree beside the
conversations for `contacts/`.

The seal is signed inside. What goes out sealed is a signed message in
the sealed data, and factotum makes the signature over the digest. A
sealed message in with a signature is checked against the sender's
contact key, and refused when it does not hold. A sender with no key
here is let stand, unverified. `seal on` refuses a message to a contact
without a key, and `seal off` lets it go.

The boot line opens a sealed message signed by Bob, and refuses the
same with its signature bent. It sees the reply to Bob signed inside by
factotum's key, and `seal on` refuse a plain message.

Chats are in. Every message in or out stands in `inbox/` or `sent/`
as mail shows it, and in a chat as a messenger shows it. A chat is a
directory named for the other address, or `group-` and the
`Chat-Group-ID` a group's messages carry inside the seal. The same
message is in both.
The boot line sees Bob's three messages and the reply to him in the
chat named for his address.

SecureJoin is in. `invite` on `ctl` makes an invite as Delta Chat
does. It is the fingerprint, the address and two secrets, and `ctl`
shows it.

`join` with an invite sends the request, plain, with the joiner's key. The inviter answers sealed. The joiner checks that the
inviter's key is the invite's, and sends the auth sealed. The inviter
checks the auth and the fingerprint, and confirms sealed.

Then `verified` reads `yes` on both sides. The handshake's headers ride
inside the seal.

It is proven on a spool. `spool DIR` makes mail files under a
directory, so two servers on one machine exchange mail with nothing
between them. The boot line runs the handshake between this mailfs and
a second. A bent fingerprint first ends in `no`, then the invite whole
ends in `yes`.

Chatmail is in. `account dcaccount:URL` makes the relay's request
through `webfs`, a POST that answers an address and a password. The
password goes to `factotum` under the address's host. The address is
the account, the submission server is its host over TLS, and the seal
is on. `seal off` is refused, since the relay refuses cleartext. The
boot line runs it against a scripted relay on the machine's own stack.

IDLE is in, and step 3 with it. `idle` on `ctl` keeps a session with
the server: a login, the inbox, what was new, and then IDLE, RFC 2177.
The server says a message landed, the session says DONE, takes what is
new by UID, and idles again. What it takes lands in `inbox/` and its
chat as a fetch's does, so `event` answers as it lands. `idle off` says
DONE and logs out. A handshake step that lands under IDLE is answered
on a sender thread over SMTP, since the session must get back to the
wire, and that is the handshake over the servers.

The boot line runs the servers between two mailfs: `tests/smtpsrv -d`,
a relay that delivers into a directory of mailboxes, and `tests/imapsrv
-m` over each mailbox, which answers IDLE off a reader thread. Bob's
message to Glenda lands in her inbox with no fetch asked, and her
`event` names it. Then Bob invites and Glenda joins, and four steps
later, each taken as it landed, Glenda is verified with Bob. Not yet:
STARTTLS on 587, and the re-issue of IDLE every twenty-nine minutes the
RFC asks of a long session.

### Step 4: the two networks

`servers/fedifs`, `servers/atfs`, `sys/libcid`, `factotum`'s `oauth`
protocol, DPoP. About 5,600 lines. Needs step 2 and `docs/FLEET.md` step
2.

Boot line: two saved timelines bound as one, a record that fails its
CID, and a scripted login that ends with a token.

**Where it stands.** `servers/fedifs` is the first cut: a timeline's
source on `ctl`, a saved one's path read as it is or a URL through
`webfs`, and each status a message. The account's name and address
are `from`, `created_at` the date, the content warning the subject,
the content an HTML body, the URL, the attachments and the card the
links, and `in_reply_to_id` resolves to `replyto`. A boost is the
boosted status under the boost's id and date. The instance's own id
is the message's name, since it is digits. `raw` keeps the status's
own bytes out of the array, so `hash` is the instance's text. The
boot line reads `tests/home.json`, three statuses with a reply and an
attachment.

`servers/atfs` is the same shape over a `getTimeline` answer: the
author's name and handle, the record's `createdAt` and text, the post's
page on the web and its images as links, and the reply's parent URI as
`replyto`. A post's name is its URI, which is no file name, so the id
carries the URI's hash and a reply resolves by the same. `raw` is the
feed item whole. The boot line reads `tests/timeline.json`, and then
binds the two timelines under `/mnt/all`, where six posts list as one
in time order. The source reading and the reach into JSON moved into
`libmsg`, `source.odin` and `json.odin`, for both.

A record checks against its hash. `sys/libcid` makes a record's
DAG-CBOR again from its JSON, the keys sorted by length and then by
their bytes, a link a tag 42 over the CID's bytes, and hashes it into
a CID of version 1 in base32. `atfs` checks each post's record against
the CID the server gave, and serves the CID as `hash` when it holds, or
an empty `hash` and a line in `notify/` when it does not. The boot
line's fourth post was altered after its CID was made.

The fediverse login is in, `servers/fedifs/login.odin`. `login BASE`
registers the app with the instance and `ctl` shows the page to
approve on, the authorization code flow with the out-of-band redirect.
`code CODE` trades the code for a token, asks the instance whose it
is, and puts the token in `factotum` under `proto=oauth`, the
account's name and the host; `me` is then the account. `fetch home`
takes the account's home timeline with the token, asked of factotum on
each request and never kept. `account BASE USER` names an account
whose token factotum holds already. `webfs` learned nothing: the
header goes on the request, through `libmsg.request`, which is a
method, headers and a body over a conversation. The boot line runs
the flow against `tests/websrv`, which serves the instance's four
paths: a wrong code refused, the right one ending with the token in
factotum, and a token the instance refuses refusing the fetch.

The AT login is in, `servers/atfs/login.odin`: an app password on
`createSession` first, as the plan says. `login PDS HANDLE` asks
`factotum` for the app password under `proto=pass`, the handle and the
host, and the session's token goes back under `proto=oauth`; `me` is
the handle and the DID. `fetch home` is `getTimeline` with the token.
Factotum's ctl and rpc are reached through `libmsg` now, for both
logins. The boot line runs it against the scripted server's two XRPC
paths: a wrong password refused, the right one ending with the token
in factotum, and a token the server refuses refusing the fetch.

Notifications are in, on both. `fetch notifications` takes what came
back into `notify/`: a message from the account that did it, its kind
or reason as the subject, the status or record it carries as the body,
and the status or post it concerns named by `replyto`. A status or post
a notification carries lands in `home` too, so a reply that came back
is a message under `replies/` of what it answered: section 7's "the
link that came back". A saved answer's path is the offline proof, and
the boot line runs one on each: a mention and a reply land under the
first post's `replies/`, a favourite and a like name what they
concern, a follow says nothing.

A post written to `new` is in, on both. The block is section 4's: the
body the status or the text, `subject` a content warning on the
fediverse, and `replyto` an id in `home`, which becomes
`in_reply_to_id` by the instance's id, or the reply's parent and root
by URI and CID on AT. The write waits for the server, with the token
from `factotum`. What the server answers lands in `home`, the status
as it made it or the record under the URI and CID it named, and under
`sent/` of the store `-s DIR` names, the way section 7 keeps what the
person owns before the network has it. The boot line posts a reply on
each against the scripted server, which echoes the status and names
the record, and reads both back from `home`, `replies/` and the store.

Any object by URL or URI is in. `object [name] url` on `fedifs` is a
GET with `Accept: application/activity+json`, and the actor or the
object answered is a message: who it is attributed to, its content,
its page and its attachments, and what it replies to by the URL's
hash. `record [name] uri` on `atfs` is `getRecord` with the
repository, the collection and the key off the URI, the value a post
whose author is the repository, checked against the CID beside it.
The boot line reads a saved note and a saved record offline, and
fetches both through the scripted server.

OAuth on AT is in, `servers/atfs/oauth.odin`: PAR, PKCE and DPoP. The
key a token is bound to lives in `factotum` under the new
`proto=dpop`, P-256, made there and never leaving; `sys/libjws` is the
JWS on ES256 and the JWK a key is carried as. `oauth PDS HANDLE` makes
the key unless there is one, draws a PKCE verifier, pushes the
authorization request with a proof, and `ctl` shows the page to
approve on with the request URI. This program is a loopback client,
so the page sends the browser to the loopback address with the code,
and `code CODE` trades it with the verifier for a token bound to the
key. From then on every request as the account carries the token as
`DPoP` and a proof factotum signs, with the server's nonce once it has
given one. The plan had `webfs` add the header; the proof is per
request and the key is factotum's, so `atfs` asks factotum and adds
it, which is one fewer thing `webfs` knows. The boot line runs the
flow against the scripted server, which verifies every proof with the
key in its own header, its method, its URI and the token's hash, and
demands its nonce once.

The page through `mothra` is in. `atfs` is a loopback client: it
listens on this machine's own address while the page is open, the
page's approval sends the browser there with the code, and `atfs`
takes it off the one request and trades it, so nothing is pasted.
`mothra` follows where a response sends it, up to five hops, which
the approval's answer is. The boot line opens the scripted page in
the reader, presses its one button, and sees the token land in
`factotum`; without a screen the code goes by hand.

Media on a post is in, on both. An `attach` line on `new` is a file
uploaded first, as multipart form data to the instance or as a blob
to the server, and the status then carries the media the instance
named, or the record embeds the blob as an image. The boot line posts
a one-pixel picture on each. `$bytes` in a record is CBOR bytes now.
Not yet: the refresh, and an image read back as a part directory,
which section 4 leaves to mail.

### Step 5: chat

`servers/matrixfs`, `sys/libolm`, the device requester. About 4,600
lines. Needs step 2 and `docs/FLEET.md` step 2.

Boot line: the Olm and Megolm vectors, a saved sync, and a sealed
message out.

**Where it stands.** `servers/matrixfs` is the first cut, on the
client-server API and no seal yet. A sync is the source: a saved one's
path, or the account's with its token. Each joined room is a
conversation, named by its state or by its id made plain, its message
events messages with the sender, the server's time, the body with the
reply fallback taken off or the formatted body as HTML, an image's
media as a link, and a reply resolved by the event id's hash; an
invite is a line in `notify/`. `login BASE USER` sends the password
`factotum` holds and keeps the token there, the networks' way. A
message written to `new` names a room and is put with the token, and
the event the homeserver names lands in the room. The boot line reads
`tests/sync.json` offline, and logs in, syncs and sends against the
scripted server.

`sys/libolm` is in: Olm's triple Diffie-Hellman and double ratchet on
X25519, HMAC-SHA-256 and AES-256 in CBC mode, the CBC a page over
`core:crypto/aes`, with pre-key and compact messages, chains each
way, and the keys kept for a message that comes late; and Megolm's
ratchet, its keys, its signed messages, and the session sharing and
export formats. Nothing in it draws randomness, so a test fixes every
key. The boot line runs `tests/olm`: Megolm's ratchet against the
reference implementation's own known answers, one step, a jump of
2^24, a jump to 0x1041506 and the wraps at 2^32; a Megolm session
sealing and opening in any order, refusing a bent message and a bent
share; and an Olm session both ways, a pre-key message first, a
message opened out of order with its kept key, and a bent one refused.
The seal is in `matrixfs`. At login the device makes a Curve25519
identity key, an Ed25519 signing key and one-time keys from
`/dev/random`, and uploads them signed over their canonical JSON. A
room whose state says it is encrypted takes a message out as a Megolm
event: the room's outbound session seals it, and its key goes first to
every member's devices, each queried, a one-time key claimed, an Olm
session made on it and an `m.room_key` sealed in it and sent to the
device. A to-device event that comes in under Olm opens with the
session it names, a pre-key message making one on the one-time key it
was made for, and the room key inside becomes a Megolm session kept
under `keys/matrix/` in the store, exported, so history opens after a
restart. A sealed room event opens with the session its key named, or
is served as a message that says the key never came. The boot line's
homeserver holds a second device, Bob, on the same library: Glenda's
sealed message opens on his side and what it said lands in a file the
test reads, and the sync after carries his key by Olm and an event he
sealed, which opens in her room.

The room's verbs and the long poll are in. `join ROOM` joins by id or
alias and the room lands with the next sync; `leave <room>` leaves and
empties the room, its directory staying for a reader's path; `invite
<room> USER` invites. A room's directory holds two files beside its
events, which `libmsg` now serves for any network: `members`, one a
line off the room's state, and `typing`, a read that parks until
someone is and answers who, off the sync's ephemeral events. `idle` is
the long poll behind `event`: a thread syncs from the last batch with
the server holding the request until something comes, takes it the way
`sync` does, and asks again; a server that answers at once with
nothing new is asked again after a pause; `idle off` ends it. On the
boot line the poll brings a message in the plain room, which a read of
`event` is answered with, and Bob typing in the sealed room, which a
read of its `typing` answers; a join brings the invited room named by
its state with its members and welcome; an invite and a leave are
taken. Two threads asking through `webfs` at once found a slot race:
a conversation just taken off `clone` and not yet written to could be
reclaimed for the next `clone`, so `webfs` now reclaims those last.
Not yet: the device requester, and the store sealed under the
passphrase.

### Step 6: publishing, and the ghost

`cmd/httpd`, `cmd/gemd`, `cmd/mkfeed`, `cmd/webmention`, `/mnt/mention`,
the `dict` files and the two classes. About 1,700 lines. Needs step 2,
`docs/FLEET.md` step 1 for `listen`, and `docs/GHOST.md` step 1 for the
classes.

Boot line: a page served both ways, a mention in and out with its
control, and the ghost reading a timeline in the `social` class.

### Deferred, with the reason written down

- **JavaScript.** A page that is a program needs an engine, and an
  engine is a hundred thousand lines this tree will not write. The hatch
  is a port of a small one under `docs/DEVTOOLS.md`'s POSIX library,
  behind `mothra` as a second renderer for a page that asks. It waits
  for a page a person needs that has no other door. The ghost that reads
  the page for them is the first door to try.
- **HTTP/2 and 3.** A multiplexer and QUIC, for milliseconds. When a
  server a person needs answers nothing else.
- **Nostr.** Its event is a hash and its author is a key, which is
  Armstrong's web exactly, and it costs one curve `core:crypto` does not
  ship, secp256k1 with Schnorr. The shape is section 4's and a server
  for it is a translator. It waits for the curve, and for a community
  whose clients stop drifting apart.
- **JMAP.** The better mail protocol, on a few servers. A second
  transport behind `mailfs`, and a client cannot tell.
- **Delta Chat's calls.** WebRTC is a stack of its own, and the tree has
  no audio device yet. `docs/DEVTOOLS.md` step 1 is the sound.
- **The emoji handshake, and cross-signing.** A requester with a
  fingerprint does the job on a homelab. The rest waits for a person
  with five devices.
- **XMPP**, for section 2's reason.
- **Annotations.** Hypothesis and the W3C model are Nelson's margin
  notes on any page. The store has a place for them, one file per hash,
  and the format is the W3C's, so the day has a shape. A person who
  wants them shared is the trigger.
- **A wallet.** Nostr's zaps are the closest thing to transcopyright
  that exists. A wallet is not this tree's business.
- **An ActivityPub server, and a PDS**, for section 9's reason.

## 12. Decisions taken here, and what would reverse them

- **No protocol of this tree's own.** Every wire here has people on it,
  and a person on a phone can reach every one. The reversal is none.
- **One message shape, `upas/fs`'s, for every network.** So the reader
  is one program and the merge is a bind. The reversal is a network with
  a message the shape cannot carry, and `raw` carries it until the shape
  grows a file.
- **The union is the timeline, and nothing merges.** The ids sort by
  time and `ls` does the rest. The reversal is a network whose ids
  cannot carry a time, and there is not one.
- **The web of hashes is local.** Every body goes in under its hash and
  every link both ways, on this machine, from this person's reading. Not
  a network, because the network that tried is a gateway now. The
  reversal is a content network people use, and the store then dials it
  for a hash it lacks.
- **The reader draws and does not run.** A page that is a program is the
  tracking web, and the readable subset is the web worth keeping. The
  reversal is named above and its cost with it.
- **HTTP/1.1, TLS 1.3, and no more.** Enough for every server and three
  and a half thousand lines. The reversal is named above.
- **Mail is the messenger, Delta Chat's way.** Because it is the one
  sealed messenger that is federated, popular and not invented here, and
  a plain mail user is on it too. The reversal is a seal Autocrypt
  drops, and `libpgp` follows the draft.
- **Two social networks, natively, and no bridge.** The reversal is a
  third one people use, and it is a translator behind the shape.
- **Matrix on Olm and Megolm, and MLS behind the same files.** Because
  that is what every room speaks today. The reversal is named in section
  8.
- **A key a person owns is derived from the passphrase.** That is
  `docs/FLEET.md` section 4's rule. A second machine is then the same
  person, and no key file exists to lose. The cost is that one
  passphrase is every identity. The reversal is a person who wants them
  apart, and it is a label per identity in `factotum`.
- **`factotum` does the arithmetic.** No server holds a private key, and
  the sandbox cannot reach `factotum`. The reversal is none.
- **Every link is plumbed.** A click, a script and the ghost are one
  mechanism. The reversal is none.
- **Publishing is a directory on the file server.** Not a service
  elsewhere. The reversal is a person with no machine that stays up, and
  it is a `cp` to a host that does.
- **None of it in the ghost's sandbox by default.** The reversal is a
  line in a class file, which is the design.
- **The font comes first.** A reader of the world's pages cannot drop
  runes. The reversal is none.

## 13. Sizes and order of dependence

    step 0  the wire      tlsclient 3,500, webfs 1,800, store 400,          FLEET 0
                          jar 200, gemini 200, ws 300
    step 1  the reader    libfont 800, libhtml 2,500, libmark 600,          step 0, WORKBENCH 3,
                          libgemtext 150, mothra 3,000, tests 250           GHOST 2
    step 2  the shape     libmsg 800, libmime 700, feedfs 900,              step 1
                          mothra 300, tests 200
    step 3  mail          mailfs 2,500, libpgp 3,000, factotum 400,         step 2, FLEET 2
                          autocrypt securejoin 1,200, compose 600, tests 300
    step 4  two networks  fedifs 2,000, atfs 2,400, libcid 500,             step 2, FLEET 2
                          oauth dpop 400, tests 300
    step 5  chat          matrixfs 2,500, libolm 1,800, tests 300           step 2, FLEET 2
    step 6  publishing    httpd 500, gemd 300, mkfeed 200,                   step 2, FLEET 1,
                          webmention 400, dicts 200, tests 100              GHOST 1

Step 0 waits on the fleet's network and nothing else, and its TLS is the
ghost's TLS. Step 1's font can start today, on the tree as it is, and is
the one part of this plan nothing else waits to begin.

## See also

- `docs/FLEET.md` -- `/net`, `factotum`, the passphrase rule, and
  `listen`, which this plan reads mail, posts and rooms through.
- `docs/GHOST.md` -- `webfs` and `tlsclient`, built here and used there,
  the plumber, the application contract, and the classes that keep the
  ghost out of the mailbox.
- `docs/WORKBENCH.md` -- `libmui`, which the reader is a client of, and
  the font this plan removes from its deferred list.
- `docs/THREAD.md` -- the library every server here is written on, and
  the read that parks behind every `event`.
- `docs/NAMESPACE.md` -- the union directory that is the timeline.
- `docs/DEVTOOLS.md` -- the POSIX library a script engine or a fediverse
  server would be ported under.
- `docs/DRAW.md` -- the window `mothra` draws in, and the runes the font
  finishes.
