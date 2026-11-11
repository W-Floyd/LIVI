#!/usr/bin/env python3
"""Drive the root console of run.sh from a script file and take screenshots.
usage: EMMC=... BOOT_DIR=... RAMDISK=ramdisk.emu.gz TIMEOUT=2400 [PROMPT_TIMEOUT=120] drive.py script.txt out.log
script lines: a shell command (waits for the prompt), `#sleep N`, `#shot NAME` (NAME.ppm/.png next to out.log),
`#savevm TAG` (native only, qcow2 EMMC: snapshot the running machine, see README "Snapshot").
Needs the ramdisk from build-ramdisk.py (root console) and docker (the container is named tccq) or, with QEMU=<native
qemu-system-arm from build-native.sh>, no docker at all."""
import subprocess, sys, time, threading, os, re
import zlib, struct
def ppm2png(a, b):
    d = open(a, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", d)
    w, h = int(m.group(1)), int(m.group(2)); px = d[m.end():]
    raw = b"".join(b"\0" + px[y*w*3:(y+1)*w*3] for y in range(h))
    def ck(t, x): return struct.pack(">I", len(x)) + t + x + struct.pack(">I", zlib.crc32(t + x))
    open(b, "wb").write(b"\x89PNG\r\n\x1a\n" + ck(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ck(b"IDAT", zlib.compress(raw, 6)) + ck(b"IEND", b""))
cmds = [l.rstrip("\n") for l in open(sys.argv[1])]
out = open(sys.argv[2], "wb")
NATIVE = bool(os.environ.get("QEMU"))
MON = "/tmp/tccq.mon"  # unix socket paths are limited to ~100 bytes
env = dict(os.environ, DOCKER_FLAGS="-i --name tccq", EXTRA="" if NATIVE else "-monitor unix:/run/q/mon,server,nowait", MON=MON)
def screendump(path):
    if NATIVE:
        import socket
        s = socket.socket(socket.AF_UNIX); s.connect(MON); time.sleep(.5)
        s.send(("screendump %s\n" % path).encode()); time.sleep(3); s.close()
        return
    subprocess.run(["docker","exec","tccq","python3","-c","import socket,time;s=socket.socket(socket.AF_UNIX);s.connect('/run/q/mon');time.sleep(.5);s.send(b'screendump /run/q/x.ppm\\n');time.sleep(10)"])
    subprocess.run(["docker","cp","tccq:/run/q/x.ppm", path])
p = subprocess.Popen([os.path.join(os.path.dirname(os.path.abspath(__file__)), "run.sh")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
buf = bytearray()
def rd():
    while True:
        c = os.read(p.stdout.fileno(), 4096)
        if not c: break
        buf.extend(c); out.write(c); out.flush()
threading.Thread(target=rd, daemon=True).start()
def wait(pat, t):
    s = time.time()
    while time.time()-s < t:
        if re.search(pat, bytes(buf)): return True
        time.sleep(0.5)
    return False
PT = float(os.environ.get("PROMPT_TIMEOUT", "120"))
print("prompt", wait(rb"(shell|root)@\S+:/ [\$#] ", 400), flush=True)
# The kernel log keeps interleaving with the prompt: detect command end with a marker instead.
END = "; echo @@E$((6*7))"
for c in cmds:
    if c.startswith("#shot"):
        n = c.split()[1]
        d = os.path.dirname(os.path.abspath(sys.argv[2]))
        screendump(d+"/%s.ppm" % n)
        ppm2png(d+"/%s.ppm" % n, d+"/%s.png" % n)
        continue
    if c.startswith("#savevm"):
        import socket
        m = socket.socket(socket.AF_UNIX); m.connect(MON); m.settimeout(1); time.sleep(.5)
        m.send(("savevm %s\n" % c.split()[1]).encode())
        r = b""
        while b"(qemu)" not in r[10:]:
            try: r += m.recv(4096)
            except socket.timeout: pass
        time.sleep(5); continue
    if c.startswith("#sleep"): time.sleep(float(c.split()[1])); continue
    del buf[:]
    p.stdin.write((c+END+"\n").encode()); p.stdin.flush()
    print(c, wait(rb"@@E42", PT), flush=True)
p.terminate()
