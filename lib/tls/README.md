# /lib/tls

`roots` is the TLS trust store `cmd/tlsclient` verifies server certificate
chains against: X.509 certificates in DER, concatenated (each is a
self-delimiting ASN.1 element, so no separators). `docs/WEB.md` section 3.

Today it holds a single self-signed test certificate (CN=vectra.test, with
subject alternative names `vectra.test`, `vectra`, `one`, `two` and `fs`: the
machines of the solo image and the bench, so `tlsclient` can dial any of them
by name and the name check passes). It is the one `tests/crypto` embeds and the
one `tests/tlssrv` serves, with the private key both fixtures carry. A real
deployment stages the host's CA bundle here at build time; that extraction is
a follow-up.
