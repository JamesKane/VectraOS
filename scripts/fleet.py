#!/usr/bin/env python3
# Drives the two-machine bench: waits for both to boot, announces a service on
# one, dials it by name from the other, and checks a line crosses.
import socket, time, os, sys, re, functools
print=functools.partial(print, flush=True)

BUILD="/Users/jkane/Development/odin/Vectra/build"
A=BUILD+"/console-a.sock"; B=BUILD+"/console-b.sock"

def connect(path, deadline):
    while time.time() < deadline:
        if os.path.exists(path):
            try:
                s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path)
                s.setblocking(False); return s
            except OSError: pass
        time.sleep(0.3)
    return None

class Console:
    def __init__(self, name, sock): self.name=name; self.s=sock; self.buf=""
    def pump(self, secs):
        end=time.time()+secs
        while time.time()<end:
            try:
                d=self.s.recv(65536)
                if d: self.buf+=d.decode(errors="replace")
            except BlockingIOError: time.sleep(0.05)
            except OSError: break
    def waitfor(self, text, secs):
        end=time.time()+secs
        while time.time()<end:
            self.pump(0.3)
            if text in self.buf: return True
        return False
    def send(self, line): self.s.sendall((line+"\n").encode())
    def cmd(self, line, secs=1.5):
        self.buf=""; self.send(line); self.pump(secs); return self.buf

def main():
    dl=time.time()+180
    sa=connect(A, dl); sb=connect(B, dl)
    if not sa or not sb: print("FLEET: consoles never appeared"); return 2
    a=Console("one", sa); b=Console("two", sb)
    print("connected to both consoles")
    # Boot may have already scrolled past on the log; poke each for a prompt.
    a.send(""); b.send("")
    if not a.waitfor("%", 180): print("machine one no prompt"); print(repr(a.buf[-300:])); return 2
    if not b.waitfor("%", 60): print("machine two no prompt"); print(repr(b.buf[-300:])); return 2
    print("both at a prompt")
    # Each kernel names its architecture in its first line. The bench wants
    # two, so the same tree is proven on both rather than one kernel twice.
    arches=[]
    for tag in ("a","b"):
        try:
            log=open(BUILD+"/serial-%s.log"%tag, errors="replace").read()
        except OSError:
            log=""
        m=re.search(r"Vectra [^ ]+ \((\w+)\) entering kmain", log)
        arches.append(m.group(1) if m else "?")
    print("machine one is %s, machine two is %s" % tuple(arches))
    time.sleep(1); a.pump(1); b.pump(1)
    # confirm each resolved its own name/ip from ndb
    a.send("cat /net/ether0/addr"); a.pump(2)
    # Announce the service on machine one, and wait until it is really
    # listening before machine two dials it -- a dial that races the announce
    # burns its retransmits on a port that is not open yet.
    a.send("netecho announce echo &"); a.pump(1)
    listening=False
    for _ in range(20):
        if "Listen" in a.cmd("cat /net/tcp/0/status"): listening=True; break
        time.sleep(0.5)
    print("machine one listening:", listening)
    # Dial in the background and read the echo off the console. A foreground
    # dial holds its reply read open, and a held read on a mounted server draws
    # the note-poll flood that can end it early. The backgrounded dial prints
    # what came back to the same console this is watching.
    b.buf=""
    b.send("netecho dial tcp!one!echo crossing &")
    b.waitfor("crossing", 20)
    b.pump(1)
    print("=== machine two output tail ===")
    print(b.buf[-600:])
    # The word appears once as the echoed command line and once as the reply.
    crossed=b.buf.count("crossing")>=2
    # And a ping by name the other way: machine one pings `two`, which
    # `/net/cs` resolves out of ndb, and counts the replies.
    a.buf=""
    a.send("ping -n 3 two")
    a.waitfor("received", 15)
    print("=== machine one ping ===")
    print(a.buf[-400:])
    pinged=a.buf.count("bytes from two")>=2
    # And the other way, so a failure says which side is deaf.
    b.buf=""
    b.send("ping -n 2 one")
    b.waitfor("received", 12)
    print("=== machine two ping ===")
    print(b.buf[-300:])
    for name,c in (("one",a),("two",b)):
        print("=== %s icmp stats / arp ===" % name)
        print(c.cmd("cat /net/icmp/stats").strip())
        print(c.cmd("cat /net/ether0/stats").strip())
        print(c.cmd("cat /dev/ether/stats").strip())
        print(c.cmd("cat /net/arp").strip())
    two=len(set(arches))==2 and "?" not in arches
    print("=== VERDICT:", ("LINE CROSSED" if crossed else "NO CROSSING")+", "+("PINGED BY NAME" if pinged else "NO PING")+", "+("TWO ARCHITECTURES" if two else "NOT TWO ARCHITECTURES"))
    # leave them; caller kills qemu
    return 0

sys.exit(main())
