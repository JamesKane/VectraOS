/*
doctest -- the reader's document model and its layout, from ring 3.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first step that did not hold. A gemtext page, a markdown page
and an HTML page each parse to the blocks their lines mean. Three small PNGs
decode to their pixels, one of each shape a page uses. Each lays out to the rows a
narrow column gives them, counted here by hand. That is `docs/WEB.md` step
1's "a page of each kind lays out to the numbers".
*/
package doctest

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libgemtext"
import "vsys:libhtml"
import "vsys:libimage"
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

// Three PNGs, each with its stream in two IDAT chunks. RGBA with the Sub,
// Up and Paeth filters, pixel (x, y) being (60x, 100y, 30(x+y), 255-40x).
// A two-bit palette with a tRNS alpha and the Average filter. And
// sixteen-bit gray.
PNG_RGBA := [?]u8{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x08, 0x06, 0x00, 0x00, 0x00, 0xb4, 0xf4, 0xae, 0xc6, 0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0x60, 0x60, 0xf8, 0x6f, 0xc3, 0x20, 0x77, 0x03, 0x86, 0x99, 0x18, 0x49, 0x86, 0xa0, 0x7b, 0x00, 0x00, 0x00, 0x0f, 0x49, 0x44, 0x41, 0x54, 0x52, 0xe4, 0x18, 0x90, 0x31, 0x0b, 0x98, 0xc1, 0x80, 0xc0, 0x00, 0xfc, 0x03, 0x07, 0x81, 0xd8, 0x9b, 0x76, 0xa5, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82}
PNG_PAL := [?]u8{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x02, 0x03, 0x00, 0x00, 0x00, 0x0f, 0xd8, 0xe5, 0xb7, 0x00, 0x00, 0x00, 0x0c, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xfb, 0x00, 0x60, 0xf6, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0xff, 0x80, 0x08, 0x0f, 0xb3, 0x6a, 0x00, 0x00, 0x00, 0x06, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x16, 0x60, 0xd8, 0xc8, 0x0f, 0x47, 0xfa, 0x00, 0x00, 0x00, 0x06, 0x49, 0x44, 0x41, 0x54, 0x00, 0x00, 0x00, 0xf0, 0x00, 0xc4, 0x19, 0x3b, 0x6c, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82}
PNG_G16 := [?]u8{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x1b, 0x97, 0x2b, 0x00, 0x00, 0x00, 0x07, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x68, 0x60, 0x68, 0x81, 0xcb, 0x68, 0x00, 0x00, 0x00, 0x08, 0x49, 0x44, 0x41, 0x54, 0xf8, 0xff, 0x1f, 0x00, 0x05, 0x04, 0x02, 0x7f, 0x60, 0x2b, 0xfe, 0xc7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82}

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

	// -- PNG -------------------------------------------------------------------
	{
		img, ok := libimage.decode_png(PNG_RGBA[:], context.allocator)
		want(ok && img.w == 4 && img.h == 3, "png: an RGBA picture decodes to its size")
		good := true
		for y in 0 ..< 3 {
			for x in 0 ..< 4 {
				o := (y * 4 + x) * 4
				if int(img.pix[o]) != x * 60 || int(img.pix[o + 1]) != y * 100 || int(img.pix[o + 2]) != (x + y) * 30 || int(img.pix[o + 3]) != 255 - x * 40 {
					good = false
				}
			}
		}
		want(good, "and every pixel is what was encoded, through the Sub, Up and Paeth filters")
		libimage.image_free(&img, context.allocator)

		pal, pok := libimage.decode_png(PNG_PAL[:], context.allocator)
		want(pok && pal.w == 2 && pal.h == 2, "a two-bit palette picture decodes")
		want(pal.pix[0] == 255 && pal.pix[1] == 0 && pal.pix[4] == 0 && pal.pix[5] == 255 && pal.pix[7] == 128 && pal.pix[10] == 255 && pal.pix[12] == 255 && pal.pix[15] == 255, "to its palette's colours, with tRNS as alpha")
		libimage.image_free(&pal, context.allocator)

		g16, gok := libimage.decode_png(PNG_G16[:], context.allocator)
		want(gok && g16.w == 3 && g16.pix[0] == 0 && g16.pix[4] == 128 && g16.pix[8] == 255 && g16.pix[11] == 255, "and sixteen-bit gray takes its high byte")
		libimage.image_free(&g16, context.allocator)

		bad: [8]u8
		_, bok := libimage.decode_png(bad[:], context.allocator)
		want(!bok, "and bytes that are no PNG are refused")
	}

	libuser.exits("ok")
}
