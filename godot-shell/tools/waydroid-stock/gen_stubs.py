#!/usr/bin/env python3
"""Generate stub smali for the vendor (non-AOSP) classes an app references.

usage: gen_stubs.py <app-smali-dir> <fw-smali-root> <out-dir> <target-classes.txt>
target-classes.txt lists the classes the Waydroid framework already has (internal names); anything else the firmware defines is stubbed.
Signatures, fields, constants and interface/abstract-ness are kept; bodies return defaults.
"""
import os, re, sys, collections

app_dir, fw_root, out_dir, target = sys.argv[1:5]
res_dir = sys.argv[5] if len(sys.argv) > 5 else None
api_tsv = sys.argv[6] if len(sys.argv) > 6 else None
# optional table of fixed return values: 'Lpkg/Cls;->name(desc)ret = value' per line (value: integer, true/false)
VALUES = {}
if len(sys.argv) > 7 and os.path.exists(sys.argv[7]):
    for l in open(sys.argv[7]):
        l = l.split('#')[0].strip()
        if '=' in l:
            k, v = [x.strip() for x in l.split('=')]
            VALUES[k] = {'true': 1, 'false': 0}.get(v, None) if v in ('true', 'false') else int(v, 0)
api_sup, api_final = {}, set()
if api_tsv:
    for l in open(api_tsv):
        p = l.rstrip('\n').split('\t')
        if p[0] == 'C': api_sup[p[1][1:-1]] = p[2][1:-1] if p[2] != 'None' else None
        elif p[0] == 'M' and len(p) > 3 and p[3] == 'final': api_final.add((p[1][1:-1], p[2]))
HAVE = set(open(target).read().split())
SKIP = ('java/', 'javax/', 'dalvik/', 'libcore/', 'sun/', 'junit/', 'org/apache/', 'org/json/', 'org/w3c/', 'org/xml/', 'org/kxml2/', 'org/bouncycastle/', 'com/android/org/', 'com/android/okhttp/', 'org/conscrypt/')
TYPE = re.compile(r'L([A-Za-z0-9_/$]+);')

def walk(d):
    for r, _, fs in os.walk(d):
        for f in fs:
            if f.endswith('.smali'):
                yield os.path.join(r, f)

def cname(text):
    return re.search(r'^\.class (?:\S+ )*?L([^;]+);', text, re.M).group(1)

app_text = {p: open(p).read() for p in walk(app_dir)}
app_classes = {cname(t) for t in app_text.values()}
fw = {}
for p in walk(fw_root):
    t = open(p).read()
    c = cname(t)
    if c not in HAVE and not c.startswith(SKIP) and c not in fw:
        fw[c] = t

def layout_seeds():
    if not res_dir: return set()
    out = set()
    for r, _, fs in os.walk(res_dir):
        if '/layout' not in r and '/xml' not in r and '/menu' not in r: continue
        for f in fs:
            for t in re.findall(r'<([A-Za-z][A-Za-z0-9_.]*)', open(os.path.join(r, f), errors='replace').read()):
                if '.' in t: out.add(t.replace('.', '/'))
                else: out.update('%s/%s' % (p, t) for p in ('android/view', 'android/widget', 'android/webkit', 'android/app'))
    return out

def refs(text):
    return {m for m in TYPE.findall(text)}

need, queue = set(), collections.deque()
for c in layout_seeds():
    if c in fw and c not in HAVE and c not in app_classes: need.add(c); queue.append(c)
for t in app_text.values():
    for c in refs(t):
        if c in fw and c not in app_classes and c not in need:
            need.add(c); queue.append(c)

def parse(text):
    lines = text.split('\n')
    head, fields, methods = [], [], []
    i = 0
    while i < len(lines):
        l = lines[i]
        if l.startswith('.method'):
            j = i
            while not lines[j].startswith('.end method'): j += 1
            methods.append(lines[i:j + 1]); i = j + 1; continue
        if l.startswith('.field'):
            j = i
            if i + 1 < len(lines) and lines[i + 1].strip().startswith('.annotation'):
                j = i
                while not lines[j].startswith('.end field'): j += 1
            fields.append(l); i = j + 1; continue
        if l.startswith(('.class', '.super', '.implements')): head.append(l)
        i += 1
    return head, fields, methods

parsed = {}
def load(c):
    if c not in parsed: parsed[c] = parse(fw[c])
    return parsed[c]

# closure over vendor types appearing in headers, field and method signatures
while queue:
    c = queue.popleft()
    head, fields, methods = load(c)
    sigs = ' '.join(head + fields + [m[0] for m in methods])
    for r in refs(sigs):
        if r in fw and r not in need and r not in app_classes:
            need.add(r); queue.append(r)

def split_sig(s):
    m = re.match(r'\.method (.*?)([^ ]+)\((.*)\)(.+)$', s)
    flags, name, params, ret = m.groups()
    ps = re.findall(r'\[*(?:L[^;]+;|[ZBSCIJFD])', params)
    return flags.split(), name, ps, ret

def width(t): return 2 if t in ('J', 'D') else 1

def zero_load(t, reg):
    if t in ('J', 'D'): return ['    const-wide/16 v%d, 0x0' % reg]
    return ['    const/4 v%d, 0x0' % reg]

info = {}  # class -> (flags, super, min ctor sig or None)
for c in need:
    head, _, methods = load(c)
    cl = head[0]; flags = cl.split()[1:-1]
    sup = re.search(r'^\.super L([^;]+);', '\n'.join(head), re.M).group(1)
    ctors = []
    for m in methods:
        fl, name, ps, ret = split_sig(m[0])
        if name == '<init>' and 'abstract' not in fl: ctors.append((sum(width(p) for p in ps), ps))
    ctors.sort(key=lambda x: x[0])
    info[c] = (flags, sup, ctors[0][1] if ctors else None)

def ctor_regs_needed(ps): return 1 + sum(width(p) for p in ps)

def emit_new(cls, reg_base):
    """smali lines creating cls via its min ctor into v<reg_base>; args use following regs."""
    ps = info[cls][2]
    lines = ['    new-instance v%d, L%s;' % (reg_base, cls)]
    regs = ['v%d' % reg_base]; r = reg_base + 1
    for p in ps:
        lines += zero_load(p, r)
        regs.append('v%d' % r)
        if width(p) == 2: regs.append('v%d' % (r + 1))
        r += width(p)
    if len(regs) <= 5:
        lines.append('    invoke-direct {%s}, L%s;-><init>(%s)V' % (', '.join(regs), cls, ''.join(ps)))
    else:
        lines.append('    invoke-direct/range {v%d .. v%d}, L%s;-><init>(%s)V' % (reg_base, r - 1, cls, ''.join(ps)))
    return lines, r - reg_base

COLL = {'java/util/List': 'java/util/ArrayList', 'java/util/ArrayList': 'java/util/ArrayList', 'java/util/Collection': 'java/util/ArrayList',
        'java/util/Map': 'java/util/HashMap', 'java/util/HashMap': 'java/util/HashMap', 'java/util/Set': 'java/util/HashSet', 'java/util/HashSet': 'java/util/HashSet'}

def body_for(ret):
    """returns (locals, lines)"""
    if ret == 'V': return 0, ['    return-void']
    if ret in 'ZBSCIF' and len(ret) == 1: return 1, ['    const/4 v0, 0x0', '    return v0']
    if ret in ('J', 'D'): return 2, ['    const-wide/16 v0, 0x0', '    return-wide v0']
    if ret.startswith('['):
        if len(ret) == 2: return 2, ['    const/16 v0, 0x10', '    new-array v0, v0, %s' % ret, '    return-object v0']
        return 1, ['    const/4 v0, 0x0', '    new-array v0, v0, %s' % ret, '    return-object v0']
    c = ret[1:-1]
    if c == 'java/lang/String': return 1, ['    const-string v0, ""', '    return-object v0']
    if c in COLL:
        k = COLL[c]
        return 1, ['    new-instance v0, L%s;' % k, '    invoke-direct {v0}, L%s;-><init>()V' % k, '    return-object v0']
    if c in info and 'interface' in info[c][0]:
        return 1, ['    const-class v0, L%s;' % c, '    invoke-static {v0}, Lcom/livi/waydroid/HkmcStubs;->proxy(Ljava/lang/Class;)Ljava/lang/Object;',
                   '    move-result-object v0', '    check-cast v0, L%s;' % c, '    return-object v0']
    if c in info and info[c][2] is not None and not (set(info[c][0]) & {'abstract', 'interface'}):
        ls, n = emit_new(c, 0)
        return n, ls + ['    return-object v0']
    return 1, ['    const/4 v0, 0x0', '    return-object v0']

def clinit_ok(m):
    for r in refs('\n'.join(m)):
        if r in HAVE or r.startswith(SKIP) or r in need or r in app_classes: continue
        return False
    return not re.search(r'-quick|execute-inline|invoke-direct-empty', '\n'.join(m))

def overrides_final(c, name, desc):
    s = info[c][1]
    while s:
        if s in api_sup or s not in need:
            while s:
                if (s, name + desc) in api_final: return True
                s = api_sup.get(s)
            return False
        s = info[s][1]
    return False

def stub_method(c, m, is_enum):
    fl, name, ps, ret = split_sig(m[0])
    if name not in ('<init>', '<clinit>') and 'static' not in fl and 'private' not in fl and overrides_final(c, name, '(%s)%s' % (''.join(ps), ret)):
        return []
    hdr = '.method %s%s(%s)%s' % (' '.join(fl) + ' ' if fl else '', name, ''.join(ps), ret)
    if 'abstract' in fl: return [hdr, '.end method']
    fl = [f for f in fl if f != 'native']
    hdr = '.method %s%s(%s)%s' % (' '.join(fl) + ' ' if fl else '', name, ''.join(ps), ret)
    if name == '<clinit>':
        if clinit_ok(m): return [l for l in m if not l.strip().startswith(('.line', '.annotation'))] if False else m
        return ['.method static constructor <clinit>()V', '    .locals 0', '    return-void', '.end method']
    if is_enum and name in ('<init>', 'values', 'valueOf'):
        return m
    if name == '<init>':
        sup = info[c][1]
        own = '\n'.join(m)
        mt = re.search(r'invoke-direct(/range)? \{([^}]*)\}, L(%s|%s);-><init>\(([^)]*)\)V' % (re.escape(sup), re.escape(c)), own)
        if mt: sup = mt.group(3)  # a this(...) delegation is kept as such
        sps, args = [], []
        if mt:
            sps = re.findall(r'\[*(?:L[^;]+;|[ZBSCIJFD])', mt.group(4))
            if mt.group(1):
                lo, hi = [int(x[1:]) for x in re.split(r'\s*\.\.\s*', mt.group(2).strip())]
                regs = ['p%d' % i for i in range(lo, hi + 1)]
            else:
                regs = [x.strip() for x in mt.group(2).split(',') if x.strip()]
            args = regs[1:]  # p0 is this; wide args take two entries
        slots, i = [], 0  # (type, source p-register or None)
        for p in sps:
            r = args[i] if i < len(args) else None
            slots.append((p, r if r and r.startswith('p') else None)); i += width(p)
        total = sum(width(p) for p, _ in slots)
        if total <= 4:
            pregs, locs, lines = [], 0, []
            for p, r in slots:
                w = width(p)
                if r: pregs += [r] + (['p%d' % (int(r[1:]) + 1)] if w == 2 else [])
                else:
                    lines += zero_load(p, locs); pregs += ['v%d' % locs] + (['v%d' % (locs + 1)] if w == 2 else []); locs += w
            out = [hdr, '    .locals %d' % max(locs, 1)] + lines
            out.append('    invoke-direct {%s}, L%s;-><init>(%s)V' % (', '.join(['p0'] + pregs), sup, ''.join(sps)))
        else:
            out = [hdr, '    .locals %d' % (total + 1), '    move-object/from16 v0, p0']
            k = 1
            for p, r in slots:
                if not r: out += zero_load(p, k)
                elif p in ('J', 'D'): out.append('    move-wide/from16 v%d, %s' % (k, r))
                elif len(p) == 1: out.append('    move/from16 v%d, %s' % (k, r))
                else: out.append('    move-object/from16 v%d, %s' % (k, r))
                k += width(p)
            out.append('    invoke-direct/range {v0 .. v%d}, L%s;-><init>(%s)V' % (total, sup, ''.join(sps)))
        out += ['    return-void', '.end method']
        return out
    key = 'L%s;->%s(%s)%s' % (c, name, ''.join(ps), ret)
    if key in VALUES and ret in ('Z', 'B', 'S', 'C', 'I'):
        return [hdr, '    .locals 1', '    const/16 v0, %d' % VALUES[key], '    return v0', '.end method']
    loc, body = body_for(ret)
    return [hdr, '    .locals %d' % max(loc, 1)] + body + ['.end method']

n_methods = 0
for c in sorted(need):
    head, fields, methods = load(c)
    flags = info[c][0]; is_enum = 'enum' in flags
    out = list(head) + ['']
    out += fields + ['']
    for m in methods:
        sm = stub_method(c, m, is_enum)
        if sm: out += sm + ['']; n_methods += 1
    p = os.path.join(out_dir, c + '.smali')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write('\n'.join(out))
print('stubbed %d classes, %d methods' % (len(need), n_methods))
