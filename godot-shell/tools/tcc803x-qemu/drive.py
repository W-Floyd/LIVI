#!/usr/bin/env python3
"""Drive the root console of run.sh from a script file and take screenshots.
usage: EMMC=... BOOT_DIR=... RAMDISK=ramdisk.emu.gz TIMEOUT=2400 [PROMPT_TIMEOUT=120] drive.py script.txt out.log
script lines: a shell command (waits for the prompt), `#sleep N`, `#shot NAME` (NAME.ppm/.png next to out.log),
`#savevm TAG` (native only, qcow2 EMMC: snapshot the running machine, see README "Snapshot").
Needs the ramdisk from build-ramdisk.py (root console) and docker (the container is named tccq) or, with QEMU=<native
qemu-system-arm from build-native.sh>, no docker at all.

usage: QEMU=... EMMC=<qcow2> LOADVM=<tag> BOOT_DIR=... RAMDISK=ramdisk.emu.gz MICOM_FAKE=<micom-fake> \
       drive.py --flow stock-ui.yaml TARGET|all OUTDIR
drives the stock UI to each target screen of the graph (stock-ui.yaml), from the snapshot each time, with the fake micom
playing the screen's state, checks it arrived and screenshots OUTDIR/TARGET.png (README "Stock UI flows")."""
import subprocess, sys, time, threading, os, re, json, socket, tempfile, collections
import zlib, struct
def ppm2png(a, b):
    d = open(a, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", d)
    w, h = int(m.group(1)), int(m.group(2)); px = d[m.end():]
    raw = b"".join(b"\0" + px[y*w*3:(y+1)*w*3] for y in range(h))
    def ck(t, x): return struct.pack(">I", len(x)) + t + x + struct.pack(">I", zlib.crc32(t + x))
    open(b, "wb").write(b"\x89PNG\r\n\x1a\n" + ck(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ck(b"IDAT", zlib.compress(raw, 6)) + ck(b"IEND", b""))

def load_yaml(path):
    # No PyYAML here: Ruby's stdlib reads it.
    return json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.dump(YAML.load_file(ARGV[0]))", path]))

class Machine:
    """run.sh resumed from LOADVM, its console on a pipe, its monitor and micom UART on sockets."""
    MON, MICOM = "/tmp/tccq.mon", "/tmp/tccq.micom"  # unix socket paths are limited to ~100 bytes
    def __init__(self, log):
        env = dict(os.environ, MON=self.MON, MICOM="unix:%s,server=on,wait=off" % self.MICOM, TIMEOUT=os.environ.get("TIMEOUT", "14400"))
        self.p = subprocess.Popen([os.path.join(os.path.dirname(os.path.abspath(__file__)), "run.sh")], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        self.buf, self.log, self.fake = bytearray(), open(log, "wb"), None
        threading.Thread(target=self._read, daemon=True).start()
        time.sleep(3)
    def _read(self):
        while True:
            c = os.read(self.p.stdout.fileno(), 4096)
            if not c: break
            self.buf.extend(c); self.log.write(c); self.log.flush()
    def sh(self, cmd, timeout=120):
        """Runs cmd on the root console, returns its output."""
        mark = "@@F%d" % time.monotonic_ns()
        del self.buf[:]
        self.p.stdin.write(("%secho %s\n" % (cmd + "; " if cmd else "\n", mark)).encode()); self.p.stdin.flush()
        t = time.time()
        while time.time() - t < timeout:
            m = re.search(rb"\n" + mark.encode(), bytes(self.buf))
            if m: return bytes(self.buf[:m.start()]).decode(errors="replace").replace("\r", "")
            time.sleep(0.3)
        raise TimeoutError(cmd)
    def mon(self, cmd, timeout=300):
        s = socket.socket(socket.AF_UNIX); s.connect(self.MON); s.settimeout(1); time.sleep(.3)
        s.send((cmd + "\n").encode()); r, t = b"", time.time()
        while r.count(b"(qemu)") < 2 and time.time() - t < timeout:
            try: r += s.recv(4096)
            except socket.timeout: pass
        s.close()
    def shot(self, png):
        ppm = png[:-4] + ".ppm"
        self.mon("screendump " + ppm); time.sleep(1)
        ppm2png(ppm, png); os.remove(ppm)
    def micom(self, state, out):
        """(Re)starts the fake micom with a state's scenario."""
        if self.fake: self.fake.terminate(); self.fake.wait()
        sc = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False); json.dump(state.get("scenario", []), sc); sc.close()
        args = [os.environ["MICOM_FAKE"], "-connect", "unix:" + self.MICOM, "-scenario", sc.name, "-record", out + ".micom.jsonl"]
        if os.environ.get("MICOM_CAPTURE") and state.get("still"):
            args += ["-replay", os.environ["MICOM_CAPTURE"], "-still", state["still"]]
        self.fake = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=open(out + ".micom.log", "w"))
    def close(self):
        if self.fake: self.fake.terminate()
        self.p.terminate()

def flow_view(m):
    """The focused window and the shown view ids of the top activity."""
    focus = re.search(r"mCurrentFocus=Window\{\S+ \S+ ([^}\s]+)", m.sh("dumpsys window windows"))
    ids = set(re.findall(r"\{[0-9a-f]+ V[^}]*app:id/(\w+)", m.sh("dumpsys activity top")))
    return focus.group(1) if focus else "", ids

def flow_arrived(m, exp, tries=6):
    for _ in range(tries):
        focus, ids = flow_view(m)
        ok = re.search(exp.get("activity", ""), focus) and (exp.get("dialog") or set(exp.get("ids", [])) <= ids)
        if ok: return True, focus
        time.sleep(3)
    return False, focus

def flow_do(m, steps):
    for st in steps:
        if "tap" in st: m.sh("input tap %d %d" % tuple(st["tap"]))
        elif "key" in st: m.sh("input keyevent %s" % {"BACK": 4, "HOME": 3}.get(st["key"], st["key"]))
        elif "shell" in st: m.sh(st["shell"])
        elif "wait" in st: time.sleep(st["wait"])
        else: raise ValueError("unknown step %r" % st)

def flow_path(g, target):
    """Shortest list of transitions from the start screen to target."""
    prev, q = {g["start"]: None}, collections.deque([g["start"]])
    while q:
        a = q.popleft()
        for t in g["transitions"]:
            if t["from"] == a and t["to"] not in prev:
                prev[t["to"]] = t; q.append(t["to"])
    if target not in prev: return None
    out, s = [], target
    while prev[s]: out.append(prev[s]); s = prev[s]["from"]
    return out[::-1]

def flow_main(yml, target, outdir):
    g = load_yaml(yml)
    os.makedirs(outdir, exist_ok=True)
    tag = os.environ.get("LOADVM", "ui")
    m = Machine(os.path.join(outdir, "console.log"))
    targets = [s for s in g["screens"] if s != g["start"]] if target == "all" else [target]
    report, first = {}, True
    try:
        m.sh("", timeout=60)
        for tg in targets:
            out = os.path.join(outdir, tg)
            if not first: m.mon("loadvm " + tag); time.sleep(2); m.sh("", timeout=60)
            first = False
            scr = g["screens"][tg]
            m.micom(g.get("states", {}).get(scr.get("state"), {}), out); time.sleep(3)
            for need in scr.get("needs", []): flow_do(m, g["modes"][need]["setup"])
            path = flow_path(g, tg)
            if path is None: report[tg] = "no path"; continue
            res = "reached"
            for t in path:
                flow_do(m, t["do"])
                ok, focus = flow_arrived(m, g["screens"][t["to"]].get("expect", {}))
                if not ok: res = "stuck before %s (focus %s)" % (t["to"], focus); break
            m.shot(out + ".png")
            report[tg] = res
            print(tg, res, flush=True)
    finally:
        m.close()
        json.dump({"reached": report, "unreachable": g.get("unreachable", {})}, open(os.path.join(outdir, "report.json"), "w"), indent=1)

if sys.argv[1] == "--flow":
    flow_main(sys.argv[2], sys.argv[3], sys.argv[4])
    sys.exit(0)
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
