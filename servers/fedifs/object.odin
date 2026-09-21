/*
Any object by URL: `docs/WEB.md` section 7's "anything public on any
instance is a GET with Accept: application/activity+json", so an actor
or an object anywhere in the fediverse is a message directory, whether
or not the person's instance knows it.

`object [name] url-or-path` fetches the object and puts it in the
conversation named, the URL's host when no name is given. A Note, an
Article or a Question is a message: who it is attributed to as `from`,
its `published` as the date, its summary as the subject, its content
as an HTML body, its URL and its attachments as links, and what it
replies to as `replyto`, by the URL's hash. An actor is a message too:
its name as the subject, its summary as the body, its page as a link.
A saved object's path is the offline proof.
*/
package fedifs

import "core:encoding/json"
import "vsys:libmsg"
import "vsys:vectra9"

ACTIVITY_JSON :: "Accept: application/activity+json\n"

// fetch_object reads one object and puts it in the conversation.
fetch_object :: proc(f: ^Fetch) -> vectra9.Errno {
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text: []u8
	ok: bool
	if libmsg.is_url(source) {
		status: int
		text, status, ok = libmsg.request(f.io, source, "", ACTIVITY_JSON, "")
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
	m, made := object_message(string(text))
	if !made {
		return vectra9.EINVAL
	}
	c := libmsg.conv(&net, name)
	i := libmsg.conv_index(&net, name)
	libmsg.add(&net, c, m)
	libmsg.resolve_replies(c)
	src := &sources[i]
	src.len = copy(src.text[:], source)
	rebuild_status()
	return 0
}

// object_message makes the message of an ActivityStreams object.
object_message :: proc(raw: string) -> (m: libmsg.Msg, ok: bool) {
	v, err := json.parse_string(raw, .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return m, false
	}
	id := libmsg.str_of(o, "id")
	kind := libmsg.str_of(o, "type")
	if id == "" || kind == "" {
		return m, false
	}
	m.date_text = libmsg.clone(libmsg.str_of(o, "published"))
	m.date, _ = libmsg.parse_date(m.date_text)
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(m.date, id, idbuf[:]))
	m.raw = libmsg.clone(raw)
	links := make([dynamic]u8, 0, 256)
	switch kind {
	case "Person", "Service", "Group", "Organization", "Application":
		// An actor: named, described, and a page on the web.
		m.from = libmsg.clone(libmsg.str_of(o, "preferredUsername"))
		m.subject = libmsg.clone(libmsg.str_of(o, "name"))
		m.body = libmsg.clone(libmsg.str_of(o, "summary"))
		m.type = libmsg.clone("text/html")
		libmsg.put_link(&links, libmsg.str_of(o, "url"))
	case:
		// A Note, an Article, a Question: content, from whoever it is
		// attributed to, answering what it replies to.
		m.from = libmsg.clone(libmsg.str_of(o, "attributedTo"))
		m.subject = libmsg.clone(libmsg.str_of(o, "summary"))
		if m.subject == "" {
			m.subject = libmsg.clone(libmsg.str_of(o, "name"))
		}
		m.body = libmsg.clone(libmsg.str_of(o, "content"))
		m.type = libmsg.clone("text/html")
		m.replyto = libmsg.clone(libmsg.str_of(o, "inReplyTo"))
		libmsg.put_link(&links, libmsg.str_of(o, "url"))
		if attachments, has := libmsg.arr_of(o, "attachment"); has {
			for item in attachments {
				if a, is := item.(json.Object); is {
					libmsg.put_link(&links, libmsg.str_of(a, "url"))
				}
			}
		}
	}
	m.links = string(links[:])
	return m, true
}
