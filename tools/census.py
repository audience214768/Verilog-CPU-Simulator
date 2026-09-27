#!/usr/bin/env python3
"""census.py —— 在有名字的网表上数扇出, 把"哪个 RTL 构造"变成算术。

配套 tools/preabc.py 产出的 **RTL 层网表** (层次保留、信号名还在) 使用。post-ABC 的
mapped.v 里只剩 _NNNNN_ 匿名名, 什么都对不上, 所以归因必须走这里。

两种用法:
  1. 普查: 列出负载数最多的信号 —— 用来看热点在哪、降完之后热点迁到哪去了。
     (信号出现次数 ≈ 扇出 + 驱动, 与官方容器里实测的扇出数误差在 1% 量级,
      上一轮实测 792 (RTL 数) vs 797 (网表) 就是这么对上的。)
  2. 定点: --target SIG 打印该信号的**每一条负载点**, 给出精确扇出与引脚构成 ——
     这是判定"这是什么结构"的硬证据 (写使能 N×W? 读索引 one-hot W? 树的某一层?)

注意: 本工具的输出**不是**频率预测器。§15.10.11 已实测 "高扇出网个数" 与频率反相关;
只有"某个具体信号驱动多少负载 + 它是什么结构"才是可用的硬数据。

用法:
  tools/census.py /tmp/pa_with/preabc.v --top 25
  tools/census.py /tmp/pa_with/preabc.v --target rs_entry_valid
"""
import argparse
import re
from collections import Counter, defaultdict

# assign 的左右端; 实例连接 .PIN(sig) 或 .PIN({a,b})
RE_ASSIGN = re.compile(r"^\s*assign\s+(.+?)\s*=\s*(.+?);\s*$")
RE_PORT = re.compile(r"\.(\S+?)\s*\(\s*([^)]*?)\s*\)")
RE_SIG = re.compile(r"[A-Za-z_\\$][\w$\\\[\]\.]*")
RE_MOD = re.compile(r"^module\s+(\S+)")
# Verilog 字面量必须先去干净, 否则 32'h0000000 会被当成名为 h0000000 的信号
RE_LITERAL = re.compile(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+")


def tokens(expr):
    """从表达式里取信号名 (丢掉常量、位宽、操作符)。"""
    out = []
    for m in RE_SIG.finditer(RE_LITERAL.sub(" ", expr)):
        t = m.group(0)
        if re.fullmatch(r"[a-zA-Z_]\w*", t) and t in ("assign", "begin", "end", "wire", "reg"):
            continue
        out.append(t)
    return out


def scan(path):
    """返回 (loads[(sig, module, pin_or_rhs)], modules[sig] -> set)。"""
    loads = []
    owner = {}
    module = "?"
    for line in open(path, errors="replace"):
        m = RE_MOD.match(line)
        if m:
            module = m.group(1)
            continue
        m = RE_ASSIGN.match(line)
        if m:
            lhs, rhs = m.groups()
            name = tokens(lhs)
            if name:
                owner.setdefault(name[0], module)
            for t in tokens(rhs):
                loads.append((t, module, "assign-rhs"))
            continue
        if "(" in line and "." in line and line.rstrip().endswith(");"):
            for pin, conn in RE_PORT.findall(line):
                for t in tokens(conn):
                    loads.append((t, module, pin))
    return loads, owner


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--target", default=None, help="只报这个信号的负载点")
    ap.add_argument("--min", type=int, default=64, help="普查的负载数下限")
    args = ap.parse_args()

    loads, owner = scan(args.netlist)
    per_sig = defaultdict(Counter)
    for sig, module, pin in loads:
        per_sig[sig][f"{pin}"] += 1
    if args.target:
        c = per_sig.get(args.target)
        if not c:
            print(f"没找到信号 {args.target} (可能被 opt 合并或名字被改写)")
            return
        total = sum(c.values())
        print(f"# {args.target}: 负载点 {total} 个, 定义于模块 {owner.get(args.target, '?')}")
        for pin, n in c.most_common(30):
            print(f"   {pin:20s} x{n}")
        return
    print(f"# {args.netlist}: 负载数 >= {args.min} 的信号 (共 {len(per_sig)} 个信号有负载)")
    print(f"{'负载数':>8}  {'模块':<28} 信号 / 主要负载引脚")
    for sig, c in sorted(per_sig.items(), key=lambda kv: -sum(kv[1].values()))[:args.top]:
        n = sum(c.values())
        if n < args.min:
            break
        pins = ",".join(f"{p}x{k}" for p, k in c.most_common(3))
        print(f"{n:8d}  {owner.get(sig, '?'):<28} {sig}   [{pins}]")


if __name__ == "__main__":
    main()
