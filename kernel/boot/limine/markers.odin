/*
The request-section furniture: base revision tag and the delimiters that bound
the region the bootloader scans.

These live in three dedicated sections so `kernel/link_amd64.ld` can lay them
out in the one order the protocol accepts:

    .limine_requests_start   <- start marker
    .limine_requests         <- base revision tag, then every request
    .limine_requests_end     <- end marker

Under base revision 2 and above the delimiters are binding rather than
advisory, so a request that lands outside them is simply never seen -- it
compiles, it links, it boots, and its response stays nil. Every request must
therefore carry `@(link_section = ".limine_requests")`; see `kernel/main.odin`.

The whole region has to be writable: the bootloader fills in each request's
`response` pointer and stamps its answer into the base revision tag in place.
*/
package limine

@(export, link_section = ".limine_requests_start")
requests_start_marker := REQUESTS_START_MARKER

/*
The base revision handshake.

Word 2 goes out as the revision we want and comes back as 0 if the bootloader
can provide it. Word 1 comes back as the revision we were actually loaded
under. `kmain` checks both before trusting anything else in a response.
*/
@(export, link_section = ".limine_requests")
base_revision_tag := Base_Revision_Tag{BASE_REVISION_MAGIC_1, BASE_REVISION_MAGIC_2, BASE_REVISION}

@(export, link_section = ".limine_requests_end")
requests_end_marker := REQUESTS_END_MARKER
