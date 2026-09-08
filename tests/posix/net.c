/*
posixnet -- a socket client, the live check for the socket row.

`posixnet a.b.c.d port` opens a socket, connects to that address over
`/net`, and says whether the connection formed. It is not in the boot
self-test: a round trip wants a server, and the machine's always-on one
is `exportfs` on tcp564, whose bytes are 9P. So this proves `connect`
reaches the stack and forms a conversation, which is the client half of
`docs/DEVTOOLS.md` section 8's socket row. `sys/libposix`'s dial mirrors
`sys/libnet`'s, which the network tests already prove.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char **argv)
{
	if (argc != 3) {
		printf("usage: posixnet a.b.c.d port\n");
		return 1;
	}
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		printf("posixnet: socket failed\n");
		return 2;
	}
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((unsigned short)atoi(argv[2]));
	sa.sin_addr.s_addr = inet_addr(argv[1]);
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		printf("posixnet: connect to %s!%s failed\n", argv[1], argv[2]);
		close(fd);
		return 3;
	}
	printf("posixnet: connected to %s!%s\n", argv[1], argv[2]);
	close(fd);
	return 0;
}
