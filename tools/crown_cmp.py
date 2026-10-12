#!/usr/bin/env python3
"""crown_cmp.py <baseline_census.txt> <new_census.txt> [门值=3.3330]

口径: census 行 = `CENSUS <slack> <arrival> <start> <end>`。
只做**同一读法**的两棵树对照: 最差条 / 头名起点去重 / B 族(宏读口→宏地址脚) / 胖尾计数。
不解释、不推断族身份 (那要 census_src.py), 只给可核对的量。
"""
import re, sys, collections

def load(p):
    rows = []
    for ln in open(p, errors='replace'):
        f = ln.split()
        if len(f) < 5 or f[0] != 'CENSUS':
            continue
        rows.append((float(f[2]), f[3], f[4]))
    return rows

B_S = re.compile(r'u_arr\.lane_\d+/rd_out')
B_E = re.compile(r'u_arr\.lane_\d+/addr_in')

def stat(rows):
    d = {}
    d['n'] = len(rows)
    d['worst'] = max(r[0] for r in rows)
    d['>3.4'] = sum(1 for r in rows if r[0] > 3.4)
    d['>4.0'] = sum(1 for r in rows if r[0] > 4.0)
    d['>4.4'] = sum(1 for r in rows if r[0] > 4.4)
    d['med'] = sorted(r[0] for r in rows)[len(rows) // 2]
    b = [r for r in rows if B_S.search(r[1]) and B_E.search(r[2])]
    d['B'] = len(b)
    d['Bworst'] = max((r[0] for r in b), default=0.0)
    nb = [r for r in rows if not (B_S.search(r[1]) and B_E.search(r[2]))]
    d['nb_best'] = max((r[0] for r in nb), default=0.0)
    d['nb_row'] = max(nb, default=(0, '?', '?'))
    st = collections.Counter(r[1] for r in rows)
    d['top_start'] = st.most_common(3)
    return d

a, b = load(sys.argv[1]), load(sys.argv[2])
da, db = stat(a), stat(b)
keys = ['n', 'worst', 'med', '>3.4', '>4.0', '>4.4', 'B', 'Bworst', 'nb_best']
print('%-10s %14s %14s' % ('量', sys.argv[1].split('/')[-1], sys.argv[2].split('/')[-1]))
for k in keys:
    va, vb = da[k], db[k]
    if isinstance(va, float):
        print('%-10s %14.4f %14.4f   Δ%+.4f' % (k, va, vb, vb - va))
    else:
        print('%-10s %14d %14d   Δ%+d' % (k, va, vb, vb - va))
print('\n非 B 族最好一条:')
print('  基线 %.4f  %s -> %s' % da['nb_row'])
print('  新树 %.4f  %s -> %s' % db['nb_row'])
print('\n起点去重 top3:')
print('  基线', da['top_start'])
print('  新树', db['top_start'])
print('\n新树最差 12 条:')
for r in sorted(b, reverse=True)[:12]:
    print('   %.4f  %s -> %s' % r)
