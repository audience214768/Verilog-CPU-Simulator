#!/usr/bin/env python3
"""离线 D-cache 命中率模拟 (零 RTL、零面积) —— 回答"加 D-cache 值不值"。

输入: tb/top/tb_cpu_prog.v 用 +LTRACE=1 落下的地址流 sim/ltr_<prog>.txt
      行格式 "L|S <8位hex地址> <宽度码>" (宽度码 0=字节 1=半字 2=字)
      只含**被接受**的 load 与**真正落盘**的 store (MMIO 停机写已剔除), 见 TB 内注释。

做两件事:
  1. 扫 容量 × 相联度 × 行大小, 出逐程序命中率 H 与工作集行数;
  2. 把 H 折成**等效平均延迟** L_eff = H*hit + (1-H)*miss (hit=2, miss=10 —— 官方
     LATENCY 口径), 再用官方实测的"延迟 → IPC"曲线插值出预估 IPC。

口径与局限 (结论必须带上这几条):
  * hit=2 取自官方 LATENCY=2 那个**全命中上界**实测点, 不是真实 cache 的 tag+data 拍数;
  * L_eff 用算术平均代替真实 MLP 动态 —— 本核 LD_INFLIGHT=8, 多个 miss 会重叠,
    故这是**保守的一阶估计**(真实收益通常好于此);
  * trace 里 load 按**发射**序、store 按**提交**序, 二者交错与程序序不完全一致;
  * trace 来自 TB (无 I-cache), 但曲线取自官方运行 ⇒ 只借它做 IPC 映射。
"""

import sys
from pathlib import Path

# 官方实测 (runs/ic1k = ic1k 参数 + 本 HEAD RTL, make perf LATENCY=N, 自带正确性校验):
#   LATENCY  2      3      4      5      6      8      10
# 逐案值见 docs/plan.md; geo 0.5674 ... 0.4143
IPC_CURVE = {
    2:  {"perf_median": 0.4952, "perf_multiply": 0.6637, "perf_qsort": 0.4347,
         "perf_rsort": 0.5809, "perf_towers": 0.5718, "perf_vvadd": 0.7031},
    3:  {"perf_median": 0.4781, "perf_multiply": 0.6634, "perf_qsort": 0.4112,
         "perf_rsort": 0.5468, "perf_towers": 0.5340, "perf_vvadd": 0.6714},
    4:  {"perf_median": 0.4642, "perf_multiply": 0.6632, "perf_qsort": 0.3921,
         "perf_rsort": 0.5165, "perf_towers": 0.4985, "perf_vvadd": 0.6426},
    5:  {"perf_median": 0.4485, "perf_multiply": 0.6630, "perf_qsort": 0.3759,
         "perf_rsort": 0.4894, "perf_towers": 0.4665, "perf_vvadd": 0.6159},
    6:  {"perf_median": 0.4337, "perf_multiply": 0.6627, "perf_qsort": 0.3582,
         "perf_rsort": 0.4627, "perf_towers": 0.4376, "perf_vvadd": 0.5912},
    8:  {"perf_median": 0.4081, "perf_multiply": 0.6587, "perf_qsort": 0.3303,
         "perf_rsort": 0.4191, "perf_towers": 0.3833, "perf_vvadd": 0.5398},
    10: {"perf_median": 0.3797, "perf_multiply": 0.6537, "perf_qsort": 0.3071,
         "perf_rsort": 0.3830, "perf_towers": 0.3512, "perf_vvadd": 0.4932},
}

PROGS = sorted(IPC_CURVE[10])
HIT_LAT = 2      # 命中拍数 (官方 LATENCY=2 全命中实测点的口径)
MISS_LAT = 10    # 官方 LATENCY 默认值


def geo(xs):
    p = 1.0
    for x in xs:
        p *= x
    return p ** (1.0 / len(xs))


def parse(path):
    """→ [(addr, size_bytes, is_store)] ; 宽度码 0/1/2 → 1/2/4 字节"""
    out = []
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if len(f) != 3:
            continue
        out.append((int(f[1], 16), 1 << int(f[2]), f[0] == "S"))
    return out


class Cache:
    """组相联, LRU。store 策略 (STORE_POL) 决定"提交级 store 怎么动缓存":

      alloc   写分配+写回 —— store 未命中**先取行**(占 AXI 读通道), 命中即更新 (**乐观上界**, 真做要加读流量)
      update  写直达 + 命中更新 + 未命中不分配 —— 与 store_queue 直连 AXI 的现实实现最接近
      wbinv   写直达 + 命中**失效整行** + 未命中不分配 —— 最省事 (一位 valid 清零), 代价是丢同行其余字
      none    store 完全不碰缓存 —— 只用来量"store 策略到底值多少命中率"的敏感度
    （真实设计不会用写回: 脏行驱逐要加写口与状态机, 而 store_queue 已经把写送出去了。)
    """

    def __init__(self, cap_bytes, ways, line_bytes, STORE_POL="update"):
        self.line = line_bytes
        self.ways = ways
        self.sets = cap_bytes // (ways * line_bytes)
        self.pol = STORE_POL
        self.tag = [[-1] * ways for _ in range(self.sets)]   # -1 = 空 (-1 不是合法 tag: tag 从 0 起)
        self.lru = [[0] * ways for _ in range(self.sets)]    # 越大越新

    def access(self, addr, is_store):
        ln = addr // self.line
        s = ln % self.sets
        tg = ln // self.sets
        row, age = self.tag[s], self.lru[s]
        for w in range(self.ways):
            if row[w] == tg:
                if is_store and (self.pol == "wbinv"):
                    row[w] = -1               # 失效: 之后必须重新取行
                    return True               # 对 store 自己而言"命中了"(不产生取行流量)
                age[w] = max(age) + 1
                return True
        if is_store and (self.pol != "alloc"):
            return False                      # 写不分配: 不取行, 也不留行
        w = age.index(min(age))          # 空行 age 恒为 0 ⇒ 优先填空行
        row[w] = tg
        age[w] = max(age) + 1
        return False

    def run(self, accs):
        """→ (hit, tot, 触及行数, AXI 读拍数, load 拍数基线)

        读拍数 = 缺失次数 × 行字数 (每次取行要逐字发 AR); 基线 = 无缓存时每个 load 一拍。
        两者相除就是"加缓存后 AXI 读通道占用是原来的几倍" —— 行大小越大, 命中率越高但填充越贵。
        """
        hit = tot = miss = nload = 0
        lines = set()
        for addr, size, is_store in accs:
            # 一次访存按其**触及的不同行**各计一次 (跨行访问不能漏; 同一次访问内的重复字节合并)
            for ln in {a // self.line for a in range(addr, addr + size, 1)}:
                lines.add(ln)
                tot += 1
                if not is_store:
                    nload += 1
                if self.access(ln * self.line, is_store):
                    hit += 1
                else:
                    miss += 1
        return hit, tot, len(lines), miss * (self.line // 4), nload


class WordCache:
    """**字粒度**对照模型 (无行、无填充 FSM):

    索引 = 字地址的低位, tag = 字地址的高位; 命中即交付 (AXI 一拍不发), 缺失走原通路并**当场安装**
    该字。store 提交时命中即按字节更新 (未命中不分配) —— 与 [update] 同策略。

    与行缓存的差别只有两点, 但两点都很值钱:
      * 缺失代价 = 基线 (1 拍 AR), **AXI 读流量不增反降** (命中的 load 完全不发 AR);
      * 不需要"一次取整行"⇒ 没有填充 FSM、没有 early restart、没有 ld_busy 阻塞,
        交付路径仍是"接受 → 1 拍 SRAM 读 → 下一拍交付"的定长 2 拍。
    代价是空间局部性只靠"相邻字落在不同索引"间接吃到 (行缓存是显式吃到)。
    """

    def __init__(self, entries, ways):
        self.ways = ways
        self.sets = entries // ways
        self.tag = [[-1] * ways for _ in range(self.sets)]
        self.lru = [[0] * ways for _ in range(self.sets)]

    def access(self, addr, is_store):
        wa = addr >> 2                      # 字地址 (load/store 不跨字: 见 mem_subsystem 的对齐约束)
        s = wa % self.sets
        tg = wa // self.sets
        row, age = self.tag[s], self.lru[s]
        for w in range(self.ways):
            if row[w] == tg:
                age[w] = max(age) + 1
                return True
        if is_store:
            return False                    # 写不分配 (与 [update] 同)
        w = age.index(min(age))
        row[w] = tg
        age[w] = max(age) + 1
        return False

    def run(self, accs):
        """→ (hit, tot, 唯一字数, AXI 读拍数, load 拍数基线)

        AXI 读拍数 = **load** 的缺失数 (每缺失 1 拍 AR); store 走写通道, 不占读通道。
        """
        hit = tot = nload = lmiss = 0
        words = set()
        for addr, size, is_store in accs:
            for wa in {a >> 2 for a in range(addr, addr + size, 1)}:
                words.add(wa)
                tot += 1
                if not is_store:
                    nload += 1
                if self.access(wa << 2, is_store):
                    hit += 1
                elif not is_store:
                    lmiss += 1
        return hit, tot, len(words), lmiss, nload


class WBCache:
    """**写回/写直达 × 写分配/不分配** 且带总线记账 —— 检查点 0 的选型工具 (plan §检查点 0)。

    两个正交开关, 组成三种可用策略 (WB=0,WA=1 不自洽, 不实现):
      WB=0, WA=0  写直达 + 命中就地更新  —— 检查点 1 的目标 (无脏位)
      WB=1, WA=0  写回 + 缺失不分配      —— 命中即改在缓存里, 缺失那笔直送内存 (无 RFO)
      WB=1, WA=1  写回 + 写分配          —— 检查点 2 的目标 (缺失先 RFO 取整行)
    记账 (逐拍):
      load 缺失       → 填充 AR += 行字数; 受害行脏 → 写回 W += 行字数
      store 命中,WB=1 → 就地更新 + 置脏, **零总线流量** (写回的全部价值)
      store 命中,WB=0 → 写直达: W += 1
      store 缺失,WA=1 → RFO: AR += 行字数, 占位 ⇒ 之后的 load 可能白捡
      store 缺失,WA=0 → W += 1 (1 AW + 1 W + 1 B), 不占位, 该行之后仍会缺失
    判据 (预注册): **store 拉回的行要划算 ⟺ 它省下的 load 缺失次数 ≥ 拉回的行数**
      —— 两边都是 lw 笔 AR, 约掉即 saved_lmiss / st_alloc ≥ 1。
    """

    def __init__(self, cap_bytes, ways, line_bytes, WA=True, WB=True):
        self.line = line_bytes
        self.lw = line_bytes // 4
        self.ways = ways
        self.sets = cap_bytes // (ways * line_bytes)
        self.wa = WA
        self.wb = WB
        self.tag = [[-1] * ways for _ in range(self.sets)]
        self.lru = [[0] * ways for _ in range(self.sets)]
        self.dirty = [[False] * ways for _ in range(self.sets)]
        self.touch = [[0] * ways for _ in range(self.sets)]      # 装入后被碰过的次数 (判据用)
        self.fromst = [[False] * ways for _ in range(self.sets)]  # 该行是 store 缺失拉回来的
        self.hit = self.tot = 0
        self.lhit = self.ltot = self.shit = self.stot = 0
        self.ar = self.wr = 0
        self.st_alloc = self.st_alloc_reuse = 0   # store 拉回的行数 / 其中"换出前又被碰过"
        self.saved_lmiss = 0                      # 落在 store 拉回行上的 load 命中次数

    def _close(self, s, w, flushing):
        """一行离场 (或收尾): 结判据的账; flushing=1 才真的算写回流量 (退出时不必写回)。"""
        if self.fromst[s][w]:
            self.st_alloc += 1
            if self.touch[s][w] > 1:
                self.st_alloc_reuse += 1
        if flushing and self.dirty[s][w]:
            self.wr += self.lw
        self.dirty[s][w] = False

    def access(self, addr, is_store):
        ln = addr // self.line
        s = ln % self.sets
        tg = ln // self.sets
        row, age = self.tag[s], self.lru[s]
        self.tot += 1
        if is_store:
            self.stot += 1
        else:
            self.ltot += 1
        for w in range(self.ways):
            if row[w] == tg:
                age[w] = max(age) + 1
                self.touch[s][w] += 1
                self.hit += 1
                if is_store:
                    self.shit += 1
                    if self.wb:
                        self.dirty[s][w] = True    # 写回: 命中即改在缓存里, 不上总线
                    else:
                        self.wr += 1               # 写直达: 命中也要把这一笔发到内存
                else:
                    self.lhit += 1
                    if self.fromst[s][w]:
                        self.saved_lmiss += 1      # 判据的"省下来的 load 缺失"
                return True
        if is_store and not self.wa:
            self.wr += 1                           # 写直达: 1 笔 W, 不占位
            return False
        self.ar += self.lw                         # 填充 / RFO 都逐字发 AR
        w = age.index(min(age))
        if row[w] >= 0:
            self._close(s, w, True)
        row[w] = tg
        age[w] = max(age) + 1
        self.dirty[s][w] = is_store and self.wb   # 写直达没有脏行 (内存恒为最新)
        self.touch[s][w] = 1
        self.fromst[s][w] = is_store
        return False

    def run(self, accs):
        for addr, size, is_store in accs:
            for ln in {a // self.line for a in range(addr, addr + size, 1)}:
                self.access(ln * self.line, is_store)
        for s in range(self.sets):                 # 收尾: 只结判据的账, 不算写回流量
            for w in range(self.ways):
                if self.tag[s][w] >= 0:
                    self._close(s, w, False)
        return self

    def row(self, p):
        return dict(prog=p, allH=self.hit / self.tot, loadH=self.lhit / self.ltot,
                    storeH=self.shit / self.stot, ar=self.ar, wr=self.wr,
                    st_alloc=self.st_alloc, st_alloc_reuse=self.st_alloc_reuse,
                    saved=self.saved_lmiss, nload=self.ltot)


VARIANTS = [
    ("写直达+命中更新", dict(WA=False, WB=False)),   # 检查点 1
    ("写回+不分配",     dict(WA=False, WB=True)),    # 检查点 2 备选 A
    ("写回+写分配",     dict(WA=True,  WB=True)),    # 检查点 2 备选 B
]


def checkpoint0():
    """检查点 0: 在**当前几何**下对照三种 store 策略 (零 RTL 选型)。

    开跑前已预注册 (plan §检查点 0):
      判据 = saved_lmiss / st_alloc ≥ 1 (store 拉回的行必须至少白捡一次 load 缺失);
      预测 = towers/qsort/rsort (写多、行内复用) 受益; vvadd (顺序流) 受损或持平。
    """
    import os
    cap = int(os.environ.get("DC_SIZE", 2048))
    ways = int(os.environ.get("DC_WAYS", 2))
    line = int(os.environ.get("DC_LINE_WORDS", 8)) * 4
    d = Path("sim")
    traces = {p: d / f"ltr_{p}.txt" for p in PROGS}
    missing = [p for p, f in traces.items() if not f.exists()]
    if missing:
        sys.exit(f"缺 trace: {missing}")
    accs = {p: parse(f) for p, f in traces.items()}
    print(f"== 检查点 0: store 策略对照 @ {cap}B / {ways} 路 / {line}B 行 (lw={line // 4}) ==")

    res = {p: [WBCache(cap, ways, line, **kw).run(accs[p]) for _, kw in VARIANTS]
           for p in PROGS}
    n = len(VARIANTS)

    print("\n-- 一、命中率 (loadH / storeH) --")
    print(f"{'程序':<14}" + "".join(f"{nm:>20}" for nm, _ in VARIANTS) + f"{'idxinv all-H':>14}")
    for p in PROGS:
        ihit, itot, _, _, _ = Cache(cap, ways, line, "wbinv").run(accs[p])
        print(f"{p:<14}" + "".join(
            f"{r.lhit / r.ltot:>10.3f}/{r.shit / r.stot:<9.3f}" for r in res[p])
            + f"{ihit / itot:>14.3f}")

    print("\n-- 二、AXI 通道拍数 (AR 读 / W 写; 现 RTL = 每条 store 都发一笔 W) --")
    print(f"{'程序':<14}" + "".join(f"{nm:>20}" for nm, _ in VARIANTS) + f"{'idxinv W':>10}")
    for p in PROGS:
        st = sum(1 for a in accs[p] if a[2])     # 现 RTL: store 全量走写通道
        print(f"{p:<14}" + "".join(f"{r.ar:>10}/{r.wr:<9}" for r in res[p]) + f"{st:>10}")

    print("\n-- 三、预注册判据: store 拉回的行划不划算 (只对'写回+写分配', 判据 = saved/alloc ≥ 1) --")
    print(f"{'程序':<14}{'拉回行':>8}{'其中复用':>9}{'复用率':>8}{'省下load缺失':>13}"
          f"{'saved/alloc':>12}{'RFO_AR':>8}")
    for p in PROGS:
        a = res[p][-1]
        r = a.saved_lmiss / a.st_alloc if a.st_alloc else float("nan")
        print(f"{p:<14}{a.st_alloc:>8}{a.st_alloc_reuse:>9}"
              f"{a.st_alloc_reuse / a.st_alloc if a.st_alloc else 0:>8.3f}"
              f"{a.saved_lmiss:>13}{r:>12.2f}{a.st_alloc * a.lw:>8}")

    print("\n-- 四、折算 IPC (沿用本脚本已标定的'命中率→等效延迟→IPC'映射; all-H / load-H) --")
    print(f"{'程序':<14}" + "".join(f"{nm:>20}" for nm, _ in VARIANTS) + f"{'idxinv':>10}")
    gs = [[] for _ in range(n * 2)]
    gi = []
    for p in PROGS:
        ihit, itot, _, _, _ = Cache(cap, ways, line, "wbinv").run(accs[p])
        hi = ihit / itot if itot else 1.0
        ii = ipc_at(hi * HIT_LAT + (1 - hi) * MISS_LAT, p)
        gi.append(ii)
        cells = ""
        for k, r in enumerate(res[p]):
            for tag, h in ((k, r.hit / r.tot), (n + k, r.lhit / r.ltot)):
                gs[tag].append(ipc_at(h * HIT_LAT + (1 - h) * MISS_LAT, p))
            a = ipc_at(r.hit / r.tot * HIT_LAT + (1 - r.hit / r.tot) * MISS_LAT, p)
            b = ipc_at(r.lhit / r.ltot * HIT_LAT + (1 - r.lhit / r.ltot) * MISS_LAT, p)
            cells += f"{a:>10.4f}/{b:<9.4f}"
        print(f"{p:<14}{cells}{ii:>10.4f}")
    print(f"{'geo':<14}" + "".join(
        f"{geo(gs[k]):>10.4f}/{geo(gs[n + k]):<9.4f}" for k in range(n)) + f"{geo(gi):>10.4f}")

    print("\n  ⚠ 口径局限: ① AR/W 只是 D-cache 侧记账, 未计三路 AR 仲裁里 I-cache 的争用;"
          "\n     ② all-H 把 store 命中与 load 命中同等折成延迟, 而 store 不产生结果 ⇒ 对写直达偏严;"
          "\n     ③ 不含 SQ 排队与 B 往返 —— 'store 不再等 B' 这笔收益要 RTL 落地才量得到。")


def ipc_at(lat, prog):
    """在官方实测曲线上线性插值 (超出 [2,10] 取端点)"""
    ks = sorted(IPC_CURVE)
    if lat <= ks[0]:
        return IPC_CURVE[ks[0]][prog]
    if lat >= ks[-1]:
        return IPC_CURVE[ks[-1]][prog]
    lo = max(k for k in ks if k <= lat)
    hi = min(k for k in ks if k >= lat)
    if lo == hi:
        return IPC_CURVE[lo][prog]
    t = (lat - lo) / (hi - lo)
    return IPC_CURVE[lo][prog] * (1 - t) + IPC_CURVE[hi][prog] * t


def main():
    d = Path("sim")
    traces = {p: d / f"ltr_{p}.txt" for p in PROGS}
    missing = [p for p, f in traces.items() if not f.exists()]
    if missing:
        sys.exit(f"缺 trace: {missing} —— 先跑 "
                 f"for P in {' '.join(PROGS)}; do bench_ic1k +PROG=$P +LTRACE=1; done")

    accs = {p: parse(f) for p, f in traces.items()}
    print("== 逐程序访问构成 (来自 TB trace, 含被接受的 load 与落盘 store) ==")
    for p in PROGS:
        a = accs[p]
        wset = len({x[0] // 16 for x in a})
        span = max(x[0] for x in a) - min(x[0] for x in a)
        print(f"  {p:<16} 访问={len(a):>6}  地址跨度={span / 1024:>7.1f} KB  "
              f"触及 16B 行={wset:>6} ({wset * 16 / 1024:.1f} KB)")

    best = None
    for pol in ("update", "wbinv", "alloc", "none"):
        print(f"\n== [{pol}] 命中率 / 等效延迟 / 预估 IPC (hit=2, miss=10) ==")
        print(f"{'配置':<22} {'geoH':>6} {'L_eff':>6} {'预估IPC':>8} {'vs 0.4143':>10} {'AXI读拍/基线':>14}")
        rows = []
        for cap in (1024, 2048, 4096, 8192):
            for ways in (1, 2):
                for line in (16, 32, 64):
                    hs, beats, base = {}, 0, 0
                    for p in PROGS:
                        hit, tot, _, b, nld = Cache(cap, ways, line, pol).run(accs[p])
                        hs[p] = hit / tot if tot else 1.0
                        beats += b
                        base += nld
                    g = geo([hs[p] for p in PROGS])
                    leff = g * HIT_LAT + (1 - g) * MISS_LAT
                    ipc = geo([ipc_at(leff, p) for p in PROGS])
                    rows.append((ipc, cap, ways, line, g, leff, hs, beats / base))
        rows.sort(reverse=True)
        for ipc, cap, ways, line, g, leff, hs, bp in rows:
            print(f"{cap // 1024}KB {ways}路 {line:>2}B".ljust(22) +
                  f" {g:>6.3f} {leff:>6.2f} {ipc:>8.4f} {ipc / 0.4143:>9.1%} {bp:>13.2f}x")
        if pol == "update":
            best = rows[0]

    print("\n== 字粒度对照 (无行/无填充 FSM; store 命中即更新, 未命中不分配) ==")
    print("   ⚠ geoH 恒 0.000 **不是 bug**: vvadd/multiply 的 load 地址**零重访** "
          "(vvadd 1200 个 load 全落在 1200 个不同字上), 空间局部性只能靠'整行取回'吃到,")
    print("     字粒度缓存既拿不到时间局部性也拿不到空间局部性 ⇒ 该结构**直接出局**, 不必再算容量。")
    print(f"{'配置':<22} {'geoH':>6} {'L_eff':>6} {'预估IPC':>8} {'vs 0.4143':>10} {'AXI读拍/基线':>14}")
    wrows = []
    for ent in (128, 256, 512, 1024, 2048):
        for ways in (1, 2):
            hs, beats, base = {}, 0, 0
            for p in PROGS:
                hit, tot, _, b, nld = WordCache(ent, ways).run(accs[p])
                hs[p] = hit / tot if tot else 1.0
                beats += b
                base += nld
            g = geo([hs[p] for p in PROGS])
            leff = g * HIT_LAT + (1 - g) * MISS_LAT
            ipc = geo([ipc_at(leff, p) for p in PROGS])
            wrows.append((ipc, ent, ways, g, leff, hs, beats / base))
    wrows.sort(reverse=True)
    for ipc, ent, ways, g, leff, hs, bp in wrows:
        print(f"{ent * 4 // 1024}KB 字阵列 {ways}路".ljust(22) +
              f" {g:>6.3f} {leff:>6.2f} {ipc:>8.4f} {ipc / 0.4143:>9.1%} {bp:>13.2f}x")

    print("\n== 最优配置的逐程序明细 ([update] 策略) ==")
    _, cap, ways, line, g, leff, hs, _bp = best
    print(f"  配置: {cap // 1024}KB / {ways} 路组相联 / {line}B 行   (geoH={g:.3f}, L_eff={leff:.2f})")
    for p in PROGS:
        print(f"  {p:<16} H={hs[p]:>6.3f}  L_eff={hs[p] * HIT_LAT + (1 - hs[p]) * MISS_LAT:>5.2f}  "
              f"IPC {IPC_CURVE[10][p]:.4f} → {ipc_at(hs[p] * HIT_LAT + (1 - hs[p]) * MISS_LAT, p):.4f}")


if __name__ == "__main__":
    if "--ckpt0" in sys.argv:
        checkpoint0()
    else:
        main()
