/*
The Webmention endpoint: `docs/WEB.md` section 9's "the two-way link as
a W3C standard". A POST to `/mention` carries `source` and `target`,
form-encoded. `httpd` fetches the source, verifies it links to the
target here, and writes it as a message directory under the mention
store, which `mentionfs` serves at `/mnt/mention`. A source that does
not link here is refused, the one control the plan names.

This is filled in with the webmention brick; for now a POST to
`/mention` is accepted and anything else refused.
*/
package httpd

take_post :: proc(wfd: int, target: string, headers: string, body: string) {
	if target == "/mention" {
		respond(wfd, 202, "text/plain", "accepted\n", false)
		return
	}
	respond(wfd, 404, "text/plain", "not found\n", false)
}
