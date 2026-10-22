// SPDX-License-Identifier: BSD-3-Clause

// vtest's one need that Swift can't reach (D121): a descriptor passed on
// a Unix socket (SCM_RIGHTS), whose control message's macros
// (CMSG_FIRSTHDR, CMSG_DATA) don't import into Swift. Hosted only.

#pragma once

// A descriptor received on `socket` with its one byte, close-on-exec; -1
// with errno set (ECONNRESET at the end, EPROTO if no descriptor came).
int td_vtest_receive_fd(int socket);
