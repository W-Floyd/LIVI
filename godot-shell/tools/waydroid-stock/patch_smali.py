#!/usr/bin/env python3
"""Rewrite Context/Activity.getSystemService(String) call sites to HkmcStubs.get(Context,String) (falls back to the real call).
Calls to vendor-added methods on AOSP classes (absent in the target) go to HkmcStubs.missingN, which returns the receiver
for builder-style returns and a zero value otherwise.
usage: patch_smali.py <app-smali-dir> <stubs-out-dir> <api.tsv>"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from find_missing import missing
app, stubs, api = sys.argv[1:4]
miss = {k: i for i, ((kind, c, k), _) in enumerate(sorted(missing(app, api, stubs).items())) if kind == 'M'}
miss_cls = {}
for (kind, c, k), _ in missing(app, api, stubs).items():
    if kind == 'M': miss_cls[(c, k)] = None
helpers = []
def helper(c, k):
    name, rest = k.split('(', 1); params, ret = rest.split(')', 1)
    n = len(helpers)
    isstatic = False
    body = {'V': '    return-void', 'J': '    const-wide/16 v0, 0x0\n    return-wide v0', 'D': '    const-wide/16 v0, 0x0\n    return-wide v0'}.get(ret)
    if body is None:
        body = '    return-object p0' if ret == c else ('    const/4 v0, 0x0\n    return v0' if len(ret) == 1 else '    const/4 v0, 0x0\n    return-object v0')
    helpers.append('.method public static missing%d(%s%s)%s\n    .locals 1\n%s\n.end method\n' % (n, c, params, ret, body))
    return n
site = re.compile(r'invoke-(?:virtual|interface|direct)(/range)? (\{[^}]*\}), (L[^;]+;)->([^\s(]+\([^)]*\)\S+)')
def fix(m):
    c, k = m.group(3), m.group(4)
    if (c, k) not in miss_cls: return m.group(0)
    if miss_cls[(c, k)] is None: miss_cls[(c, k)] = helper(c, k)
    name, rest = k.split('(', 1); params, ret = rest.split(')', 1)
    return 'invoke-static%s %s, Lcom/livi/waydroid/Missing;->missing%d(%s%s)%s' % (m.group(1) or '', m.group(2), miss_cls[(c, k)], c, params, ret)

svc_helpers, nsvc = {}, 0
svc_site = re.compile(r'invoke-virtual (\{[^}]*\}), Lcom/hkmc/VehicleInfoManager;->getService\(Ljava/lang/String;\)Ljava/lang/Object;((?:\s*\n\s*move-result-object [vp0-9]+)?(?:\s*\n)*\s*check-cast [vp0-9]+, (L[^;]+;))')
def svc(m):
    global nsvc
    cls = m.group(3); nsvc += 1
    name = 'svc_' + re.sub(r'\W', '_', cls)
    svc_helpers[name] = ('.method public static %s(Lcom/hkmc/VehicleInfoManager;Ljava/lang/String;)Ljava/lang/Object;\n    .locals 1\n    const-class v0, %s\n'
        '    invoke-static {v0}, Lcom/livi/waydroid/HkmcStubs;->instance(Ljava/lang/Class;)Ljava/lang/Object;\n    move-result-object v0\n    return-object v0\n.end method\n') % (name, cls)
    return 'invoke-static %s, Lcom/livi/waydroid/Missing;->%s(Lcom/hkmc/VehicleInfoManager;Ljava/lang/String;)Ljava/lang/Object;%s' % (m.group(1), name, m.group(2))
pat = re.compile(r'invoke-virtual \{([^}]*)\}, Landroid/(?:content/Context|app/Activity);->getSystemService\(Ljava/lang/String;\)Ljava/lang/Object;')
fg = re.compile(r'invoke-virtual \{([^}]*)\}, Landroid/app/Service;->startForeground\(ILandroid/app/Notification;\)V')
n = 0
for r, _, fs in os.walk(app):
    for f in fs:
        if not f.endswith('.smali'): continue
        p = os.path.join(r, f); t = open(p).read()
        t2, k = pat.subn(lambda m: 'invoke-static {%s}, Lcom/livi/waydroid/HkmcStubs;->get(Landroid/content/Context;Ljava/lang/String;)Ljava/lang/Object;' % m.group(1), t)
        t2 = fg.sub(lambda m: 'invoke-static {%s}, Lcom/livi/waydroid/HkmcStubs;->startForeground(Landroid/app/Service;ILandroid/app/Notification;)V' % m.group(1), t2)
        t2 = svc_site.sub(svc, t2)
        t2 = site.sub(fix, t2)
        if t2 != t: open(p, 'w').write(t2); n += k
# targetSdk >= 24 rejects MODE_WORLD_READABLE/WRITEABLE (and the stock 0x7 etc.): make those private.
mode_site = re.compile(r'(const(?:/4|/16) (v\d+), )0x[1-7]\n(\s*\n\s*invoke-virtual(?:/range)? \{([^}]*)\}, Landroid/content/Context;->(?:getSharedPreferences\(Ljava/lang/String;I\)|openFileOutput\(Ljava/lang/String;I\)|getDir\(Ljava/lang/String;I\)))')
def mode_fix(m):
    last = re.split(r'[,\s.]+', m.group(4).strip())[-1]
    return m.group(1) + '0x0\n' + m.group(3) if last == m.group(2) else m.group(0)
nmode = 0
for r, _, fs in os.walk(app):
    for f in fs:
        if f.endswith('.smali'):
            p = os.path.join(r, f); t = open(p).read(); t2 = mode_site.sub(mode_fix, t)
            if t2 != t: open(p, 'w').write(t2); nmode += 1
print('file modes made private in %d files' % nmode)
main = os.path.join(app, 'com/hkmc/daudio/app/ev3/MainActivity.smali')
if os.path.exists(main):
    t = open(main).read()
    t2 = re.sub(r'(\.method [^\n]*onCreate\(Landroid/os/Bundle;\)V\n(?:\s*\.[a-z]+[^\n]*\n)*?\s*\.(?:locals|registers) \d+\n)',
        lambda m: m.group(1) + '    invoke-static {p0}, Lcom/livi/waydroid/HkmcStubs;->windowBackground(Landroid/app/Activity;)V\n', t, count=1)
    if t2 != t: open(main, 'w').write(t2); print('MainActivity.onCreate sets the window background')
os.makedirs(os.path.join(stubs, 'com/livi/waydroid'), exist_ok=True)
open(os.path.join(stubs, 'com/livi/waydroid/Missing.smali'), 'w').write('.class public Lcom/livi/waydroid/Missing;\n.super Ljava/lang/Object;\n\n' + '\n'.join(helpers) + '\n'.join(svc_helpers.values()))
print('patched %d getSystemService + %d VehicleInfoManager.getService call sites, %d vendor-added methods redirected' % (n, nsvc, sum(1 for v in miss_cls.values() if v is not None)))
