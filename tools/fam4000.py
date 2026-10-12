#!/usr/bin/env python3
"""fam4000.py <census.txt> —— census 4000 行的族普查（行格式: CENSUS <slack> <arrival> <start> <end>）。"""
import re, sys, collections
macro = re.compile(r'(u_arr|u_ic)\.lane_\d+/(rd_out|addr_in|wd_in|we_in)')
rows = []
for ln in open(sys.argv[1], errors='replace'):
    p = ln.split()
    if len(p) < 5 or p[0] != 'CENSUS': continue
    arr, s, e = float(p[2]), p[3], p[4]
    rows.append((arr, s, e))
print(f'# {len(rows)} 条; 最差 arrival {max(r[0] for r in rows):.4f}; 第 4000 条 arrival {min(r[0] for r in rows):.4f}')
cnt = collections.Counter(); bworst = 0.0; best_nb = 0.0; nbrow = None
for arr, s, e in rows:
    ms = bool(re.search(r'u_arr\.lane_\d+/rd_out', s))
    me = bool(re.search(r'u_arr\.lane_\d+/addr_in', e))
    ms2 = bool(re.search(r'u_arr\.lane_\d+/(wd_in|we_in)', s)) or bool(re.search(r'u_arr\.lane_\d+/(wd_in|we_in)', e))
    k = 'B:宏读口→宏地址脚' if (ms and me) else ('含宏脚(其他)' if (macro.search(s) or macro.search(e)) else '纯逻辑')
    cnt[k] += 1
    if k == 'B:宏读口→宏地址脚': bworst = max(bworst, arr)
    elif k != 'B:宏读口→宏地址脚' and arr > best_nb:
        best_nb, nbrow = arr, (s, e)
for k, v in cnt.most_common(): print(f'  {k:<16} {v:>5} 条')
print(f'\nB 族最差 arrival      {bworst:.4f}')
print(f'非 B 最好 arrival     {best_nb:.4f}   ({nbrow[0]} -> {nbrow[1]})' if nbrow else '')
