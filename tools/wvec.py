#!/usr/bin/env python3
"""wvec.py —— 全设计**宽向量 × 动态访问**普查 (配 tools/preabc.py 的 preabc.json 用)。

口径: "宽向量 × 动态访问" = 对一条宽寄存器/线网做**变量下标**读或写 (RTL 里的 `v[i]`
/ `v[i +: W]`, i 是信号)。它在网表里必然物化成 $shiftx/$shift (ymosys 的 techmap 之前),
而这些正是官方 ABC 流程下被全额惩罚的宽扇出的来源 —— 例如 dcache tag_r(1408 位) 的动态写口
曾是**唯一**的 ≥1024 扇出簇 (见 docs/plan.md §41)。

本工具给出**理论下界**: 一条 N 条目 × W 位的向量, 动态访问至少要 W 个负载 (每输出位一次),
而把下标译码**挪到寄存器后面** (one-hot 提前一拍) 后峰值扇出降到 = W (条目宽度), 与 N 无关。
⇒ 排序键 = A_WIDTH (待消灭的位数), 越大越值得动刀。

用法:
  tools/wvec.py /tmp/preabc_base/preabc.json            # 按宽度排序的全表
  tools/wvec.py /tmp/preabc_base/preabc.json --min 64   # 只列 A_WIDTH >= 64
  tools/wvec.py /tmp/preabc_base/preabc.json --src dcache  # 只看某文件的访问点
"""
import argparse
import json
import os
import re
from collections import defaultdict

SHIFT = ("$shiftx", "$shift", "$shiftxr", "$shiftr")


def bin2int(v):
    """参数在 json 里是二进制串 (可能带 x/z, 或十进制串)。"""
    if v is None:
        return None
    if isinstance(v, int):
        return v
    s = v.strip()
    if set(s) <= set("01"):
        return int(s, 2)
    try:
        return int(s, 10)
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("json", help="preabc.py 产出的 preabc.json")
    ap.add_argument("--min", type=int, default=1, help="只列 A_WIDTH >= 该值")
    ap.add_argument("--src", default=None, help="只看 src 路径含该子串的访问点")
    ap.add_argument("--top", type=int, default=0, help="只打印前 N 条 (0=全部)")
    a = ap.parse_args()

    d = json.load(open(a.json))
    mods = d["modules"]

    # RTL 位置 -> 聚合 (同一处可能被参数化例化多次, 例如每路一个)
    agg = defaultdict(lambda: {"n": 0, "aw": 0, "yw": 0, "mods": set(), "names": set()})
    for mn, m in mods.items():
        netnames = m.get("netnames") or {}
        # netnames 是 name -> {bits:[id...]}; 反查表用来把 A 输入的网 id 认回向量名
        id2name = {}
        for nm, info in netnames.items():
            for b in (info.get("bits") or []):
                id2name.setdefault(b, nm)
        for cn, c in (m.get("cells") or {}).items():
            if c.get("type") not in SHIFT:
                continue
            p = c.get("parameters") or {}
            aw = bin2int(p.get("A_WIDTH"))
            yw = bin2int(p.get("Y_WIDTH"))
            src = (c.get("attributes") or {}).get("src", "?")
            if a.src and a.src not in src:
                continue
            if aw is None or aw < a.min:
                continue
            key = (c["type"], src)
            e = agg[key]
            e["n"] += 1
            e["aw"] = max(e["aw"], aw)
            e["yw"] = max(e["yw"], yw or 0)
            e["mods"].add(re.sub(r"^\$paramod\$\w+\\?", "", mn))
            # A 输入的首位网名 —— 认向量用 (宽总线是逐位拼的, 首位足够认名)
            conn = (c.get("connections") or {}).get("A") or []
            if conn:
                first = id2name.get(conn[0])
                if first:
                    # 去掉 yosys 的 lookahead 前缀 / 总线下标 / 转义, 只留信号名
                    first = re.sub(r"^\$0\$lookahead\\?", "", first)
                    first = re.sub(r"\[\d+(:\d+)?\]", "", first)
                    e["names"].add(first.lstrip("\\"))

    rows = sorted(agg.items(), key=lambda kv: (-kv[1]["aw"], -kv[1]["n"], kv[0][1]))
    if a.top:
        rows = rows[: a.top]

    tot_bits = sum(e["aw"] for _, e in rows)
    print(f"# {a.json}: {len(rows)} 处动态访问点 (A_WIDTH>={a.min}), 合计待消灭位宽 {tot_bits}")
    print(f"{'A_W':>6} {'Y_W':>5} {'份数':>4}  {'向量(首位网名)':<28} {'模块':<22} src")
    for (typ, src), e in rows:
        names = ",".join(sorted(e["names"])[:2]) or "?"
        mods = ",".join(sorted(e["mods"])[:2])
        loc = re.sub(r"^.*/(verilog/.*)$", r"\1", src)
        print(f"{e['aw']:>6} {e['yw']:>5} {e['n']:>4}  {names[:28]:<28} {mods[:22]:<22} {loc}")


if __name__ == "__main__":
    main()
