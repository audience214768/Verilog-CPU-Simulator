#!/usr/bin/env python3
"""loadtax.py —— 从 `mapped.v` 量**负载税分布**（与 ABC 无关的结构量）。

为什么需要它：官方 ABC **不缓冲也不 upsize**，一个网挂多少负载就是多少延时，所以"设计好不好"
在结构上就是一个问题：**负载被挂在哪、挂了多少**。而官方 `min_period_ns` 是 ABC 全局重分解的
产物 —— 它会**把一处省下的时间在别处还回去**（[§62] 实测：删掉锥 ① 的尾巴地板 3.54→0.38 ns，
上游同时 +1.93 ns、数据回程 +1.54 ns，官方数反而退 1.97%）。于是判"这刀有没有赢地面"必须
看**别的量**：本脚本给出全网的总驱动负担，用来区分"**删掉了负载**"与"**把负载挪了个位置**"。

用法（宿主直接跑，不需要容器）：
    tools/loadtax.py <mapped.v> [<mapped.v> ...]

口径：只看 `student_top` 这个模块体（设计是展平的；SRAM 宏是黑盒，不展开），对每个网数它出现在
多少个 `.port(net)` 连接里 = **负载脚数**。`clock`/`reset` 是广播网，单独看会盖住信号网，所以
阈值统计里保留它们但报告时点名（它们的扇出就是触发器数，不随刀的改动而变）。

**读法**：Σfanout 是全网总账。若一刀之后 Σfanout 基本不动（<1%）而某条路径的尾巴没了，
那这刀就是**搬位置**而不是**删负担** —— 官方数大概率不会涨，别把这刀当收益记。
"""
import collections
import re
import sys


def loads(path):
    """student_top 模块体里, 每个网被多少个输入脚读。"""
    txt = open(path, errors="ignore").read()
    i = txt.find("module student_top")
    if i < 0:
        sys.exit("no student_top in " + path)
    body = txt[i:txt.find("\nendmodule", i)]
    fan = collections.Counter()
    for m in re.finditer(r"^\s*(\w+)\s+(\S+)\s*\((.*?)\);", body, re.S | re.M):
        for pm in re.finditer(r"\.(\w+)\(([^)]*)\)", m.group(3)):
            net = pm.group(2).strip()
            if net:
                fan[net] += 1
    return fan


def report(path):
    fan = loads(path)
    tot = sum(fan.values())
    print("=== %s" % path)
    print("  网数 %d   负载脚总数 Sigma-fanout %d" % (len(fan), tot))
    for thr in (16, 32, 64, 128):
        sel = {k: v for k, v in fan.items() if v >= thr}
        print("  扇出>=%-4d : 网数 %-5d  Sigma %-8d (%.1f%%)"
              % (thr, len(sel), sum(sel.values()), 100.0 * sum(sel.values()) / tot))
    top = sorted(fan.items(), key=lambda kv: -kv[1])[:8]
    print("  最大扇出: " + ", ".join("%s=%d" % (k, v) for k, v in top))


for p in sys.argv[1:]:
    report(p)

# ---- 已知的两点（2026-10-10 实测 cutD vs cutE）----------------------------
#   cutD: 网数 78758 / Sigma 299345 / >=64 网 335 / >=128 网 68
#   cutE: 网数 79377 / Sigma 301625 / >=64 网 334 / >=128 网 64     (+0.8% / -1 / -4)
# 即"锥 ① 写口打一拍"这一刀在全网账上**几乎没有变化** —— 它把那 3.54 ns 的尾巴删了，
# 但 ABC 重新分解后在别处又挂了差不多同样多的负载。这是本工具存在的理由。
