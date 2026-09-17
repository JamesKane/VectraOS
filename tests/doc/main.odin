/*
doctest -- the reader's document model and its layout, from ring 3.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first step that did not hold. A gemtext page, a markdown page
and an HTML page each parse to the blocks their lines mean. Each lays out to the rows a
narrow column gives them, counted here by hand. That is `docs/WEB.md` step
1's "a page of each kind lays out to the numbers".
*/
package doctest

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libgemtext"
import "vsys:libhtml"
import "vsys:libmark"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

GEMTEXT :: "# Title\n\nSome text that is long enough to wrap when the column is narrow indeed.\n=> gemini://example.org/ Example\n=> /bare\n* one\n* two\n> quoted\n```\ncode line\n```\n"

HTML :: "<!DOCTYPE html>\n<html><head><meta charset=utf-8><title>Page &amp; Co</title>\n<style>p { color: red }</style><script>var s = \"<p>not text</p>\";</script></head>\n<body>\n<h1>Hello</h1>\n<p>Some   <b>bold</b>\ntext with a <a href=\"/next\">link</a>.</p>\n<ul><li>one</li><li>two</ul>\n<blockquote><p>quoted</p></blockquote>\n<pre>\n  code\nline</pre>\n<hr>\n<img src=\"p.png\" alt=\"pic\">\n<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>\n<!-- a comment <p>hidden</p> -->\n<p>&#169; 2026 &mdash; done</p>\n</body></html>\n"

MARKDOWN :: "# Doc\n\nSee [the site](https://x.y/ \"a title\") now.\nMore *here*.\n\n- a\n1. b\n\n---\n![pic](p.png)\n"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// -- Gemtext ---------------------------------------------------------------
	{
		d: libdoc.Doc
		libdoc.doc_init(&d)
		libgemtext.parse(&d, GEMTEXT)
		want(len(d.blocks) == 9, "gemtext: nine lines are nine blocks")
		want(d.blocks[0].kind == .Heading && d.blocks[0].level == 1 && libdoc.block_text(&d, 0) == "Title", "a heading keeps its level and its text")
		want(libdoc.title(&d) == "Title", "and the first heading is the title")
		want(d.blocks[1].kind == .Text && libdoc.block_text(&d, 1) == "", "a blank line is an empty paragraph")
		want(d.blocks[3].kind == .Link && libdoc.block_href(&d, 3) == "gemini://example.org/" && libdoc.block_text(&d, 3) == "Example", "a link keeps its URL and its name")
		want(d.blocks[4].kind == .Link && libdoc.block_text(&d, 4) == "/bare", "a link with no name shows its URL")
		want(d.blocks[5].kind == .Item && d.blocks[6].kind == .Item, "list items are items")
		want(d.blocks[7].kind == .Quote && libdoc.block_text(&d, 7) == "quoted", "a quote drops its marker")
		want(d.blocks[8].kind == .Pre && libdoc.block_text(&d, 8) == "code line", "a fenced block keeps its line")

		l: libdoc.Layout
		libdoc.layout_init(&l)
		n := libdoc.layout(&l, &d, 20)
		want(n == 12, "at twenty columns the page is twelve rows")
		want(libdoc.row_text(&l, 0) == "# Title", "the heading wears its marks")
		want(libdoc.row_text(&l, 2) == "Some text that is", "a paragraph breaks at the last space that fits")
		want(libdoc.row_text(&l, 3) == "long enough to wrap", "and again")
		want(libdoc.row_text(&l, 5) == "narrow indeed.", "to its last row")
		want(libdoc.row_text(&l, 6) == "=> Example" && l.rows[6].block == 3 && l.rows[6].first, "a link row names its block")
		want(libdoc.row_text(&l, 11) == "code line", "and the preformatted line is the last row")

		// A wrapped link's continuation rows are indented under its mark.
		n = libdoc.layout(&l, &d, 8)
		want(n > 12 && libdoc.row_text(&l, 0) == "# Title" , "a narrow column still lays out")
		found := false
		for i in 0 ..< n {
			if l.rows[i].block == 3 && !l.rows[i].first {
				found = libdoc.row_text(&l, i)[:3] == "   "
				break
			}
		}
		want(found, "and a link's second row is indented under its mark")
		libdoc.layout_free(&l)
		libdoc.doc_free(&d)
	}

	// -- Markdown --------------------------------------------------------------
	{
		d: libdoc.Doc
		libdoc.doc_init(&d)
		libmark.parse(&d, MARKDOWN)
		want(len(d.blocks) == 7, "markdown: a heading, a paragraph, its link, two items, a rule and an image")
		want(d.blocks[0].kind == .Heading && libdoc.title(&d) == "Doc", "the heading is the title")
		want(d.blocks[1].kind == .Text && libdoc.block_text(&d, 1) == "See the site now. More here.", "lines join into one paragraph, markers dropped, a link reduced to its name")
		want(d.blocks[2].kind == .Link && libdoc.block_text(&d, 2) == "the site" && libdoc.block_href(&d, 2) == "https://x.y/", "and the link follows the paragraph, its title left out of the URL")
		want(d.blocks[3].kind == .Item && libdoc.block_text(&d, 3) == "a" && d.blocks[4].kind == .Item && libdoc.block_text(&d, 4) == "b", "dashed and numbered items are items")
		want(d.blocks[5].kind == .Rule, "three dashes are a rule")
		want(d.blocks[6].kind == .Image && libdoc.block_href(&d, 6) == "p.png" && libdoc.block_text(&d, 6) == "pic", "an image keeps its source and its alt")

		l: libdoc.Layout
		libdoc.layout_init(&l)
		n := libdoc.layout(&l, &d, 40)
		want(n == 7, "at forty columns the page is seven rows")
		want(libdoc.row_text(&l, 2) == "=> the site", "the link is a row to press")
		want(len(libdoc.row_text(&l, 5)) == 40 && libdoc.row_text(&l, 5)[0] == '-', "the rule is dashes across the width")
		want(libdoc.row_text(&l, 6) == "[image] pic", "and the image is named")
		libdoc.layout_free(&l)
		libdoc.doc_free(&d)
	}

	// -- HTML ------------------------------------------------------------------
	{
		d: libdoc.Doc
		libdoc.doc_init(&d)
		libhtml.parse(&d, HTML)
		want(len(d.blocks) == 12, "html: twelve blocks, the head, the comment and the script left out")
		want(libdoc.title(&d) == "Page & Co", "the title is the page's, its reference decoded")
		want(d.blocks[0].kind == .Heading && d.blocks[0].level == 1 && libdoc.block_text(&d, 0) == "Hello", "a heading keeps its level")
		want(d.blocks[1].kind == .Text && libdoc.block_text(&d, 1) == "Some bold text with a link.", "a paragraph collapses its space, drops emphasis and keeps a link's name")
		want(d.blocks[2].kind == .Link && libdoc.block_text(&d, 2) == "link" && libdoc.block_href(&d, 2) == "/next", "and the link follows it")
		want(d.blocks[3].kind == .Item && libdoc.block_text(&d, 3) == "one" && d.blocks[4].kind == .Item && libdoc.block_text(&d, 4) == "two", "items are items, the last unclosed")
		want(d.blocks[5].kind == .Quote && libdoc.block_text(&d, 5) == "quoted", "a paragraph in a quote is a quote")
		want(d.blocks[6].kind == .Pre && libdoc.block_text(&d, 6) == "  code\nline", "preformatted text keeps its space, less the tag's own newline")
		want(d.blocks[7].kind == .Rule, "hr is a rule")
		want(d.blocks[8].kind == .Image && libdoc.block_text(&d, 8) == "pic" && libdoc.block_href(&d, 8) == "p.png", "an image keeps its alt and its source")
		want(d.blocks[9].kind == .Text && libdoc.block_text(&d, 9) == "a | b" && libdoc.block_text(&d, 10) == "1 | 2", "a table row is its cells parted by a bar")
		want(libdoc.block_text(&d, 11) == "\u00a9 2026 \u2014 done", "a numbered and a named reference decode")

		l: libdoc.Layout
		libdoc.layout_init(&l)
		n := libdoc.layout(&l, &d, 40)
		want(n == 13, "at forty columns the page is thirteen rows")
		want(libdoc.row_text(&l, 2) == "=> link", "the link is a row to press")
		want(libdoc.row_text(&l, 6) == "  code" && libdoc.row_text(&l, 7) == "line", "the preformatted lines are rows as they were")
		want(libdoc.row_text(&l, 9) == "[image] pic", "and the image is named")
		libdoc.layout_free(&l)
		libdoc.doc_free(&d)
	}

	libuser.exits("ok")
}
