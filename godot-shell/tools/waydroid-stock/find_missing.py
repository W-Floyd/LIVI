#!/usr/bin/env python3
"""List members (methods/fields) the app calls on framework classes that the target framework lacks.
usage: find_missing.py <app-smali-dir> <api.tsv> [<stubs-dir>]   -> prints 'kind\tclass->member\tcount'"""
import os, re, sys, collections

INV = re.compile(r'invoke-[a-z]+(?:/range)? \{[^}]*\}, (L[^;]+;)->([^\s(]+\([^)]*\)\S+)')
FLD = re.compile(r'[is](?:get|put)[a-z-]* [vp0-9, ]+, (L[^;]+;)->(\S+:\S+)')

def missing(app, api, stubs=None):
    sup, ifs, mem = {}, {}, collections.defaultdict(set)
    for l in open(api):
        p = l.rstrip('\n').split('\t')
        if p[0] == 'C': sup[p[1]] = p[2]; ifs[p[1]] = p[3:]
        else: mem[p[1]].add(p[2])  # p[3] (methods): 'final' or '-'
    local = set()
    for d in (app, stubs):
        if not d: continue
        for r, _, fs in os.walk(d):
            for f in fs:
                if f.endswith('.smali'):
                    m = re.search(r'^\.class (?:\S+ )*?(L[^;]+;)', open(os.path.join(r, f)).read(), re.M)
                    if m: local.add(m.group(1))
    def has(c, key, seen):
        if c in seen or c not in sup: return None
        seen.add(c)
        if key in mem[c]: return True
        return any(has(s, key, seen) for s in [sup[c]] + ifs[c] if s and s != 'None')
    cnt = collections.Counter()
    for r, _, fs in os.walk(app):
        for f in fs:
            if not f.endswith('.smali'): continue
            t = open(os.path.join(r, f)).read()
            for rx, kind in ((INV, 'M'), (FLD, 'F')):
                for c, k in rx.findall(t):
                    if c in local or c not in sup: continue
                    if not has(c, k, set()): cnt[(kind, c, k)] += 1
    return cnt

if __name__ == '__main__':
    for (kind, c, k), n in sorted(missing(*sys.argv[1:4]).items()): print('%s\t%s->%s\t%d' % (kind, c, k, n))
