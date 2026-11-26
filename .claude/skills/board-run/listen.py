# listen.py LOG SECONDS: append the board's serial console to LOG for
# SECONDS, holding the descriptor open at 115200 8N1 (macOS forgets a
# tty's settings when its last descriptor closes, so `stty -f` then `cat`
# records nothing). The device is $BOARD_TTY.
import os, sys, termios, time
tty = os.environ.get("BOARD_TTY", "/dev/cu.usbserial-ABSCDIMD")
fd = os.open(tty, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0; a[1] = 0; a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL; a[3] = 0
a[4] = termios.B115200; a[5] = termios.B115200
a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
out = open(sys.argv[1], "ab", buffering=0)
end = time.time() + float(sys.argv[2])
while time.time() < end:
    try:
        b = os.read(fd, 4096)
        if b: out.write(b)
    except BlockingIOError:
        pass
    time.sleep(0.02)
