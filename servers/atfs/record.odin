/*
A record by URI: `docs/WEB.md` section 7's "a record by URI is
com.atproto.repo.getRecord". `record [name] uri-or-path` asks the
account's server for the record the URI names, its repository, its
collection and its key taken off the URI, and puts it in the
conversation named, `records` when no name is given, as a post: its
value is the record, its author the repository's DID, and its CID
checks the way a timeline's does. A saved answer's path is the offline
proof.
*/
package atfs

import "core:encoding/json"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libuser"
import "vsys:vectra9"

// fetch_record reads one record and puts it in the conversation.
fetch_record :: proc(f: ^Fetch) -> vectra9.Errno {
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text: []u8
	ok: bool
	if libodin.has_prefix(source, "at://") {
		if !account.set {
			return vectra9.EPERM // No server to ask
		}
		repo, collection, rkey, split := split_uri(source)
		if !split {
			return vectra9.EINVAL
		}
		url: [BASE_MAX + 512]u8
		status: int
		text, status, ok = libmsg.request(f.io, libuser.cat_into(url[:], string(account.base[:account.blen]), "/xrpc/com.atproto.repo.getRecord?repo=", repo, "&collection=", collection, "&rkey=", rkey), "", "", "")
		if ok && status != 200 {
			delete(text)
			return vectra9.ENOENT
		}
	} else {
		text, ok = libmsg.read_source(f.io, source)
	}
	if !ok {
		return vectra9.EIO
	}
	defer delete(text)
	m, made := record_message(string(text))
	if !made {
		return vectra9.EINVAL
	}
	c := libmsg.conv(&net, name)
	i := libmsg.conv_index(&net, name)
	libmsg.add(&net, c, m)
	resolve_replies(c)
	src := &sources[i]
	src.len = copy(src.text[:], source)
	rebuild_status()
	return 0
}

// record_message makes the message of a getRecord answer, `{uri, cid,
// value}`: a post view whose author is the repository, and whose record
// is the value, checked against the CID.
record_message :: proc(raw: string) -> (m: libmsg.Msg, ok: bool) {
	v, err := json.parse_string(raw, .JSON, true)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return m, false
	}
	uri := libmsg.str_of(o, "uri")
	value, has_value := libmsg.obj_of(o, "value")
	if uri == "" || !has_value {
		return m, false
	}
	repo, _, _, _ := split_uri(uri)
	// The view the timeline's shape wants: the record under `record`, the
	// repository as the author.
	view := make(map[string]json.Value)
	defer delete(view)
	author := make(map[string]json.Value)
	defer delete(author)
	author["did"] = json.String(repo)
	author["handle"] = json.String(repo)
	view["uri"] = json.String(uri)
	view["cid"] = json.String(libmsg.str_of(o, "cid"))
	view["author"] = json.Object(author)
	view["record"] = json.Object(value)
	return post_message(json.Object(view), raw)
}

// split_uri takes an AT URI apart: `at://repo/collection/rkey`.
split_uri :: proc "contextless" (uri: string) -> (repo, collection, rkey: string, ok: bool) {
	if !libodin.has_prefix(uri, "at://") {
		return "", "", "", false
	}
	rest := uri[5:]
	a := 0
	for a < len(rest) && rest[a] != '/' {
		a += 1
	}
	if a >= len(rest) {
		return "", "", "", false
	}
	b := a + 1
	for b < len(rest) && rest[b] != '/' {
		b += 1
	}
	if b >= len(rest) || b + 1 >= len(rest) {
		return "", "", "", false
	}
	return rest[:a], rest[a + 1:b], rest[b + 1:], true
}
