#!/usr/bin/env python3
"""path.py —— 关键路径解剖: 把"哪一级贵、贵在扇出还是贵在深度"变成算术。

数据源是**官方判分产物自己** —— OpenSTA 写的 `timing.rpt` 每行本来就带
`Fanout Cap Slew Delay Time Description` 五列, 所以不需要自己数网表, 也不用 join
`mapped.v` (post-ABC 只有匿名名 _NNNNN_)。每一级 = 一个带扇出数的驱动引脚行。

输出三样东西, 对应频率墙的两道:
  1. 扇出分桶表 (级数 / Σ延时 / ps per 级) —— 回答"高扇出吃掉多少"。
  2. healthy_ns (扇出 ≤15 的级) 与 hot_ns (≥16) —— healthy_ns 就是**深度地板**
     (≈ 级数 × 单级本征延时), hot_ns 是扇出税。
  3. 最贵的 N 级 (驱动单元 + 扇出 + 电容 + 摆率 + 增量延时), 可选带负载引脚直方图。

判据 (对应计划的"过程判据"): 要 300 MHz 需 级数 ≤71 且 每级扇出 ≤15。

**不要**把本工具输出的级数/层数当频率预测器 —— §15.10.11 已实测 ltp/层数/面积/
高扇出网个数全部与频率反相关。这里只有"这一级的延时与扇出"是硬数据。

用法:
  tools/path.py build/synth_t4/opt                        # 默认分析第 1 条(最差)路径
  tools/path.py build/synth_f3/opt --netlist mapped.v      # 附带热点网的负载引脚直方图
  tools/path.py build/synth_t4/opt --json /tmp/p1.json
"""
import argparse
import json
import re
from collections import Counter
from pathlib import Path

# 驱动引脚行: "  482  251.9796  2.1928  1.0670  1.0670 ^ _214779_/QN (DFFASRHQNx1_...) "
RE_DRIVE = re.compile(
    r"^\s*(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\^v])\s+(\S+)\s+\((\S+)\)\s*$")
# 负载引脚行: "                       0.7584    0.0000    2.7581 v _174076_/B (NOR2xp33_...)"
RE_LOAD = re.compile(r"^\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\^v])\s+(\S+)\s+\((\S+)\)\s*$")
# mapped.v 里实例是**多行**写法 (每行一个 .PIN(net), 最后一行 ");"), 单行正则数不到
RE_INST_HEAD = re.compile(r"^\s+(\S+)\s+(\S+)\s*\(\s*$")
RE_CONN = re.compile(r"\.(\S+?)\s*\(\s*([^)]*?)\s*\)")
OUT_PINS = ("Y", "Q", "QN", "CON")
BUCKETS = [(0, 15), (16, 31), (32, 63), (64, 127), (128, 255), (256, 1 << 30)]


def parse_rpt(text, index=0):
    """切出第 index 条路径并逐级解析。返回 (header, levels)。"""
    blocks = text.split("Startpoint:")[1:]
    if not blocks:
        raise ValueError("timing.rpt 里没有 Startpoint 块")
    if index >= len(blocks):
        raise ValueError(f"只有 {len(blocks)} 条路径, 要不了第 {index + 1} 条")
    # 只保留本条路径: 切到下一个 Startpoint 之前, 再把标记拼回去给表头正则用
    block = "Startpoint:" + blocks[index].split("Startpoint:")[0]
    levels, load_sig = [], []
    for line in block.splitlines():
        m = RE_DRIVE.match(line)
        if m:
            fan, cap, slew, delay, time, edge, pin, cell = m.groups()
            levels.append({"fanout": int(fan), "cap_fF": float(cap) * 1000.0,
                           "slew_ns": float(slew), "delay_ns": float(delay),
                           "time_ns": float(time), "pin": pin, "cell": cell,
                           "net": pin.split("/")[0], "loads": []})
            load_sig = []
            continue
        m = RE_LOAD.match(line)
        if m and levels:
            slew, delay, time, _edge, pin, cell = m.groups()
            levels[-1]["loads"].append({"pin": pin, "cell": cell})
    header = {}
    for key in ("Startpoint", "Endpoint", "Path Group", "Path Type"):
        mm = re.search(rf"^{key}:\s*(.+)$", block, re.M)
        if mm:
            header[key.lower().replace(" ", "_")] = mm.group(1).strip()
    mm = re.search(r"^\s*([-\d.]+)\s+slack", block, re.M)
    if mm:
        header["slack_ns"] = float(mm.group(1))
    mm = re.search(r"^\s*([-\d.]+)\s+data arrival time", block, re.M)
    if mm:
        header["arrival_ns"] = float(mm.group(1))
    return header, levels


def scan_instances(text):
    """扫 mapped.v 的实例, 产出 [(cell, inst, {pin: conn})]。

    形态是多行 (每行一个 `.PIN(net),`, 收尾一行 `);`), 所以必须按块读, 不能按行匹配。
    """
    insts = []
    lines = text.splitlines()
    i, n = 0, len(lines)
    while i < n:
        m = RE_INST_HEAD.match(lines[i])
        if not m:
            i += 1
            continue
        cell, inst, conns = m.group(1), m.group(2), {}
        i += 1
        while i < n and lines[i].strip() != ");":
            for pin, conn in RE_CONN.findall(lines[i]):
                conns[pin] = conn
            i += 1
        i += 1
        insts.append((cell, inst, conns))
    return insts


def load_pin_histogram(insts, inst_name):
    """给一个**驱动实例名** (OpenSTA 报的 `_149244_/Y` 前半截), 数它那根网的负载引脚构成。

    注意: 实例名 != 网名 —— mapped.v 里 `_149244_(.Y(_082773_))`, OpenSTA 报 `_149244_/Y`,
    而负载点写的是 `_082773_`。所以先解出输出网名, 再统计。
    """
    if insts is None:
        return None, None
    net = None
    for _cell, inst, conns in insts:
        if inst == inst_name:
            net = next((conns[p] for p in OUT_PINS if p in conns), None)
            break
    if net is None:
        return None, None
    hist = Counter()
    for cell, _inst, conns in insts:
        for pin, conn in conns.items():
            if conn == net:
                hist[f"{cell}.{pin}"] += 1
    return net, dict(hist.most_common(10))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("artifacts", help="含 timing.rpt 的产物目录 (或直接给 timing.rpt)")
    ap.add_argument("--path", type=int, default=1, help="第几条路径 (1 = 最差)")
    ap.add_argument("--top", type=int, default=10, help="列最贵的 N 级")
    ap.add_argument("--netlist", default=None, help="mapped.v 路径, 给热点网加负载引脚直方图")
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    src = Path(args.artifacts)
    rpt = src / "timing.rpt" if src.is_dir() else src
    header, levels = parse_rpt(rpt.read_text(), args.path - 1)
    insts = None
    if args.netlist:
        insts = scan_instances(Path(args.netlist).read_text(errors="replace"))

    total = sum(l["delay_ns"] for l in levels)
    healthy = sum(l["delay_ns"] for l in levels if l["fanout"] <= 15)
    hot = total - healthy
    n_healthy = sum(1 for l in levels if l["fanout"] <= 15)

    print(f"# {rpt}")
    print(f"# 路径 {args.path}: {header.get('startpoint')} -> {header.get('endpoint')}"
          f"  slack {header.get('slack_ns')} ns  arrival {header.get('arrival_ns')} ns")
    print(f"# 级数 {len(levels)}  最长级延时 {max(l['delay_ns'] for l in levels):.4f} ns"
          f"  健康级 {n_healthy} 级 / {healthy:.4f} ns"
          f" ({healthy / max(n_healthy, 1) * 1000:.1f} ps/级)"
          f"  高扇出税 {hot:.4f} ns ({hot / total * 100:.0f}%)")
    # 两道墙各自的地板 —— 必须分清, 混用会自欺:
    #   上限B (只修扇出, 级数不变): 每一级都降到健康级那么便宜 => 级数 × ps/级。
    #       这是"扇出消除"这条路能到的天花板, 也是本轮工作范围的真实预期。
    #   上限A (假想): 现存的健康级原样不动、高扇出的 15 级**完全不要钱** => healthy_ns。
    #       它不是一个可达目标 (那 15 级的逻辑不会凭空消失), 只用来判断"深度本身够不够"。
    ps = healthy / max(n_healthy, 1) * 1000.0
    floor_fanout_only = len(levels) * ps / 1000.0
    print(f"# 上限B 只修扇出(级数不变) = {floor_fanout_only:.4f} ns -> "
          f"{1 / floor_fanout_only * 1000:.0f} MHz")
    print(f"# 上限A 假想(高扇出全免费) = {healthy:.4f} ns -> {1 / healthy * 1000:.0f} MHz"
          f"   | 300 MHz 预算 {3.333:.3f} ns 允许总级数 <= {3.333 / ps * 1000:.0f} 级"
          f" (现 {len(levels)} 级, 健康 {n_healthy} 级)")
    print()
    print("扇出桶            级数     Σ延时 ns   ps/级")
    for lo, hi in BUCKETS:
        sel = [l for l in levels if lo <= l["fanout"] <= hi]
        if not sel:
            continue
        d = sum(l["delay_ns"] for l in sel)
        label = f"{lo}-{hi}" if hi < (1 << 30) else f">={lo}"
        print(f"  {label:<14} {len(sel):5d}   {d:9.4f}   {d / len(sel) * 1000:7.1f}")
    print()
    print(f"最贵的 {args.top} 级:")
    print("   级   扇出     电容fF    摆率ns   增量ns    累计ns  驱动")
    for rank, l in sorted(enumerate(levels), key=lambda kv: -kv[1]["delay_ns"])[:args.top]:
        print(f"  {rank:4d} {l['fanout']:6d} {l['cap_fF']:10.1f} {l['slew_ns']:8.4f}"
              f" {l['delay_ns']:9.4f} {l['time_ns']:9.4f}  {l['cell']} {l['pin']}")
        if args.netlist:
            net, h = load_pin_histogram(insts, l["net"])
            if h:
                print(f"       网 {net} 负载: " + ", ".join(f"{k}x{v}" for k, v in h.items()))
    if args.json:
        Path(args.json).write_text(json.dumps(
            {"report": str(rpt), "header": header, "levels": levels,
             "summary": {"levels": len(levels), "total_ns": total, "healthy_ns": healthy,
                         "hot_ns": hot, "n_healthy": n_healthy,
                         "ps_per_healthy_level": healthy / max(n_healthy, 1) * 1000}},
            indent=2) + "\n")
        print(f"\n-> {args.json}")


if __name__ == "__main__":
    main()
