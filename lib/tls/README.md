# /lib/tls

`roots` is the TLS trust store `cmd/tlsclient` verifies server certificate
chains against: X.509 certificates in DER, concatenated (each is a
self-delimiting ASN.1 element, so no separators). `docs/WEB.md` section 3.

Today it holds a single self-signed test certificate (CN=vectra.test), the one
`tests/crypto` uses, so `tlsclient` can be proven against a scripted server. A
real deployment stages the host's CA bundle here at build time; that extraction
is a follow-up.
