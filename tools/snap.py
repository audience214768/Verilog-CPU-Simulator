#!/usr/bin/env python3
"""snap.py —— 把一次综合的产物**归档进仓库** + 追加一行汇总表。

背景: 历史最优 f3 (13.3096 ns) 的证据只活在 /tmp 里, 一旦被清就再也找不回来。
本脚本把每次跑的判分产物留在 docs/timing/<tag>/, 并把一行自解释的记录追加进
docs/timing/results.csv, 于是"某版为什么快"永远可追溯。

只归档小文件 (每版约 600 KB): 丢掉 design.json (73 MB, 而且命名空间与 mapped.v
不相交, 见 tools/README.md)、elaborated.json (30 MB)、mapped.v (13 MB)。
synth.log (2.3 MB) 里只留 alumacc 的 RTL 行号归因, 蒸馏成 alu_sites.txt。

用法:
  tools/snap.py --artifacts build/synth_f3/opt --tag f3 --rev 31ba35f \
                --params "ROB=32,RS=16,PRF=64,LSQ=16,BHT=32,RAS=8" \
                --ipc "1.0536,3.6331,0.8828,0.9107,3.1922,1.7223" --note "手法1×2"
"""
import argparse
import csv
import json
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

KEEP = ("report.json", "timing_values.json", "area.json", "area_report.json",
        "report.txt", "critical_paths.json", "timing.rpt", "stat.json")
ALU_RE = re.compile(r"^.*creating \$(?:alu|macc|mul|add|sub) cell for (\S+).*$", re.M)
COLS = ["tag", "date", "git_rev", "git_dirty", "params", "filelist", "area_um2",
        "seq_area_um2", "sram_area_um2", "min_period_ns", "fmax_mhz", "slack_ns",
        "levels", "healthy_levels", "healthy_ns", "hot_ns", "ps_per_level",
        "ceiling_mhz", "top_hotnets", "ipc6", "note"]


def sh(*cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True, help="含 timing.rpt 的产物目录")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--rev", default="", help="git rev (默认查仓库当前)")
    ap.add_argument("--params", default="", help="参数串, 原样记录")
    ap.add_argument("--filelist", default="verilog/filelist.f")
    ap.add_argument("--ipc", default="", help="6 条 perf 的 IPC, 逗号分隔")
    ap.add_argument("--note", default="")
    ap.add_argument("--dirty", default=None,
                    help="覆盖 git_dirty (归档历史产物时不能拿当前工作区状态冒充)")
    ap.add_argument("--root", default="docs/timing")
    args = ap.parse_args()

    art = Path(args.artifacts).resolve()
    if not (art / "timing.rpt").is_file():
        sys.exit(f"没有 timing.rpt: {art}")
    dest = Path(args.root) / args.tag
    dest.mkdir(parents=True, exist_ok=True)
    for name in KEEP:
        if (art / name).is_file():
            shutil.copy2(art / name, dest / name)
    # alumacc 的 RTL 行号归因 —— 官方 synth.log 免费给的, 蒸馏留档
    sites = 0
    if (art / "synth.log").is_file():
        found = ALU_RE.findall((art / "synth.log").read_text(errors="replace"))
        (dest / "alu_sites.txt").write_text("\n".join(found) + "\n")
        sites = len(found)
    # 路径解剖
    pj = dest / "path.json"
    subprocess.run([sys.executable, str(Path(__file__).with_name("path.py")), str(art),
                    "--json", str(pj), "--top", "0"], check=True, capture_output=True)

    tv = json.loads((dest / "timing_values.json").read_text())
    ar = json.loads((dest / "area.json").read_text())
    p = json.loads(pj.read_text())
    s = p["summary"]
    hot = [f"{l['fanout']}@{l['cell'].split('_')[0]}"
           for l in sorted(p["levels"], key=lambda x: -x["fanout"])[:5]]
    row = {
        "tag": args.tag, "date": date.today().isoformat(),
        "git_rev": args.rev or sh("git", "rev-parse", "--short", "HEAD"),
        "git_dirty": args.dirty if args.dirty is not None
        else ("yes" if sh("git", "status", "--porcelain") else "no"),
        "params": args.params, "filelist": args.filelist,
        "area_um2": f"{ar['area_um2']:.3f}", "seq_area_um2": f"{ar['sequential_area_um2']:.3f}",
        "sram_area_um2": f"{ar['sram_area_um2']:.3f}",
        "min_period_ns": f"{tv['minimum_period_ns']:.4f}",
        "fmax_mhz": f"{tv['estimated_fmax_mhz']:.2f}",
        "slack_ns": f"{tv['worst_setup_slack_ns']:.4f}",
        "levels": s["levels"], "healthy_levels": s["n_healthy"],
        "healthy_ns": f"{s['healthy_ns']:.4f}", "hot_ns": f"{s['hot_ns']:.4f}",
        "ps_per_level": f"{s['ps_per_healthy_level']:.1f}",
        "ceiling_mhz": f"{1000.0 / s['healthy_ns']:.0f}",
        "top_hotnets": " ".join(hot), "ipc6": args.ipc, "note": args.note,
    }
    csv_path = Path(args.root) / "results.csv"
    if csv_path.is_file():  # 已有同名 tag 就替换该行, 否则追加
        with csv_path.open() as fh:
            old = list(csv.reader(fh))
        rows = [old[0]] + [r for r in old[1:] if r and r[0] != args.tag]
    else:
        rows = [COLS]
    rows.append([str(row[c]) for c in COLS])
    with csv_path.open("w", newline="") as fh:
        csv.writer(fh).writerows(rows)
    print(f"归档 {dest}  (alumacc 归因 {sites} 条)")
    print("  " + "  ".join(f"{k}={row[k]}" for k in
                           ("min_period_ns", "fmax_mhz", "area_um2", "levels",
                            "healthy_ns", "hot_ns", "ceiling_mhz", "top_hotnets")))


if __name__ == "__main__":
    main()
