#!/usr/bin/env python3
"""seqcone.py <netlist.v> <起点网|实例名> [查询网 ...] [--bounds N] [--named N]
—— 在**有名字的** pre-ABC 网表上做"时序等效组合锥"（跑到顺序单元为止，与 STA 的锥同义）。

用途：回答"这个终点到底依赖哪些 RTL 信号"，且**不受 ABC 重解影响**。
典型用法（2026-10-12，plan §3.36 定 B 族是不是真实 RTL 通路）：

    python3 tools/seqcone.py /t/preabc_cutW.v '\\u_mem.u_dc.u_arr.addr [0]' \\
            '\\u_mem.u_dc.rmw_rd_w' '\\u_mem.u_dc.u_arr.rdata [269]'

为什么必须用它而不是在 post-ABC 的 mapped.v 上做：ABC 是全局重分解，匿名网名 `_083533_`
与 RTL 没有任何对应关系，"锥里有没有 X"这种问题在 post-ABC 上问不出来（问了也只能得到
"某棵 ABC 重建的树"的形状）。pre-ABC 网表由 `tools/preabc_official.ys.tpl` 产出，**RTL 名字还在**。

★ 口径与两个必须知道的坑（head 注释即契约，改动前先读）：
 1. **输出脚必须按 cell 类型判**（本工具的 `outs()`）。`\\$_MUX_` 的 `S` 是**选择端（输入）**，
    只有加法器 (`$alu/$add`) 的 `S/CO/SO` 才是输出。踩过：把 `S` 一律当输出 ⇒ 所有 mux 的选择脚
    被当出口、锥被严重低估（同一查询从 4817 网掉到 52 网，且会得出"某个信号不可达"的相反结论）。
    仓库里的 `tools/cone.py` 的 `OUT_PINS = ('Y','Q','QN')` **不含 `S`**，所以它没有这个问题。
 2. **转义名里有空格**：`\\u_mem.u_dc.rdata_w [557]`（名字与位下标之间有一个空格）⇒ 传参时请整体
    加引号，别用 shell 分词。位宽切片 `[269]` 与整向量 `[557]` 是两个不同的网名。
 3. **输出脚可能是拼接**：fakeram 宏的 `rd_out` 在网表里常写成
    `.rd_out({ \\u_mem.u_dc.u_arr.rdata [287:266], \\u_mem.u_dc.rdata_w [265:0] })`
    ⇒ 必须把拼接**拆开**逐个登记驱动者（本工具 `split_concat()` 已处理）。踩过：只登记整串 ⇒
    那些位看起来"无驱动"，锥的边界族里混进 44 个假的"主输入"（实为两个宏的 tag/valid 位）。
    **bit 归属要按位算**：上面这行的 `rd_out[269]` = `u_arr.rdata[266+3]` = `u_arr.rdata[269]`（不是 `rdata_w[557]`）。

边界 = 顺序单元（DFF/LATCH/fakeram 宏）的输出网 + 无驱动网（主输入/常量外的悬空）。
"""
import re
import sys
from collections import deque, defaultdict

SKIP = {'module', 'input', 'output', 'inout', 'wire', 'reg', 'assign', 'always', 'initial',
        'if', 'else', 'case', 'generate', 'function', 'task', 'parameter', 'localparam',
        'endmodule', 'specify', 'end', 'endgenerate'}
CONST = ("1'b0", "1'b1", "1'bx", "1'bz", "1'h0", "1'h1", "1'hx", "1'hz")
SEQ = ('DFF', 'SDFF', 'DLY', 'LATCH', '$_DFF', '$_SDFF', '$_DLATCH', '$_SR', 'fakeram')


def outs(ty, pins):
    """该 cell 的输出脚集合 —— 按类型判，不要用一张全局的表（见头注释坑 1）。"""
    if 'rd_out' in pins:
        return {'rd_out'}                      # fakeram 宏的读出口
    if 'Y' in pins:
        return {'Y'}                           # 通用组合门
    if 'Q' in pins or 'QN' in pins:
        return {p for p in ('Q', 'QN') if p in pins}
    return {p for p in ('S', 'CO', 'SO', 'CON', 'SN', 'H', 'L') if p in pins}   # 加法器/其他


def is_named(n):
    return n.startswith('\\') and not re.match(r'^\\_\d+_', n)


def split_concat(val):
    """把引脚值拆成它连接的网名列表（拼接 `{a, b}` 与单网都吃，见头注释坑 3）。"""
    v = val.strip()
    if v.startswith('{') and v.endswith('}'):
        return [x.strip() for x in v[1:-1].split(',') if x.strip()]
    return [v]


def base_name(n):
    """`\\u_...rdata [287:266]` → `\\u_...rdata`（位下标/位段一律去掉）。"""
    return re.sub(r'\s*\[\d+(?::\d+)?\]$', '', n)


def parse(path_v):
    lines = open(path_v, errors='replace').read().split('\n')
    cell_start = re.compile(r'^  (\S+)\s+(\S+)\s+\($')
    pin_re = re.compile(r'^\s+\.(\w+)\((.+?)\)[,]?$')
    cells, drv, drvbase, seen, i, N = {}, {}, {}, set(), 0, len(lines)
    while i < N:
        m = cell_start.match(lines[i])
        if m and m.group(1).lstrip('\\$') not in SKIP:
            ty, inst = m.group(1), m.group(2)
            pins, j = {}, i + 1
            while j < N and not lines[j].startswith('  );'):
                pm = pin_re.match(lines[j])
                if pm:
                    pins[pm.group(1)] = pm.group(2).strip()
                j += 1
            cells[inst] = (ty, pins)
            for p, v in pins.items():
                for net in split_concat(v):
                    seen.add(net)
                    if p in outs(ty, pins):
                        drv[net] = inst
                        if net != base_name(net):      # 位段形（`x [287:266]`）⇒ 记基名兜底
                            drvbase[base_name(net)] = inst
            i = j + 1
        else:
            i += 1
    return cells, drv, drvbase, seen


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path_v, start = sys.argv[1], sys.argv[2]
    nb = nn = 0
    queries = []
    rest = sys.argv[3:]
    while rest:
        a = rest.pop(0)
        if a == '--bounds':
            nb = int(rest.pop(0))
        elif a == '--named':
            nn = int(rest.pop(0))
        else:
            queries.append(a)

    cells, drv, drvbase, seen = parse(path_v)
    if start in cells:                                   # 给实例名 ⇒ 换成它驱动的网
        ty, pins = cells[start]
        o = outs(ty, pins)
        if not o:
            sys.exit(f'{start}: 该 cell 没有输出脚（{ty}）')
        start = split_concat(pins[sorted(o)[0]])[0]
    if start not in seen:
        sys.exit(f'{start}: 网表里找不到这颗网（转义名含空格，记得整体加引号）')

    def is_seq(inst):
        ty = cells[inst][0].lstrip('\\$')
        return ty.startswith(SEQ) or cells[inst][0].startswith('fakeram')

    depth, q, bord = {start: 0}, deque([start]), defaultdict(int)
    while q:
        n = q.popleft()
        inst = drv.get(n) or drvbase.get(base_name(n))
        if inst is None:
            bord['(无驱动/主输入)'] += 1
            continue
        if is_seq(inst):
            bord[base_name(n)] += 1
            continue
        ty, pins = cells[inst]
        o = outs(ty, pins)
        for p, v in pins.items():
            if p in o or v in CONST or v in depth:
                continue
            depth[v] = depth[n] + 1
            q.append(v)

    print(f'# 时序截断锥 {len(depth)} 网; 边界 {sum(bord.values())} 个')
    for t in queries:
        if t in depth:
            verdict = '在锥内 d=%d' % depth[t]
        elif t in seen:
            verdict = '**不在锥内**'
        else:
            verdict = '**网表里没有这颗网**'
        print(f'   {verdict:<22} {t}')
    if nb:
        print('# 边界族 (名去位下标)')
        for g, c in sorted(bord.items(), key=lambda kv: -kv[1])[:nb]:
            print(f'   {c:>5}  {g}')
    if nn:
        named = sorted((d, n) for n, d in depth.items() if is_named(n))
        print(f'# 锥内具名(RTL)网 {len(named)} 个 (前 {nn})')
        for d, n in named[:nn]:
            print(f'   d={d:<4} {n}')


if __name__ == '__main__':
    main()
