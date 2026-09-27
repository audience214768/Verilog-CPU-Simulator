#!/usr/bin/env python3
"""preabc.py —— 生成**保留 RTL 名字**的 pre-ABC 网表 (归因用, 不是判分口径)。

官方 scripts/synth.py 跑完 abc 之后所有 RTL 名字都被丢掉 (只剩 _NNNNN_), 于是
"关键路径上这个 637 扇出的网到底是哪段 RTL"没法从判分产物里读出来。本脚本用同一套
read/synth 序列在 abc 之前把网表写出来, 名字还在, 扇出算术 (tools/fanout_model.py)
才能把网表数字对回 RTL 构造。

与官方路径的等价性 (已核实): 官方 elaborate 阶段把每个数组都打成
`Replacing memory \\x with list of registers`, 没有任何存储器被推断成 SRAM
(`configurations: []`), 所以省掉 prepare_memories/sram_fakeram 包装不影响网表结构。

口径纪律 (**重要**):
  - 宿主 yosys 0.68 / ASAP7 r27 与容器 0.63 / r28 不同源 ⇒ 本产物**只用于 RTL 名字
    归因**; 频率/面积一律引用容器官方产物 (docs/timing/<tag>/)。
  - 只读 verilog/filelist.f, 不碰 scripts/、Makefile。

用法:
  tools/preabc.py --out /tmp/preabc_ctrl
  tools/preabc.py --tree runs/ctrl --drop-memory --out /tmp/preabc_ctrl
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources  # noqa: E402  官方解析器, 保证与 synth.py 同语义

RAM_SOURCE = (ROOT / "scripts" / "ram" / "sram_fakeram.sv").name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".", help="仓库/变体树根 (含 verilog/ 与 scripts/)")
    ap.add_argument("--filelist", default=None, help="默认 <tree>/verilog/filelist.f")
    ap.add_argument("--drop-memory", action="store_true",
                    help="从读入列表里剔掉 core/memory.v (记录里那几次跑用的是 22 文件版)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stage", choices=("rtl", "gate"), default="rtl",
                    help="rtl=只展开进程与数组(名字还在, 秒级, 用于数扇出); "
                         "gate=一路跑到门级(与容器 pre-ABC 同构, 但宿主上要十几分钟)")
    ap.add_argument("--yosys", default=os.environ.get("YOSYS", "yosys"))
    args = ap.parse_args()

    tree = Path(args.tree).resolve()
    filelist = Path(args.filelist) if args.filelist else tree / "verilog" / "filelist.f"
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    sources = read_sources(filelist)
    if args.drop_memory:
        sources = [s for s in sources if s.name != "memory.v"]
    # 官方 elaborate 阶段把 sram_fakeram.sv 单独用 -noblackbox 读, 这里照做
    fakeram = next((s for s in sources if s.name == RAM_SOURCE), None)
    if fakeram is None:
        fakeram = (tree / "scripts" / "ram" / RAM_SOURCE)
    plain = [s for s in sources if s != fakeram]

    script = [
        *[f"read_verilog -sv -D SYNTHESIS {s}" for s in plain],
        f"read_verilog -sv -noblackbox -D SYNTHESIS {fakeram}",
        "hierarchy -top student_top",
        "proc",
        "memory_collect",
        # 数组在这里展开成触发器与读写树 —— 读口/写使能的扇出只有展开之后才看得见
        "memory",
        "opt_expr",
        "opt_clean",
        *([] if args.stage == "rtl" else [
            "hierarchy -check -top student_top",
            "synth -top student_top -noabc -flatten"]),
        f"write_verilog -noattr {out / 'preabc.v'}",
        f"write_json {out / 'preabc.json'}",
        f"tee -o {out / 'stat.json'} stat -json",
    ]
    (out / "preabc.ys").write_text("\n".join(script) + "\n")
    cmd = [args.yosys, "-Q", "-T", "-l", str(out / "preabc.log"), "-s", str(out / "preabc.ys")]
    print(f"[{len(plain) + 1} 个源文件; drop_memory={args.drop_memory}] -> {out}")
    subprocess.run(cmd, check=True)
    print((out / "stat.json").read_text()[:400] if (out / "stat.json").exists() else "(无 stat)")


if __name__ == "__main__":
    main()
