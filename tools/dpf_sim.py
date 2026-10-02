#!/usr/bin/env python3
"""dpf_sim.py —— D 侧"下一行预取"的**离线覆盖率**模拟 (零 RTL、零面积、零波形)。

为什么要有它: §35 量到"等存储的 60~79% 是 head load 等**自己那笔需求缺失的回包**, 往返恒 14 拍,
且推送时零排队" ⇒ 唯一的方向是**减少 head 遇到的缺失次数**。但 S3b 的"相邻缺失行"直方图
量的是"这一次缺失的下一笔缺失在哪一行", 那**不是**下一行预取的覆盖率 ——
预取的触发键是**本笔缺失的地址**(缺失在 L ⇒ 取 L+1), 与"下一笔缺失在哪"无关。
所以覆盖率必须单独模拟。这就是本脚本存在的唯一理由。

模型 (与 tools/dcache_sim.py 的 `update` 策略一致, 见其头注):
  * 组相联 + LRU, 写直达 + 命中就地更新 + 未命中不分配 (无脏位、无写回);
  * 行粒度, 一次访存按其**触及的不同行**各计一次;
  * 预取 = 往缓存里安装一行, 与需求取行**同价** (各 DC_LINE_WORDS 拍 AR)。

两种触发口径 (都实现, 因为代价不同):
  onmiss  只在**该行缺失**时预取它的下一行     —— 触发少、看起来精准
  always 只要**该行命中/存在**且下一行不在就预取 —— I-cache 现行做法 (icache.v:264-268), 触发多

**口径局限 (结论必须带上)**:
  * 真实 dcache 的填充会被**污染中止** (`fill_abort_w`, 未可见 store 落在本行) ⇒ 预取的行也可能
    被作废, 本模型看不见这一层 ⇒ **高估**。§30.3 记过 rsort 行首污染率 75%, 须据此打折;
  * 真实读通道三路共享 (需求 > I 填充 > D 填充), 预取会挤压需求 AR ⇒ 本模型只报**新增读拍数**,
    不给排队时延; §35 实测"推送零排队"是**当前**状态, 加预取后不保证;
  * 命中率→IPC 的折算**不在这里做**: 本脚本只出"消除了多少笔需求缺失", 折算按
    Δcyc = 消除笔数 × (实测"长段拍/缺失数") 的**事件式**口径在 docs/plan.md 里算。

用法: tools/dpf_sim.py [容量 路数 行字节]     默认 1024 2 32 = student_top 现行 c2
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcache_sim import PROGS, parse          # noqa: E402  (复用同一个 trace 解析与程序表)


class PfCache:
    """组相联 LRU; 可选下一行预取。`mode='off' | 'onmiss' | 'always'`"""

    def __init__(self, cap, ways, line, mode="off"):
        self.line = line
        self.ways = ways
        self.sets = cap // (ways * line)
        self.mode = mode
        self.tag = [[-1] * ways for _ in range(self.sets)]
        self.lru = [[0] * ways for _ in range(self.sets)]
        self.pf = [[False] * ways for _ in range(self.sets)]   # 该路是否由预取装入 (供"有用率"统计)
        self.pf_issued = self.pf_useful = 0

    def _find(self, s, tg):
        for w in range(self.ways):
            if self.tag[s][w] == tg:
                return w
        return -1

    def _install(self, ln, prefetched):
        s = ln % self.sets
        tg = ln // self.sets
        w = self.lru[s].index(min(self.lru[s]))          # 空路 age=0 ⇒ 优先填空路
        self.tag[s][w] = tg
        self.lru[s][w] = max(self.lru[s]) + 1
        self.pf[s][w] = prefetched

    def _access(self, addr, is_store):
        """→ (命中?, 本次是否触发了 demand 取行)"""
        ln = addr // self.line
        s = ln % self.sets
        tg = ln // self.sets
        w = self._find(s, tg)
        if w >= 0:
            if self.pf[s][w] and not is_store:
                self.pf_useful += 1
            self.pf[s][w] = False
            self.lru[s][w] = max(self.lru[s]) + 1
            miss = False
        else:
            if is_store:
                return False, False                      # 写直达 + 未命中不分配: 不取行
            self._install(ln, False)
            miss = True
        # ---- 预取: 触发键是**本次访问的行**, 不是"下一笔缺失的行" ----
        if self.mode != "off" and (self.mode == "always" or miss):
            nl = ln + 1
            if self._find(nl % self.sets, nl // self.sets) < 0:
                self._install(nl, True)
                self.pf_issued += 1
        return (w >= 0), miss

    def run(self, accs):
        """→ (load 缺失数, 预取发出数, 预取有用数, AXI 读拍数)"""
        lmiss = 0
        for addr, size, is_store in accs:
            for ln in {a // self.line for a in range(addr, addr + size, 1)}:
                hit, miss = self._access(ln * self.line, is_store)
                if miss and not is_store:
                    lmiss += 1
        return lmiss, self.pf_issued, self.pf_useful, (lmiss + self.pf_issued) * (self.line // 4)


def main():
    a = [int(x) for x in sys.argv[1:]]
    cap, ways, line = (a + [1024, 2, 32])[:3]
    d = Path("sim")
    accs = {}
    for p in PROGS:
        f = d / f"ltr_{p}.txt"
        if not f.exists():
            sys.exit(f"缺 trace: {f} —— 先 make -f Makefile.tb run TB=top/tb_cpu_prog "
                     f'ARGS="+PROG={p} +LTRACE=1 +DUMP=0"')
        accs[p] = parse(f)

    print(f"== D 侧下一行预取的离线覆盖率 ({cap}B / {ways} 路 / {line}B 行 = student_top c2 几何) ==")
    print(f"{'程序':<14}{'load缺失':>9}{'onmiss消除':>11}{'always消除':>11}"
          f"{'读拍(onm)':>11}{'读拍(alw)':>11}{'预取有用率':>11}")
    tot = {m: [0, 0, 0, 0] for m in ("off", "onmiss", "always")}
    for p in PROGS:
        row = {}
        for m in ("off", "onmiss", "always"):
            r = PfCache(cap, ways, line, m).run(accs[p])
            row[m] = r
            tot[m] = [x + y for x, y in zip(tot[m], r)]
        b = row["off"][0]
        e1 = b - row["onmiss"][0]
        e2 = b - row["always"][0]
        print(f"{p:<14}{b:>9}{e1:>11}{e2:>11}"
              f"{row['onmiss'][3] / (b * line // 4):>10.2f}x{row['always'][3] / (b * line // 4):>10.2f}x"
              f"{row['always'][2] / max(row['always'][1], 1):>10.1%}")
    b = tot["off"][0]
    print(f"{'合计':<14}{b:>9}{b - tot['onmiss'][0]:>11}{b - tot['always'][0]:>11}"
          f"{tot['onmiss'][3] / (b * line // 4):>10.2f}x{tot['always'][3] / (b * line // 4):>10.2f}x"
          f"{tot['always'][2] / max(tot['always'][1], 1):>10.1%}")
    print("\n  ⚠ 未建模: 填充**污染中止**（会作废预取行 ⇒ 本表高估）、三路 AR 争用（预取挤压需求 AR）、"
          "\n     SQ 旁路 store、以及预取行的安装与 head 需要它之间的**真实时序**（本表只算命中与否）。")


if __name__ == "__main__":
    main()
