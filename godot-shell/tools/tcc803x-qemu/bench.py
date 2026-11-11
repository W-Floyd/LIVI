#!/usr/bin/env python3 -I
"""Time a cold boot through run.sh: wall time to sys.boot_completed, guest/wall clock ratio, `input tap` latency.
usage: [QEMU=... SMP=n ...same env as run.sh] bench.py [runs]   (RAMDISK=ramdisk.emu.gz for the root console)"""
import os, re, subprocess, sys, threading, time
here = os.path.dirname(os.path.abspath(__file__))
for k, v in dict(TIMEOUT="600", RAMDISK="ramdisk.emu.gz").items(): os.environ.setdefault(k, v)
def once():
    p = subprocess.Popen([here + "/run.sh"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = bytearray(); t0 = time.time()
    def rd():
        while (c := os.read(p.stdout.fileno(), 65536)): buf.extend(c)
    threading.Thread(target=rd, daemon=True).start()
    def run(cmd, t=300):
        del buf[:]; s = time.time(); p.stdin.write((cmd + "; echo @@E$((6*7))\n").encode()); p.stdin.flush()
        while time.time() - s < t and b"@@E42" not in buf: time.sleep(.1)
        return time.time() - s, buf.decode(errors="replace")
    while not re.search(rb"(shell|root)@\S+:/ [\$#] ", buf): time.sleep(.2)
    r = {}; first = None
    while time.time() - t0 < 500:
        dt, o = run("cat /proc/uptime; getprop sys.boot_completed")
        m = re.search(r"^(\d+\.\d+) ", o, re.M)
        if m and first is None and time.time() - t0 > 10: first = (time.time() - t0, float(m[1]))
        if re.search(r"\n1\s*\r?\n", o):
            r["boot_s"] = round(time.time() - t0, 1)
            if first: r["clock"] = round((float(m[1]) - first[1]) / (time.time() - t0 - first[0]), 2)
            break
        time.sleep(2)
    time.sleep(10); r["tap_s"] = round(run("input tap 960 360")[0], 1)
    p.terminate(); return r
for i in range(int(sys.argv[1]) if len(sys.argv) > 1 else 1): print(once(), flush=True)
