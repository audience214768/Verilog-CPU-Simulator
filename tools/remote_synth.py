#!/usr/bin/env python3
"""remote_synth.py —— 把**官方综合**挪到另一台机器 (ssh 可达) 上跑, 产物捞回本机归档。

    tools/remote_synth.py <ssh主机> <id> [--restart] [tools/run.sh 的参数...]
    例:  tools/remote_synth.py pc cutA3
         tools/remote_synth.py pc cutA3 LSQ_SIZE=8
         tools/remote_synth.py pc cutA3 --restart        # 远端同 id 的容器先杀掉再重跑

为什么值得挪: synth 是**单线程**、且对内存带宽敏感 —— 本机 2026-10-10 那次 4.4× 的拖慢
(整段 elaborate 5.9 min → 26 min) 全部来自宿主 swap 抖动 (6.2/7.2 GB), 不是 CPU 不够。
换一台空闲机器即回到 ~7–10 min/次。

远端前置 (只做一次):
  1) docker 可用 (WSL2: `sudo apt install docker.io` 或 Docker Desktop 的 WSL 集成);
  2) 镜像 tag 必须是 cpu2026:local, 且**用官方 Dockerfile 构建** —— pinned 版本
     (Yosys 70a11c6bf / ASAP7 r28 / OpenSTA f89887b5) 才与本机历史数字可比:
         rsync -az /Users/audience/opt/cpu2026-fw/ <host>:~/cpu2026-fw/
         ssh <host> 'cd ~/cpu2026-fw && docker build -t cpu2026:local .'
         ssh <host> 'docker run --rm cpu2026:local cat /opt/versions.txt'   # 与本机逐行相同
     ★ 本机这份镜像是 **arm64** (在 Apple Silicon 上构建的), 搬到 x86-64 只能 qemu 模拟 —— 别搬。

同步策略: 只推源码 (verilog/ scripts/ tools/ Makefile config.mk, 共 ~1 MB);
  **runs/ 有 17 GB, 一个字节都不推**。跑完只捞 snap.py 需要的那 8 个小文件 + 两个日志。
"""
import argparse
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAYLOAD = ["verilog", "scripts", "tools", "Makefile", "config.mk"]
KEEP = ["report.json", "timing_values.json", "area.json", "area_report.json",
        "report.txt", "critical_paths.json", "timing.rpt", "stat.json", "abc.constr"]
CAP_S = 5400            # 观察上限 90 min
HEARTBEAT_S = 300


def local(cmd, check=True):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=check)


def remote(script, check=True, timeout=180):
    """远端一律走 `bash -s` + stdin 喂脚本, 免得在 ssh 参数里跟引号打架。"""
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                        HOST, "bash -s"], input=script, text=True,
                       capture_output=True, timeout=timeout)
    if check and p.returncode != 0:
        sys.exit("远端命令失败 (rc=%d):\n%s\n%s" % (p.returncode, script[:400], p.stderr[-2000:]))
    return p.stdout.strip()


ap = argparse.ArgumentParser(add_help=True)
ap.add_argument("host")
ap.add_argument("id")
ap.add_argument("--restart", action="store_true", help="杀掉远端同 id 的容器再重跑")
ap.add_argument("--remote-dir", default="cpu2026", help="远端仓库目录 (相对 $HOME)")
ap.add_argument("runargs", nargs="*", help="透传给 tools/run.sh 的参数, 如 LSQ_SIZE=8")
A, _extra = ap.parse_known_args()      # 认不出的参数 (如 --mode=diagnose) 全当 run.sh 的透传参数
A.runargs += _extra
HOST, ID = A.host, A.id

# ---------- 0) 远端体检 ----------
probe = remote("""
command -v rsync >/dev/null 2>&1 || { echo NO_RSYNC; exit 0; }
command -v docker >/dev/null 2>&1 || { echo NO_DOCKER; exit 0; }
docker image inspect cpu2026:local >/dev/null 2>&1 || { echo NO_IMAGE; exit 0; }
docker run --rm cpu2026:local true >/dev/null 2>&1 || { echo DOCKER_BROKEN; exit 0; }
printf 'OK %s\\n' "$HOME"
""")
verdict, _, rhome = probe.partition(" ")
if verdict == "NO_RSYNC":
    sys.exit("远端没有 rsync (两头都要有, 回传也用它): sudo apt install -y rsync")
if verdict == "NO_DOCKER":
    sys.exit("远端没有 docker。WSL2 里: sudo apt update && sudo apt install -y docker.io && sudo usermod -aG docker $USER (重登)")
if verdict == "NO_IMAGE":
    sys.exit("远端缺 cpu2026:local 镜像 —— 用官方 Dockerfile 构建:\n"
             "  rsync -az /Users/audience/opt/cpu2026-fw/ %s:~/cpu2026-fw/\n"
             "  ssh %s 'cd ~/cpu2026-fw && docker build -t cpu2026:local .'" % (HOST, HOST))
if verdict != "OK":
    sys.exit("远端 docker 跑不起来 (权限/守护进程?): %s" % probe)

RDIR = "%s/%s" % (rhome, A.remote_dir)
MODE = "opt"                                    # 透传参数里的 --mode=diagnose 决定产物目录
for _a in A.runargs:
    if _a.startswith("--mode="):
        MODE = _a.split("=", 1)[1]
if MODE != "opt":
    KEEP.append("mapped.v")                     # 归因必须带层次网表 (design.json 太大不回传)
OPT = "runs/%s/build/synth_%s/%s" % (ID, ID, MODE)


def find_alive():
    """远端正跑着本 id 的容器则返回容器 id (靠挂载点里的 /runs/<id> 认领)。"""
    out = remote("""
for c in $(docker ps -q --filter ancestor=cpu2026:local); do
    printf '%s ' "$c"
    docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c"
done
""")
    for line in out.splitlines():
        parts = line.split()
        if parts and ("/runs/%s" % ID) in " ".join(parts[1:]):
            return parts[0]
    return None


# ---------- 1) 已经在跑就贴上去 ----------
cid = find_alive()
if cid and A.restart:
    print("→ 杀掉远端同 id 容器 %s (--restart)" % cid)
    remote("docker rm -f %s" % shlex.quote(cid))
    cid = None

if not cid:
    # ---------- 2) 推源码 ----------
    print("→ rsync 源码 → %s:%s/ (不含 runs/)" % (HOST, RDIR))
    remote("mkdir -p %s/runs" % shlex.quote(RDIR))
    r = local(["rsync", "-az", "--delete", "--exclude", ".git"] + PAYLOAD +
              ["%s:%s/" % (HOST, RDIR)], check=False)
    if r.returncode != 0:
        sys.exit("rsync 失败:\n%s" % r.stderr[-2000:])

    # ---------- 3) 起 (断线不死; 日志落在远端 runs/_launch_<id>.log) ----------
    print("→ 远端起综合: tools/run.sh %s %s" % (ID, " ".join(A.runargs)))
    launch = "runs/_launch_%s.log" % ID
    # `{ ... & }` 不能省: 写成 `cd X && setsid .. &` 时, `&&` 让整串变成 AND-list, bash 得 fork
    # 个子 shell 来跑它 —— 那个子 shell 的 stdout 还是 ssh 的管道, 又要等 run.sh 结束才退,
    # 于是 ssh 永不返回 (实测 180 s 超时, 但远端其实已经在跑了)。加花括号后背景的是**简单命令**,
    # 子进程直接 exec、管道随即关闭, ssh ~2 s 返回。
    remote("cd %s && { setsid nohup bash tools/run.sh %s %s > %s 2>&1 < /dev/null & }; echo started"
           % (shlex.quote(RDIR), shlex.quote(ID),
              " ".join(shlex.quote(x) for x in A.runargs), shlex.quote(launch)))
    time.sleep(5)
else:
    print("→ 远端已有容器 %s 在跑 %s, 直接观察 (重跑加 --restart)" % (cid, ID))

# ---------- 4) 观察 (相位 + yosys utime, 用来区分"慢"和"死锁") ----------
POLL = """
cd %(rdir)s 2>/dev/null || { echo "nostart 0 0"; exit 0; }
if [ -f %(opt)s/timing_values.json ]; then p=done
elif [ -f %(opt)s/synth.log ]; then p=synth
elif [ -f %(opt)s/elaborate.log ]; then p=elaborate
else p=clone; fi
y=0
for c in $(docker ps -q --filter ancestor=cpu2026:local); do
    t=$(docker exec "$c" sh -c 'for q in /proc/[0-9]*; do [ "$(cat $q/comm 2>/dev/null)" = yosys ] && awk "{s+=\\$14+\\$15} END{print s}" $q/stat; done' 2>/dev/null)
    [ -n "$t" ] && y=$((y + t))
done
n=$(docker ps -q --filter ancestor=cpu2026:local | wc -l)
echo "$p $y $n"
""" % {"rdir": shlex.quote(RDIR), "opt": shlex.quote(OPT)}

t0 = time.time()
last_phase, last_beat, last_cpu = None, time.time(), -1
seen_container = False
while True:
    phase, cpu, ncont = (remote(POLL).split() + ["0", "0"])[:3]
    cpu = int(cpu)
    if phase != last_phase:
        print("[%4.0fs] 相位 %s → %s   yosys=%.0f s CPU" % (time.time() - t0, last_phase, phase, cpu / 100.0))
        last_phase = phase
    if phase == "done":
        print("[%4.0fs] ✔ 综合完成" % (time.time() - t0))
        break
    if ncont != "0":
        seen_container = True
    elif seen_container or time.time() - t0 > 300:
        # 见过容器又没了 = 流程退出; 5 min 还不见容器 = 压根没起来。启动头几秒 ncont=0 是正常的, 不算。
        tail = remote("tail -c 400 %s/%s 2>/dev/null" % (shlex.quote(RDIR), shlex.quote("runs/_launch_%s.log" % ID)), check=False)
        sys.exit("[%4.0fs] ✖ 远端流程退出了 (相位=%s, 无 timing_values.json)\n%s" % (time.time() - t0, phase, tail[-800:]))
    if time.time() - t0 > CAP_S:
        sys.exit("观察上限 %d min 到, 远端可能还在跑 —— 手工续: ssh %s 'tail -f %s/runs/_launch_%s.log'"
                 % (CAP_S // 60, HOST, RDIR, ID))
    if time.time() - last_beat > HEARTBEAT_S:
        print("[%4.0fs] 心跳 相位=%s yosys=%.0f s CPU (%s)"
              % (time.time() - t0, phase, cpu / 100.0, "在干活" if cpu > last_cpu else "!! utime 不涨: 疑死锁"))
        last_beat = time.time()
    last_cpu = cpu
    time.sleep(30)

# ---------- 5) 只捞回 snap.py 要的小文件 + 两个日志 ----------
dest = ROOT / OPT
dest.mkdir(parents=True, exist_ok=True)
r = local(["rsync", "-az", "--prune-empty-dirs", "--include=*/"] +
          ["--include=%s" % f for f in KEEP] + ["--exclude=*",
           "%s:%s/%s/" % (HOST, RDIR, OPT), str(dest) + "/"], check=False)
if r.returncode != 0:
    sys.exit("产物回传失败:\n%s" % r.stderr[-2000:])
local(["rsync", "-az", "%s:%s/runs/%s/synth_%s.log" % (HOST, RDIR, ID, ID), "runs/%s/" % ID], check=False)
local(["rsync", "-az", "%s:%s/runs/_launch_%s.log" % (HOST, RDIR, ID), "runs/%s/" % ID], check=False)

tv = (dest / "timing_values.json").read_text().strip()
print("\n产物已回传 → %s\n%s" % (OPT, tv))
print("\n归档: tools/snap.py --artifacts %s --tag %s" % (OPT, ID))
