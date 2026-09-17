# /lib/tls

`roots` here is a single self-signed test certificate (CN=vectra.test, with
subject alternative names `vectra.test`, `vectra`, `one`, `two` and `fs`: the
machines of the solo image and the bench, so `tlsclient` can dial any of them
by name and the name check passes). It is the one `tests/crypto` embeds and the
one `tests/tlssrv` serves, with the private key both fixtures carry.

The trust store on the machine, `/lib/tls/roots`, is what `cmd/tlsclient`
verifies server certificate chains against: X.509 certificates in DER,
concatenated (each is a self-delimiting ASN.1 element, so no separators).
The build stages it as this test certificate first, then every root of the
host's CA bundle (`/etc/ssl/cert.pem` or its Linux equivalents), decoded from
PEM. `tests/tlssrv` takes the first certificate. `docs/WEB.md` section 3.
