/*
socket.c -- the client half of Berkeley sockets over Plan 9's dial.

`socket` reserves a descriptor by opening `/dev/null`, so the number is
real and closeable. `connect` reads the address back into a `host!port`
string, dials it through `/net/cs` and the conversation's `ctl` and
`data` -- the sequence `sys/libnet` uses -- and moves the resulting data
stream onto the socket's descriptor, so `read`, `write`, `send` and
`recv` on it carry the connection's bytes. See `docs/DEVTOOLS.md`
section 8.
*/
#include "posix_internal.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

unsigned short htons(unsigned short v) { return (unsigned short)((v << 8) | (v >> 8)); }
unsigned short ntohs(unsigned short v) { return htons(v); }
unsigned int htonl(unsigned int v)
{
	return ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | ((v >> 24) & 0xff);
}
unsigned int ntohl(unsigned int v) { return htonl(v); }

in_addr_t inet_addr(const char *s)
{
	unsigned int parts[4] = {0, 0, 0, 0};
	int p = 0;
	for (int i = 0; s[i] && p < 4; i++) {
		if (s[i] == '.') {
			p++;
		} else if (s[i] >= '0' && s[i] <= '9') {
			parts[p] = parts[p] * 10 + (unsigned int)(s[i] - '0');
		}
	}
	unsigned int a = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
	return htonl(a);
}

int socket(int domain, int type, int protocol)
{
	(void)protocol;
	if (domain != AF_INET || type != SOCK_STREAM) {
		errno = EPROTO;
		return -1;
	}
	/* A real descriptor to hand back and to close; `connect` fills it. */
	int fd = open("/dev/null", O_RDWR);
	if (fd < 0) {
		errno = (int)(-fd < 0 ? EMFILE : -fd);
		return -1;
	}
	return fd;
}

/* put_uint appends a decimal number to `p` at `n`, and answers the new n. */
static int put_uint(char *p, int n, unsigned int v)
{
	char tmp[12];
	int t = 0;
	if (v == 0) {
		tmp[t++] = '0';
	}
	while (v) {
		tmp[t++] = (char)('0' + v % 10);
		v /= 10;
	}
	while (t > 0) {
		p[n++] = tmp[--t];
	}
	return n;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
	(void)len;
	const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
	if (in->sin_family != AF_INET) {
		errno = EPROTO;
		return -1;
	}
	unsigned int a = ntohl(in->sin_addr.s_addr);
	unsigned int port = ntohs(in->sin_port);

	/* The dial string: `tcp!a.b.c.d!port`, written to /net/cs. */
	char dial[64];
	int n = 0;
	const char *pre = "tcp!";
	for (int i = 0; pre[i]; i++) {
		dial[n++] = pre[i];
	}
	n = put_uint(dial, n, (a >> 24) & 0xff);
	dial[n++] = '.';
	n = put_uint(dial, n, (a >> 16) & 0xff);
	dial[n++] = '.';
	n = put_uint(dial, n, (a >> 8) & 0xff);
	dial[n++] = '.';
	n = put_uint(dial, n, a & 0xff);
	dial[n++] = '!';
	n = put_uint(dial, n, port);
	dial[n] = 0;

	int cs = open("/net/cs", O_RDWR);
	if (cs < 0) {
		errno = ENOENT; /* no network here. */
		return -1;
	}
	if (write(cs, dial, n) != n) {
		close(cs);
		errno = EIO;
		return -1;
	}
	/* cs answers `clone remote`: the clone file to take a conversation
	   from, and the address to connect it to. */
	char ans[128];
	long an = read(cs, ans, sizeof(ans) - 1);
	close(cs);
	if (an <= 0) {
		errno = ECONNREFUSED;
		return -1;
	}
	ans[an] = 0;
	int sp = 0;
	while (ans[sp] && ans[sp] != ' ') {
		sp++;
	}
	char clone[80];
	int ci = 0;
	for (int i = 0; i < sp && ci < (int)sizeof(clone) - 1; i++) {
		clone[ci++] = ans[i];
	}
	clone[ci] = 0;
	const char *remote = ans[sp] == ' ' ? ans + sp + 1 : "";

	int cl = open(clone, O_RDWR);
	if (cl < 0) {
		errno = ECONNREFUSED;
		return -1;
	}
	char num[16];
	long nn = read(cl, num, sizeof(num) - 1);
	if (nn <= 0) {
		close(cl);
		errno = ECONNREFUSED;
		return -1;
	}
	num[nn] = 0;
	/* The conversation directory is /net/tcp/<num>. */
	int convno = 0;
	for (int i = 0; num[i] >= '0' && num[i] <= '9'; i++) {
		convno = convno * 10 + (num[i] - '0');
	}
	close(cl);

	char ctlpath[48];
	int cn = 0;
	const char *cp = "/net/tcp/";
	for (int i = 0; cp[i]; i++) {
		ctlpath[cn++] = cp[i];
	}
	cn = put_uint(ctlpath, cn, (unsigned int)convno);
	int dirlen = cn;
	const char *cs2 = "/ctl";
	for (int i = 0; cs2[i]; i++) {
		ctlpath[cn++] = cs2[i];
	}
	ctlpath[cn] = 0;

	int ctl = open(ctlpath, O_WRONLY);
	if (ctl < 0) {
		errno = ECONNREFUSED;
		return -1;
	}
	char cmd[80];
	int mn = 0;
	const char *cc = "connect ";
	for (int i = 0; cc[i]; i++) {
		cmd[mn++] = cc[i];
	}
	for (int i = 0; remote[i] && remote[i] != '\n' && mn < (int)sizeof(cmd) - 1; i++) {
		cmd[mn++] = remote[i];
	}
	int wrote = write(ctl, cmd, mn) == mn;
	close(ctl);
	if (!wrote) {
		errno = ECONNREFUSED;
		return -1;
	}

	/* The data stream, moved onto the socket's descriptor. */
	char datapath[48];
	memcpy(datapath, ctlpath, dirlen);
	const char *dp = "/data";
	int dn = dirlen;
	for (int i = 0; dp[i]; i++) {
		datapath[dn++] = dp[i];
	}
	datapath[dn] = 0;
	int data = open(datapath, O_RDWR);
	if (data < 0) {
		errno = ECONNREFUSED;
		return -1;
	}
	dup2(data, fd);
	close(data);
	return 0;
}

long send(int fd, const void *buf, size_t n, int flags)
{
	(void)flags;
	return write(fd, buf, n);
}

long recv(int fd, void *buf, size_t n, int flags)
{
	(void)flags;
	return read(fd, buf, n);
}

int shutdown(int fd, int how)
{
	(void)how;
	(void)fd;
	return 0;
}
