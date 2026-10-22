// SPDX-License-Identifier: BSD-3-Clause

// The plumber's rules when it starts (D85): 9front's usual ones, in
// plumb(6)'s format. More are appended through its `rules` file.

extension Rules {
  public static let defaults = """
    # The plumber's rules (plumb(6)'s format; services/plumber/lib/Rules.swift).
    # A ruleset is lines up to a blank one; the first whose patterns hold
    # takes the message. Append more by writing the rules file.

    # A compiler's file:line: the editor, at the line.
    type is text
    data matches '([a-zA-Z0-9_./+-]+):([0-9]+)(:[0-9]+)?'
    arg isfile $1
    data set $file
    attr add addr=$2
    plumb to edit

    # A page of the manual, name(N): guide(4), which only shows it.
    type is text
    data matches '[a-zA-Z0-9_.-]+\\([1-8]\\)'
    plumb to man

    # A text file by name: the editor.
    type is text
    data matches '[a-zA-Z0-9_./+-]+\\.(swift|c|h|md|txt|rc|manifest)'
    arg isfile $0
    data set $file
    plumb to edit

    # The web and mail.
    type is text
    data matches '(https?|ftp)://[^ ]+'
    plumb to web

    type is text
    data matches 'mailto:[^ ]+'
    plumb to mail

    # Pictures.
    type is image/*
    plumb to image
    """
}
