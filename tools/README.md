# tools/ —— 频率归因工具链（**非官方**，不参与判分）

官方框架（`Makefile` / `Makefile.tb` / `scripts/` / `config.mk` / `verilog/filelist.f`）一律不动。
本目录只解决一个问题：**把"频率卡在哪"从猜测变成算术**。

## 0. 口径纪律（先读这条，否则后面所有数字都会骗人）

| 用途 | 唯一可信来源 |
|---|---|
| 频率 / 面积（**判分数**） | 容器 `cpu2026:local`（yosys 0.63 + ASAP7 **r28**）跑官方 `make synth`（**不带 `-constr`**） |
| 全设计扇出 / 路径普查（**可当判据**） | 判分产物的 `mapped.v` + `design.json`（`tools/bombs.py`）；容器 OpenSTA（`tools/census.tcl`） |
| RTL 名字归因（哪个信号、哪段 RTL） | **同版本**容器的 pre-ABC 网表（`pre_abc2.ys` 重放，见 §1 `bombs.py`） |

**`-constr` 不是判分口径**（2026-10-09 订正）：`docs/description.md` §5 的评测走官方 `make synth`，
ABC **没有** `set_driving_cell` / `set_load` ⇒ 不 buffer、不 upsize，**一个网的负载数就是它的延时**。
`tools/run.sh --constr` 是本机私有对照（给 ABC 多传一个 `-constr`），它给出的是**有 buffer 树的世界**：
同一份 RTL 官方 31.77 MHz vs `-constr` 275.86 MHz。**两套数绝不可混用**。

**宿主 yosys 0.68 的 pre-ABC 网表已判不可信**（2026-10-09）：0.68 在 `prepared.json` 上会报
**32 条 `multiple conflicting drivers`**（容器 0.63 报 0 条），且 FF 单元只剩 1990 个（正确值 10242）
⇒ 结构已经变了。**归因必须用容器 0.63 重放**，`tools/preabc.py` 只保留作历史参考。
跨环境比较是 §15.10.11 里花掉一整天才证伪的坑之一。

**已证伪、不许再当成功判据的量**：`ltp`、关键路径**级数**、面积、高扇出网**个数**、
单个网的扇出下降、跨环境比较。这五个里任意一个出现在"成功"栏里，就是把已经证伪的
东西请了回来 —— 实测它们与频率**反相关**。

## 1. 脚本

### `iss.py` —— 最小 RV32IM 模拟器（**功能**侧的第三方黄金参考）

上面那些工具回答"频率卡在哪"，这一个回答"**算错时正确值是多少**"。独立实现一遍 ISA 语义，
与 RTL 零共享代码 ⇒ 整机算错时不必拿 RTL 自己的输出当自己的标尺（那是循环论证）。

```sh
tools/iss.py testcases/correctness_hanoi/program.data   # → # insns=3674 exit=[184] a0=184
tools/iss.py <prog.data> -t                             # 追退休轨迹（每条一行）
```

停机口径与官方一致（MMIO `0x80000000` 的 32 位 store = 退出值）。实战用法与锚点见
`docs/plan.md` §二十四：拿它的**退休指令总数**与 TB 的 `commit=` 对齐、拿**退休轨迹**与
RTL 的提交流逐条比，一次就定位到 hanoi 的第一条错值。

### `preabc.py` —— 生成保留 RTL 名字的 pre-ABC 网表（归因用）

官方 `scripts/synth.py` 跑完 `abc` 之后所有 RTL 名字都没了（只剩 `_NNNNN_`），于是
"关键路径上那个 637 扇出的网到底是哪段 RTL"没法从判分产物里读出来。本脚本用同一套
read/synth 序列在 `abc` 之前把网表写出来，名字还在。

### `census.py` —— 在有名字的网表上数扇出

```sh
tools/census.py <preabc.v>                      # 普查: 负载数最多的信号
tools/census.py <preabc.v> --target '\regs[k]'  # 定点: 该信号的每一条负载点
```

**它是字级（word-level）的**：一个 `[31:0]` 向量被引用一次，计数是 32 而不是 1。
所以 `\regs[k]` 记 96 = 每比特 3 次引用 × 32 位。**它给不出比特精确的门级扇出** ——
要那个数只能读 `mapped.v`（post-ABC，匿名名）或 `timing.rpt`（带 Fanout 列）。见 §2 实测。

### `wvec.py` —— 全设计**宽向量 × 动态访问**普查

```sh
tools/wvec.py /tmp/preabc_base/preabc.json            # 按 A_WIDTH 排序的全表
tools/wvec.py /tmp/preabc_base/preabc.json --min 64   # 只看 A_WIDTH >= 64
tools/wvec.py /tmp/preabc_base/preabc.json --src dcache
```

数据源是 `tools/preabc.py` 的 `preabc.json`：把网表里所有 `$shiftx/$shift`（RTL 里
`v[i +: W]`、`i` 是信号时在网表里的**唯一**物化载体）连 `A_WIDTH`（被索引向量的宽度）、
`Y_WIDTH`（取出的字段宽度 = 该访问的**理论下界**）、`attributes.src`（RTL 位置）一起列出。

**它只覆盖"读"**：动态**写** `v[i +: W] <= d` 不是 `$shiftx`，而是"一条使能 × N×W 个触发器"，
要在 `mapped.v` 上用 `tools/bombs.py` 找。两侧量级差两个数量级（实测：`tag_r` 的读数据位
每位扇出 7，同一条向量的写使能 1202）⇒ **排序键取写侧的使能扇出**。见 `docs/plan.md` §9。

"份数"列 = 该源码行**展开出的 `$shiftx` 个数**（generate/for 会展开），不是模块例化数。

### `path.py` —— 关键路径解剖（**本工具链信息量最大的一个**）

数据源是**官方判分产物自己**：OpenSTA 写的 `timing.rpt` 每行本来就带
`Fanout Cap Slew Delay Time Description` 五列，不需要自己数网表。

```sh
tools/path.py docs/timing/<tag> --top 20 [--netlist <mapped.v>]
```

输出：① 扇出分桶表（级数 / Σ延时 / ps per 级）；② `healthy_ns`（扇出 ≤15 的级之和）
与 `hot_ns`（≥16 的级之和）—— **`healthy_ns` 就是深度地板**，`hot_ns` 是扇出税；
③ 最贵的 N 级 + 负载引脚直方图。

**两个上限必须分清**（混淆过一次）：
- **上限 B**（只消扇出、级数不变）= `healthy_ns + 级数 × 本征单级延时`
- **上限 A**（连热级也拆掉）= `healthy_ns`

300 MHz 的判据是 `级数 ≤ 71 且 每级扇出 ≤ 15`。

### `pathsrc.py` —— 把 `timing.rpt` 的匿名 cell 反查回 RTL 行号（位置对齐 join）

`path.py` 能把路径**解剖**开，但 `timing.rpt` 里的 cell 全叫 `_141944_` 这种匿名名，
回答不了"这条路径是哪两个模块之间的"。

`design.json`（`write_json`）和 `mapped.v`（`write_verilog`）是**同一张 ABC 后网表的两种序列化**：
前者用 `$abc$686060$auto$blifparse.cc:397:parse_blif$686061` 名，后者用合法化后的 `_141944_` 名，
**名字零重叠**，按名字 join 不可能。可行的办法是按**位置** join：

```sh
tools/pathsrc.py runs/<id>/build/synth_<id>/opt [--path N] [--all] [--only-src]
```

`mapped.v` 里第 k 个实例 ↔ `design.json` 里第 k 个 cell ↔ 该 cell 的 `attributes.src`。
脚本**逐个核对两侧的 cell 类型**，有一个不符就退出（顺序假设不成立时绝不出数）。

实测对 `ic1k` 复现：73480/73480 类型全同，最差路径起点 `_141944_` ←
`core/mem_subsystem.v:171.5-179.8`，终点 `_142968_` ← `core/axi_lite_master.v:121.5-131.8`。

**限制（不知道会得出错误结论）**：ABC 自己造的组合门**没有 `src`**，只有触发器还留着
Yosys 从 RTL 继承的 `src`。所以本工具只能回答"**首尾两个时序元件来自哪一行**"，
中间 100 级组合级一律显示 `?` —— 那是"没有 src"，不是"查表失败"。
要归因组合级，用 `MODE=diagnose`（保层次、出 `u_mem/_NNNN_` 限定名）配 `path.py`。

**独立佐证（别只看 src 字符串，行号可能撞车）**：脚本会额外报告"网表里紧挨着同 src 的一整段"。
`ic1k` 起点那段是**恰好 8 个** `DFFASRHQNx1`（= `ld_wr_p` 4 位 + `ld_rd_p` 4 位，
与 `LD_INFLIGHT=8 ⇒ 指针 4 位` 对上，异步复位风格也对上），终点那段是 **1040 个** `DFFHQNx1`。
位宽对得上，才说明归因没认错人。

### `netattr.py` —— 一颗热网的**三步归因**（谁驱动它 / 它驱动谁 / 谁在它附近）

`path.py` 说"哪一级最贵"，`pathsrc.py` 说"起终点是哪段 RTL"，`cone.py --cone` 说"正向锥多大"。
但最贵的网（扇出几百的 ABC 共享字面量）**两头都不是触发器**，缺的正是这三步：

```sh
tools/netattr.py runs/<id>/build/synth_<id>/opt _023593_     # 也可直接给实例名
```

① 驱动实例/类型/输入 —— **给实例名会自动换成它的输出网**：官方 `path.json` 的 `net` 字段填的其实是
**驱动实例名**（`.v` 里是 `TYPE _087201_ (... .Y(_029527_))`），直接拿它去找网会一无所获。
② 反向锥的门数/叶子触发器（按 `src` 分组）—— **判据：锥只有 2~3 门 ⇒ 这颗网就是一条 RTL 直线**
（`_023593_` = 2 门 + 3 个 `sq_ret_p` 触发器，见 `docs/plan.md` §14）；**锥上万门 ⇒ 它只是 ABC 对大云团的
因式分解，没有单条 RTL 对应物**（§15 实测：cut5 最差路径上 17 个热级里 16 个属于后者）。
③ 负载的类型×引脚直方图 —— 负载全是**无 src** 的复合门 ⇒ ABC 自造；引脚集中在某个低有效脚
⇒ 该字面量被折进了与/或项。④ 最近的下游触发器按 `src` 分组（答案可能很多：大云团 8 级内能碰到上千个，
**只能当"附近是谁"读，不能当"终点是谁"**）。

### `census.tcl` —— 路径普查（**推翻"官方产物够用"的那一个**）

官方 `scripts/timing.tcl` 的 `report_checks` **写死 `-group_path_count 5`** ⇒ 归档的
`timing.rpt` 永远只有 5 条路径，**结构上不可能**回答"全设计到底有几条独立的长路径"。
`ic1k` 那 5 条恰好还同属一个 32 位寄存器的相邻位，看它会得出"瓶颈是一条链"的错误结论。

本脚本用**与官方逐条相同的约束**（5 个 liberty + fakeram lib、`create_clock 3.333`、
transition/uncertainty 0.05、input/output delay 0.2/0.0、`set_load 5.0`、`set_case_analysis 0 reset`），
只把 `-group_path_count` 放大。宿主没有 OpenSTA，在容器里跑：

```sh
docker run --rm --cpus=2 -e CENSUS_DIR=<树内 opt 目录> -e CENSUS_N=4000 \
    -v <variation_tree>:/work -w /work cpu2026:local sta /work/census.tcl
```

周期固定取 3.333 ns（=300 MHz 判据）。时序路径延时**与周期无关**（本流程无 time borrowing），
故 `delay = 3.333 − slack`；与官方在 2.0 ns 下报的延时是同一个数（差 0.0726 ns 的常数是
`set_clock_uncertainty 0.05` + 触发器 setup，两边都有，相减即消）。

**把 `CENSUS_N` 开到 ≥ 终点数，得到的就不是 top-N 而是全设计普查**：`find_timing_paths`
默认 `-endpoint_count 1`（每个终点只回最差那条），所以 `CENSUS_N=30000` 在 ic1k 上返回
**8758 条 = 终点总数本身**（脚本第一行 `CENSUS_COUNT` 就是它，与 `N` 不等即说明已穷尽）。
这时"最差延时"的分布能直接回答**全设计有多少终点达不到目标周期**——这是判断
"要不要重划流水"唯一的定量依据，见 `docs/plan.md` §15.10.29。副作用：日志有 8758 行，
别直接 `cat`。

### `cone.py` —— 锥规模 + 逐级模块归因

```sh
tools/cone.py runs/<id>/build/synth_<id>/opt --cone _141944_   # 这个信号驱动了多少东西
tools/cone.py runs/<id>/build/synth_<id>/opt --path 0          # 第 0 条路径逐级"最近寄存器边界"
```

`--cone`：从该 cell 的输出网做正向组合 BFS，到触发器为止，输出组合 cell 总数 +
**到达的触发器按模块的直方图**（模块来自 `pathsrc.py` 的位置对齐 join）。用它才能回答
"这一刀切下去会不会把延时搬到别处"。

`--path`：以**所有触发器**为源做多源正向 BFS，给每个组合 cell 标上
（到最近上游触发器的级数，那些触发器的模块），再把路径逐级打出来。
**限制**：标签取的是**最近**的边界，一个门只要有任一输入来自某模块的触发器就被标成那个模块 ——
它回答"这段逻辑贴着谁的寄存器"，**不**回答"这条路径穿过了谁"。要模块级**确定**归因只能 `MODE=diagnose`。

### `bombs.py` —— 官方流程的"热网 → RTL"归因（**判分产物上直接跑**）

```sh
tools/bombs.py runs/offH/build/synth_offH/opt                # 全设计普查 + top-12 热网归因
tools/bombs.py <dir> --top 20 --depth 3                      # 看更多 / 驱动树更深
tools/bombs.py <dir> --net _038063_                          # 定点一个网 (完整消费者 + 锥)
tools/bombs.py <dir> --skip-cone                             # 只看 ①②, 跳过昂贵的正向锥
```

**为什么需要它**：官方 ABC 脚本（`strash; &get -n; &fraig -x; &put`）**没有** `set_driving_cell` /
`set_load` ⇒ ABC 手里没有负载信息，既不 buffer 也不 upsize，**一个网上挂多少负载就是多少延时**
（单元恒为最小尺寸，延时 ≈ 0.7 × 输入摆率且沿路径单调恶化）。实测 `offH`：31.4746 ns 里
**26.7162 ns（85%）是扇出税**，健康段只有 4.6919 ns / 88 级 @ 53.3 ps。所以"谁在付扇出税"就是全部问题。

`tools/path.py` 只回答"最差那 5 条路径"（官方 `timing.rpt` 写死 `-group_path_count 5`），
看不见"还有几条独立长路径、几个起点"。本工具用**全设计**口径回答 Step 0 的三件事：

1. **全设计扇出直方图 + top-N 热网**（剔除 `clock`/`reset` —— 它们本来就该巨大扇出，混进来会盖住真热点）；
2. **每个热网的消费者族**：消费者除热网外还吃哪些引脚、那些引脚由谁驱动 —— 判定"这是什么结构"
   （写使能 N×W？读口 one-hot？真实触发器广播？）的硬证据；
3. **每个热网的正向锥**：穿过组合门到达的触发器 D 脚，按 `src`（RTL 文件:行）汇总 ——
   回答"这个网一抖，全机多少寄存器跟着抖"。

**归因纪律**（`docs/plan.md` §15.10.31）：**引脚名 / 扇出数 / 比值不可用于归因**；只看
**驱动源 + 低扇出兄弟网 + 位置**三样。真正的数据位往往是热网（被 CSE 合并出的共享中间字面量）的
**低扇出兄弟** —— 所以 `src` 那一列才是证据，引脚直方图只是线索。

**口径**：只读 `mapped.v`（post-ABC，官方判分产物）+ `design.json`（`src` 来自位置对齐 join，
见 `pathsrc.py`）⇒ **这里的数字可以当判据用**，不像宿主 yosys 的 preabc 产物（那个只借名字，
见 §0 里"宿主 0.68 已判不可信"）。本工具不改任何 RTL、不产生任何频率数字。

### `snap.py` —— 把一次综合的产物归档进仓库

```sh
tools/snap.py --artifacts build/synth_<id>/opt --tag <id> --rev <git> --params "..." --ipc "..." \
              [--flow official|constr]
```

只归档小文件（每版约 600 KB），丢弃 `design.json`(73 MB)、`elaborated.json`(30 MB)、
`mapped.v`(13 MB)；`synth.log`(2.3 MB) 里只蒸馏出 `$alu/$macc` 的 RTL 行号归因存成
`alu_sites.txt`。同时往 `docs/timing/results.csv` 追加一行自解释记录 —— 历史最优 f3 的
证据只活在 `/tmp` 里差点丢掉，这个脚本就是为此写的。

**`--flow` 必填项（2026-10-02 加）**：`official` = `scripts/synth.py` 原样的 `abc -D 2000`（**判分口径**）；
`constr` = 再加 `abc.constr`（`set_driving_cell INVx1` + `set_load 5.0` + `buffer/upsize/dnsize/stime`，**本机私有对照**）。
两者 fmax 相差 **8.7 倍**（同 RTL 实测 31.77 vs 275.86 MHz），**混在一张表里必读错**
—— 所以 `results.csv` 有独立的 `flow` 列，不要靠 `note` 里的文字判断。
**报数只用 `official` 行**（§0）。
`path.json` 是 `path.py` 每次归档**重新生成**的，`critical_paths.json`/`report.json` 是官方原产物，
两者都可由 `timing.rpt` 复算；`alu_sites.txt` 例外（源 `synth.log` 不归档，**不可再生**）。

**`params` 列的读法（2026-10-02 统一键名）**：键名已统一为 RTL 的参数名
（`ROB_SIZE`/`RS_SIZE`/`PRF_SIZE`/`LSQ_SIZE`/`BHT_SIZE`/`RAS_SIZE`/`SQ_DEPTH`/`RD_DEPTH`/`WR_DEPTH`；
早期行写的 `ROB`/`RS`/… 已就地改名，**值未动**）。两个例外：
- **`PF_DEPTH` / `PF_WIN`**（5 行，2026-09-29 及更早）是**已退役参数** —— 那是 I-cache 落地之前的
  "取指预取窗口"，`icache.v` 上线后已从 RTL 删除（见 `docs/plan.md` §15.14）。**不要在新实验里用**。
- 未列出的参数一律取 RTL 默认值（`docs/architecture.md`「参数表」）。

### `run.sh` —— 造变体树 + 跑官方容器综合

```sh
tools/run.sh <id> [参数=值 ...]     # 例: tools/run.sh lsq8 LSQ_SIZE=8
tools/run.sh <id> --no-synth       # 只造树不打综合
tools/run.sh <id> --filelist=docs/timing/filelist_ic.f   # 换冻结口径的源文件列表
tools/run.sh <id> --mode=diagnose                        # 保层次网表（归因用，非判分口径）
tools/run.sh <id> --period=6.0                           # 换 ABC 的映射时序目标（见下）
tools/run.sh <id> --constr                               # 官方脚本 + ABC 的 -constr 分支（见下）
```

`--period=<ns>` 改的是 `CLOCK_PERIOD_NS`。它在 `synth.ys` 里以 **ps** 传给 ABC 的 `-D`
（默认 2.0 ns ⇒ `abc -D 2000`），而 OpenSTA 报的最小时钟周期是对产出的网表**重新二分**
测出来的，与这个目标无关。

**在官方（不带 `-constr`）流程里这个旋钮完全无效，不要用它出性能数**（详见 `docs/plan.md` §15.10.28）。
`-D 2000 / 3400 / 6000` 三个点的 `mapped.v` **md5 完全相同**（关键路径延时都是 12.141287 ns）——
`{D}` 在无约束那条 ABC 脚本里只出现在 `&nf {D}`，而三个约束都比实际路径紧，
ABC 收敛到同一个面积最优解。**它现在的用处是"证伪"**：任何"换个参数能不能提频"的猜想，
一次综合 + 一次 `md5` 就能判死。**但带 `-constr` 时 `{D}` 还要喂 `upsize {D}`/`dnsize {D}`，
这个结论不适用**。

> ⚠ **`--period` 不在实验范围内（用户 2026-09-30 裁定）**：助教建议的是"在原有官方脚本基础上
> 增加 `constr`"，**除 `-constr` 外一律用官方参数**。⇒ `CLOCK_PERIOD_NS` 固定在
> `Makefile:22` 的 `?= 2.0`（即 `abc -D 2000`），**不要拿它做扫描**。曾经扫过的
> `--period=1.0/4.0` 两棵树已删除，其数字不作为结论（见 `docs/plan.md` §15.10.33 一）。
> 这个选项保留只是因为它同时是"证伪工具"，以及将来若口径变了可以再启用。

`--constr` 只在变体树内的 `scripts/synth.py` 那一行多传 `-constr /work/abc.constr`
（官方文件不动），并在树里写 `abc.constr`（`set_driving_cell INVx1_ASAP7_75t_R` / `set_load 5.0`），
补丁后 `grep` 自检，打不上直接退出。它与官方的差别是 ABC 会走
**`buffer; upsize {D}; dnsize {D}; stime -p`** 那一支 —— 官方那一支**不插缓冲、不做驱动强度优化**。

**实测（`docs/plan.md` §15.10.32，同样是 HEAD RTL 的单变量对照）：**

| | 最低周期 | fmax | 面积 µm² | 扇出 ≥64 的网 | 缓冲数 | 路径扇出税 |
|---|---:|---:|---:|---:|---:|---:|
| 官方 | 12.1416 ns | 82.36 MHz | 8,184.21 | 349（最大 351） | 0 | 8.0975 ns（67%） |
| `--constr` | **4.0195 ns** | **248.79 MHz** | 8,941.70 | **0**（最大 18） | **12,245** | **0 ns** |

⇒ 扇出税是**流程**造的，不是 RTL 造的；`buffer/upsize/dnsize` 一开，最小周期 ÷3.02。
（判分口径待定，见 §15.10.32 五 —— 与官方口径的数字**分开记，不混用**。）

用 `cp` 而不是 `git archive`：要能测**未提交**的 RTL 改动（改一版测一版是常态）。
参数补丁只改 `student_top.v` 的 `parameter` 默认值，改完**回读校验**，对不上直接退出。

**调用时参数必须逐字写，不要拼进 shell 变量再展开** —— 本机是 **zsh**，`$P` 展开**不做单词拆分**，
`--filelist=...` 会被并进上一个参数的值里；那个值含 `/`，会提前终止参数补丁那条 `sed` 的 `s`
命令（报 `bad flag in substitute command: 't'`），而 `set -e` 让整次运行**静默退出**
（现象：日志只有一行"变体树: ..."，`runs/<id>/build/` 根本没生成）。

### `remote_synth.py` —— 把**官方综合**挪到另一台机器上跑（2026-10-10 加）

```sh
tools/remote_synth.py <ssh主机> <id> [--restart] [run.sh 的参数...]
tools/remote_synth.py pc cutA3              # 推源码 → 远端起 → 观察 → 只捞回小产物
tools/remote_synth.py pc cutA3 --restart    # 远端同 id 的容器先杀掉重跑
```

**为什么要挪**：`make synth` 是**单线程**的，而且 memory-bound —— 2026-10-10 那次把
elaborate 从 5.9 min 拖到 26 min（4.4×）的原因是**宿主 swap 抖动**（6.2/7.2 GB 已用），
不是 CPU 不够。换一台空闲机器即回到 ~7–10 min/次。**判分口径不变**：仍是官方
`scripts/synth.py`、opt 模式、不传 `-constr`。

**同步纪律**：只推 `verilog/ scripts/ tools/ Makefile config.mk`（≈1 MB），
**`runs/` 17 GB 一个字节都不推**；跑完只 rsync 回 `snap.py` 那 8 个小文件 + 两个日志。

**远端机器 = Windows 11 / WSL2（2026-10-10 建成，逐段实测过）**：

- **链路走 Tailscale**（同一账号两端登录），不走局域网：校园网对无线客户端做了隔离
  （两台机器同 /15 网段、ARP 互不可达，见下"踩坑"）。Mac `100.84.90.8` ↔ PC `100.121.142.80`，
  实测经 **DERP(hkg) 中继**、RTT ~130 ms —— 对 ~1 MB/次的同步量无感。
  **PC 上的 VPN 客户端要关掉**（TUN/全局模式抢路由会让 Tailscale 连不上或走不动）。
- Mac 侧 `~/.ssh/config` 已加别名（**免密**已装，脚本用 `ssh -o BatchMode=yes` 探测）：

  ```
  Host pc
      HostName 100.121.142.80
      User aud_xiejiaye
      Port 2222
      ServerAliveInterval 30
  ```

- Windows 侧一条链：`portproxy 2222 → <WSL eth0 的 IP>:22`，`listenaddress` 绑 tailnet 地址
  ⇒ 这个口在校园网里不存在，只有 tailnet 内可达。

**PC 重启后必做（三条命令）**：

```powershell
wsl -d Ubuntu -u root -e true     # 叫醒 WSL; systemd 会带起 sshd + docker (两者实测均 enabled)
wsl hostname -I                   # 取 eth0 的 IP —— 不是 172.17.0.1, 那是 docker0 网桥
# 若 IP 与上次不同（管理员 PowerShell）：
netsh interface portproxy delete v4tov4 listenaddress=100.121.142.80 listenport=2222
netsh interface portproxy add v4tov4 listenaddress=100.121.142.80 listenport=2222 connectaddress=<新IP> connectport=22
```

**镜像必须现构**（本机那份是 arm64，搬到 x86-64 只能 qemu 模拟）。Hub 在 PC 上也不可达
⇒ 镜像站拉基础镜像后打官方 tag（**不要改 daemon 级 registry-mirror**）：

```sh
docker pull docker.m.daocloud.io/library/ubuntu:24.04
docker tag  docker.m.daocloud.io/library/ubuntu:24.04 ubuntu:24.04
docker pull docker.m.daocloud.io/docker/dockerfile:1
docker tag  docker.m.daocloud.io/docker/dockerfile:1 docker/dockerfile:1   # BuildKit 前端备用
```

Docker 29.1.3 经典 builder **仍可用**（`DOCKER_BUILDKIT=0`，Dockerfile 首行 `# syntax=` 按注释忽略）；
WSL 只有宿主一半内存（本机 7 GB）⇒ 必须 `--build-arg BUILD_JOBS=4`，否则 `-j8` 编译 Yosys 会被 OOM 杀。

★ **PC 直连 GitHub 不通**（2026-10-10 实测：DNS 正常，TCP 443 连不上；`git fetch` 主仓偶尔能过、
子模块必挂）⇒ **借本机的通路**：本机跑一个 CONNECT 代理，构建时用 docker 的预定义代理 build-arg
（**不用改 Dockerfile**，也**不会**烤进镜像 config —— 实测 `.Config.Env` 干净）：

```sh
# ① 本机（Mac）起代理 —— 只监听 tailnet 地址, 没鉴权, 用完就关
python3 tools/github_proxy.py            # 默认 100.84.90.8:8899
# ② 本机验证通路
curl -sS -x http://100.84.90.8:8899 -o /dev/null -w '%{http_code}\n' https://github.com/
# ③ 推官方框架仓库 + 远端后台构建
rsync -az --exclude .git /Users/audience/opt/cpu2026-fw/ pc:~/cpu2026-fw/
ssh pc 'cd ~/cpu2026-fw && setsid nohup env DOCKER_BUILDKIT=0 docker build \
        --build-arg BUILD_JOBS=4 \
        --build-arg HTTPS_PROXY=http://100.84.90.8:8899 --build-arg https_proxy=http://100.84.90.8:8899 \
        -t cpu2026:local . > build.log 2>&1 < /dev/null &'
ssh pc 'docker run --rm cpu2026:local cat /opt/versions.txt'   # 与本机逐行相同才算可比
```

**踩坑**：`docker build` 的**构建上下文不能放在 `/tmp`**（WSL 里有 root 属主的 `/tmp/snap-private-tmp`，
经典 builder 遍历上下文时报 `can't stat` 直接失败）；`git ls-remote` 走镜像站（如
`https://ghfast.top/https://github.com/...`）能通，但**子模块取不到确定内容**，所以正式构建走上面的代理。

★ **ASAP7 那一步打了本地补丁**（2026-10-10）：官方 Dockerfile 从 `raw.githubusercontent.com` 取 ASAP7 r28
的 5 个 `.7z` + LICENSE，而该域**两台机器都时通时断**（TCP 连得上、几十秒收不到一个字节 ⇒ `curl: (56)`，
代理也救不了 —— Mac 自己也连不上）⇒ 本地把这一步换成 `COPY asap7/`，字节取自**既有的官方镜像**
（`docker cp <容器>:/opt/asap7`），原版留档 `Dockerfile.official`。`~/opt/cpu2026-fw/{Dockerfile,asap7/}`
在**本机与 PC 是同一份**（rsync 推过去），**别再单独改 PC 那份**。内容是不是同一份由 SHA256SUMS 对账：

```sh
ssh pc 'docker run --rm cpu2026:local cat /opt/asap7/SHA256SUMS'   # 与本机 docker run 同一命令逐行相同
```

三个 pin（Yosys `70a11c6bf` / ASAP7 **r28** `f970bd3c` / OpenSTA `f89887b5`）与架构无关，
x86-64 原生构建出来是同一套版本 ⇒ 数字与本机历史可比；宿主那套 ASAP7 是 **r27**，两边绝不可混。

**首次真跑 = 验收（已通过，2026-10-10）**：`tools/remote_synth.py pc xcheck` 在**本机同一份源码**上复现 cutD，
不止频率 —— min_period **6.287109375 ns** / fmax **159.0556 MHz** / 面积 **9249.919425 µm²** / 时序面积
2893.05108 / slack −4.287069，与本机 arm64 归档（6.2871 / 159.06 / 9249.919 / 2893.051 / −4.2871）**逐位相同**
（顺带复核 A2 已回滚）⇒ x86-64 原生构建与本机历史数字可比。一次完整跑 **18 min**（elaborate 4.9 / synth 13.3）。
**之后官方综合一律走远端，本机只做仿真**；`xcheck` 是复现，不单独进 `results.csv`。

**已验证 / 未验证**（2026-10-10）：Tailscale 链路、`ssh pc` 免密、portproxy 链、镜像站拉取、经典 builder、
**Mac 代理借道**（PC 经代理取 GitHub 200 / 1.5 s；浅克隆 `abc` 60 MB < 30 s）、**镜像构建 + `versions.txt`
与 `SHA256SUMS` 逐字节对账**、**一次完整远端综合并复现本机数字**、**启动链修好后的端到端起跑**
（见下"踩坑"）—— 全部实测通过。未验证的只剩「`--restart` 重跑」与「产物回传后 `snap.py` 归档」两条分支
（回传本身已跑通）。

**端到端的起跑怎么测**：不必烧一次 18 min 的综合 —— 传一个坏的 `FILELIST` 让它快速失败即可
（`tools/remote_synth.py pc launchtest FILELIST=verilog/nonexistent.f`），一次走完 rsync → 起跑 → 观察 →
"流程退出"判定。注意 **`FILELIST` 里有 `/` 会踩 `run.sh` 里 `sed s///` 的转义**（用别的坏法，别用带斜杠的路径）。
另外：容器若在两次轮询之间起落，"见过容器"标志不会被置上，要等满 300 s 兜底才报退出 —— 慢但正确。

**踩坑**：`remote_synth.py` 起综合那步曾用 `cd X && setsid nohup bash tools/run.sh … & echo started` ——
`&&` 让整串成为 **AND-list**，bash 必须 fork 子 shell 去跑，而子 shell 的 stdout 还是 ssh 的管道、又要等
`run.sh` 结束才退 ⇒ **ssh 永不返回**（表现为 `subprocess.TimeoutExpired` 180 s，但远端其实已经在跑了）。
修法是给背景那截加花括号：`cd X && { setsid … & }; echo started`（背景的是**简单命令**，子进程直接 exec，
管道随即关闭，ssh ~2 s 返回）。**这个坑的代价可恢复**：脚本死了不用管远端，原样重跑即可 ——
`find_alive()` 会按挂载点 `/runs/<id>` 认领正在跑的容器，走"直接观察"分支接着看并回传产物。

`tools/run.sh` 的 `sed -i ''` 已改成 `sed -i.bak`（BSD/GNU 通吃）—— 原来那写法在远端 Linux 上
会把 `''` 当文件名。补丁后一律 `rm -f *.bak`，不会把 `.bak` 带进变体树。

### `github_proxy.py` —— 本机当 CONNECT 代理，给连不上 GitHub 的机器借道

```sh
python3 tools/github_proxy.py [绑定地址=100.84.90.8] [端口=8899]
```

只实现 CONNECT（git / curl 的 https 都走它）、只放行 443/80、**只绑 Tailscale 地址**（校园网内看不见）、
没有鉴权 ⇒ **构建期间才开，用完就关**。用途与完整配方见上面 `remote_synth.py` 的"PC 直连 GitHub 不通"一节
（docker 的预定义代理 build-arg，不用改 Dockerfile）。

### `sweep.sh` —— 参数消融（**只量 IPC**）

```sh
tools/sweep.sh <id> <标签> "K=V[,K=V...]" [<标签2> "K=V,..." ...]
tools/sweep.sh sw rs8 "RS_SIZE=8" rs4 "RS_SIZE=4"     # 一个实例里逐点串行
SWEEP_TEST=1 tools/sweep.sh sw base ""                # 同一棵树里再跑官方 correctness 全集
```

面积/频率**必须**走 `run.sh`（容器官方流程）；本脚本只在宿主重建 + `make perf`，跑出来的
只有 IPC。三个执行契约：

- **并行**：临时日志带 `$ID` 前缀（`/tmp/sweep_${ID}_*.log`）⇒ **不同 id 的多个实例可同时跑**
  （各写各的树、各读各的日志）。同一个 id 只能有一个实例。固定日志名时代曾让 TIMEOUT/UNOPTFLAT
  判定读到**别人**的输出 —— 一个点的结论会张冠李戴。
- **spec 要写全**：同一实例内参数**跨标签累积**（`patch` 只改列出的项，其余保留上一标签的值）
  ⇒ 每次比较都要把该机器用到的**全部非默认参数**列出来，否则测出来的是"上一标签 + 本标签"的混合体。
- **有效性看 GEOMEAN 行**：`perf` 的 `execute()` 内置 `compare_output` ⇒ **6/6 退出值全对**
  才会打印 `GEOMEAN`；任一用例算错会 `SystemExit`，表就残缺。所以"有 6 行 + GEOMEAN"= 该点
  既有效又正确，`sweep.sh` 打印的那串 IPC 才有意义。卡死点打 `TIMEOUT`、组合环点打 `UNOPTFLAT`，
  两者都**留在输出里**不静默丢弃。

`perf/test` 都带 `SIM="$TREE/build/sim"` ⇒ 跳过 `Makefile` 的 `perf: build` 依赖，省掉一次
**冗余的 verilator 重跑**（实测每点半分钟量级）。代价：改完 RTL 必须先让本脚本自己 `build`
（它每次都 `rm -rf` 重取 `verilog/`，所以天然满足）。

⚠ 见 §2.4：TB 侧参数是各自复制的，本脚本**不**同步它们 ⇒ 扫出来的变体不覆盖
`make -f Makefile.tb` 门控，别拿单元 TB 当变体的正确性证据。

### `vcd_bubble.py` —— 官方口径逐拍气泡归因（**单点深挖，不做消融**）

```sh
make CONFIG=config.local.mk build          # 二进制必须比 verilog/ 新, 否则数的是旧 RTL
D=testcases/perf_qsort
./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.vcd
tools/vcd_bubble.py /tmp/w.vcd [ROB_SIZE] && rm -f /tmp/w.vcd
```

- **第二个参数是生成该波形的 `ROB_SIZE`（默认 16 = `c2`）**：「ROB 空」的判据是
  `rob_free == ROB_SIZE`，写死会在放大 ROB 的变体上把"在飞若干条"误判成空 ⇒ **跑非 `c2` 波形必须显式给**
  （`stack`/`dc2k_c3` 用 32）。变体侧数据表见 `plan.md` §31.5。

- **为什么用官方二进制的波形**：波形模式（`argc==6`，非 OJ）跑的是 **`scripts/sim.cpp` 本体**
  —— 与 `make perf` 同一个存储模型、同一套周期语义 ⇒ 归因**不需要**第二套行为级从机,
  周期数与 `make perf` 逐位相同（自校验见 `plan.md` §30.1：探针 `cyc` 恒 = 官方 − 16）。
- **分区按提交侧**（`set_head_valid` + ROB head 的 ready/opcode），不是派发侧 `issue_en`：
  单发射下 RS 满挡住派发的那一拍 RS 仍在出货 ⇒ 派发侧口径会把 RS 满整片记成气泡（§30.4）。
  ⚠ 但"RS 满不是直接气泡"**推不出**"RS 容量无收益"—— 大 RS 提前发射 load 缩短内存墙的收益
  落在 `head=load 等存储` 里，本分区看不见（§30.4 订正；`rs8` 实测 rsort +6.4%）。
- 波形 **≈8 KB/拍**（qsort 1.9 GB / rsort 2.5 GB）。脚本按行**流式**读、只留当前值 ⇒
  内存恒定；不要改成"把每次变化存进列表"（那版在 247k 拍上被 OOM 杀过）。
- 同一份波形可反复扫（改脚本重扫即可），所以**先存波形、再调归因**比反复跑仿真便宜。
- 输出示例与六程序数据表见 `docs/plan.md` §30.2。

### `vcd_mem.py` —— 访存并发度 + D-cache 组占用（**看结构，不看气泡**）

```sh
D=testcases/perf_rsort
./build/sim $D/program.data $(cat $D/expected.txt) 100000000 10 /tmp/w.vcd
tools/vcd_mem.py /tmp/w.vcd        # 同 vcd_bubble 的波形，可比 vcd_bubble 省一次仿真
```

- 回答两件事：**① 全机同时有几笔 D 需求缺失在飞**（`ld_occ_w` 均值/直方图，及"需求缺失撞上填充引擎忙"
  的比例）；**② D-cache 的组满不满、install 时受害路有效（真冲突驱逐）的比例**。
- 采样本应与 `vcd_bubble.py` 一致（偶数 `#t`、`rst_n && !halt`），便于逐位对账。两条**自校验**：
  - **逐拍断言** `ld_occ_w == ld_wr_p - ld_rd_p + dc_ms_fire_w`（`mem_subsystem.v:231`）。不符即口径错，
    脚本照常打印但**结论作废**（实测六程序 0 拍不符）。
  - `cyc` 必须 = 官方 `make perf` 周期 − 16；推送数 == 回包数 == `ld_wr_p` 终值。
- **`lm_flight` 的复算恒 ≥ `vcd_bubble.py` 的数（多 0~15 拍）**，不是逐位相等：后者把 `commit` / `flush`
  拍先行分类、不计入该桶（六程序实测差 +0/+2/+4/+15）⇒ 两个工具对账看趋势，不看相等。
- **起填来源必须在"起填那拍"锁存**（`fill_start_w` 上升沿 + 三个互斥理由取优先级），不能在 install
  那拍采 —— 踩过：在 install 拍采 `dpf_start_w` ⇒ vvadd 报"预取 0%"，而它全机只有 2 笔需求缺失
  （正确值 152/155）。位序：`valid_r` 的第 `way*DC_SETS + set` 位；install = `vset_w`。
- 波形同样 ≈8~10 KB/拍（qsort 2.0 GB / rsort 2.6 GB）；流式读，内存恒定。
- 输出示例与六程序数据表见 `docs/plan.md` §6.2。
- **[§40] 扩展的 `[S3=§40.V3]` 两行（命中交付路径）**：
  - `hit_valid` 上升沿 = **命中交付笔数**（`dcache.v:362`，含填充旁路）；`重放` = `lk_replay_r` 上升沿，
    分母就是它。⚠ 同段的 `hit_raw_w 为高的拍数` **不是笔数**（每笔命中可连续为高 2 拍，实测 vvadd
    597 笔 / 1198 拍）—— 该行原写「笔」是单位笔误，[§40] 已订正（缺失率那个百分比不受影响，分子分母同口径）。
  - `段内有查表重放` 直方图用来**验证因果**：towers 的 183 个 3 拍段全部含重放、97 个 1 拍段全部不含
    （qsort/rsort 同构、零例外）⇒ "命中 3 拍 = 1 拍 + 重放"成立，不是猜的。

### `vcd_prefetch.py` —— 预取选择性（**每行被驱逐前被消费了几次**）

```sh
tools/vcd_prefetch.py /tmp/w.vcd        # 波形同 vcd_bubble / vcd_mem, 可复用
```

- 按 (set, way) 建**影子**逐拍对齐 RTL：驱逐 = `fill_start_w` 上升沿（受害路**此刻**就被清无效，
  `dcache.v:765`，不是安装时换），install = `vset_w`（装进 `fill_set_r/fill_way_r`，来源继承**起填那拍**
  锁存的理由）；消费 = load 命中 + store 命中（`st_absorb`，**不是** `any_st_hit_w`，后者是组合电平）
  + 填充旁路（记在正在填的那行上）。
- **自校验 P9**：影子 valid 位图 == RTL `valid_r`、有效处 tag == RTL `tag_r`，**逐拍**（事件延迟一拍施加
  再比）。六程序 0 拍不符。另计"同 tag 排它清除"次数（`dcache.v:781`，按归纳法恒 0）作哨兵。
- ⚠ **口径不对称，读结论时必须记住**：需求缺失的数据走 AXI 回包交付、**不算命中** ⇒ 需求行的消费计数
  从 0 起算，它的第一次使用不计入。跨来源只看**趋势**，不要当比率读。
- 输出示例与六程序数据表见 `docs/plan.md` §7.2（V1）。

### `vcd_branch.py` —— 分支预测器算法评估（**离线重放同一 trace**）

```sh
tools/vcd_branch.py /tmp/w.vcd
```

- 从波形抽 (pc, 实际方向) 动态序列（执行级 `u_slot.upd_req` 口，逐拍记录、不做边沿检测 —— 那就是 BHT
  写口看到的序列），喂给 `2-bit@N` / gshare-h / 两个 oracle，比误预测数。
- **自校验 P10**：① 离线复刻的 `2-bit@BHT_SIZE` 计数器与 RTL `counters` 快照**逐拍**相等（延迟一拍）；
  ② 误预测数 == 波形里的**条件分支**误预测数。**口径坑**：RTL 的 `misp_det` = 条件分支方向错
  **∪ JALR 目标错**（`execute_slot.v:365-366`）⇒ 必须用 `upd_req` 分出条件分支子集再比（同源寄存
  bundle、零偏斜）。首轮不拆时 vvadd 报 5 vs 6（16.7%），拆开后六程序差 0.0%。
- "**无历史**上界" = 按 PC 多数派；它不是全家族上界（median 上被 gshare-10 超过）。
  "(pc,ghr) 多数派" = **历史类家族的不可达天花板**（两遍、用将来信息）—— 判"换预测器"值不值得，
  看这个数就够。
- 输出示例与六程序数据表见 `docs/plan.md` §7.2（V2）。

## 2. 踩过的坑（每条都真栽过）

1. **`design.json` 是 73 MB 的命名空间陷阱。** 它用 `$abc$…$` 命名，与 `mapped.v` 的
   `_NNNNN_` **零交集**（`_010072_` 在 `mapped.v` 出现 484 次、在 `design.json` 出现 0 次）。
   任何 join 只能走 `mapped.v`。
2. **post-ABC 与 pre-ABC 的单元名不是同一套。** `_NNNNN_` 是 `synth -flatten` 时新生的一次
   全新顺序重编号（DFF 恰好落在一段连续区间），不要假设同名可继承。
3. **`MAX_CYCLES` 必须显式传 `100000000`。** 官方默认 `1e6` 会自己制造 7 个假失败；
   容器里看不到 `config.local.mk`，更容易忘。
4. **TB 参数是各自复制的**（`tb_cpu_prog.v` 的 `*_SIZE_TB`、`tb_cpu_top.v` 硬编码 `TPW=6`）。
   只改 `student_top.v` 的参数会让 `make -f Makefile.tb` 门控变成**空测**（测的还是默认参数）
   ⇒ 参数扫描行要么同步 render TB 侧参数，要么**明确声明该门控不覆盖该变体**。
   **同理：§二十七 把基准参数改成 `c2` 也只动了 `student_top.v`** ⇒ 本地 TB 与 §二十五 的
   探针数字仍是**全参口径**，拿它们与基准比较前先确认口径（要么同步 TB 侧参数，要么只用同一口径内的对照）。
5. **`census.py` 是字级的**（见 §1），拿它算比特扇出会系统性放大 `W` 倍。
6. **一次容器综合 ≈ 20 min**，6 点扫描 ≈ 75 min ⇒ 先跑信息量最大的那一版。
7. **残留容器会 100% 烧 CPU 数小时**：容器里的 `make` 被终止后 `docker` 进程不一定退出
   （实测有一个跑了 5 小时、`SYNTH_OUT=build/synth_f3ctl`）。每轮结束 `docker ps` 核一遍。
8. **`timeout` 在 macOS 上没有**（`command not found`）。
9. **`run.sh <id>` 不带参数 = `student_top.v` 的当前默认值**（2026-10-02 起 = 基准 `c2`：
   `ROB=16/RS=4/LSQ=8/BHT=8/RAS=4/IC=512/DC=1024/LD=4/SQ=4/WR=4`；此前自 `8998ca2` 起是
   `ROB=32/RS=16/BHT=32/SQ=8/WR=8`）。跑"与归档行对比"的实验时**必须把参数补上**，
   否则综合出来的是另一台机器（面积差 41%、周期差 30%，看起来像改动引起的，其实不是）。
   同理，`make perf`（在仓库根跑）用的也是提交默认值 —— 要测归档行的配置，就用
   `run.sh <id> --no-synth` 造树（它会把参数补丁写进 `student_top.v`），再
   `make -C runs/<id> CONFIG=<绝对路径>/config.local.mk TESTCASES=<绝对路径>/testcases FILELIST=verilog/filelist.f perf`。
10. ~~**`results.csv` 的 `ipc6` 列与 `params` 列可能不对应。**~~ **（2026-09-30 结案）**
    `ic1k` 行记的是 ROB=16 的面积/频率，但它那串 `ipc6` 经逐位复现是 **ROB=32** 配置的数字；
    `constr1` 行（RTL 与 `ic1k` 逐字相同）继承了这个错值。两行已改正为 ROB=16 的实测
    `0.3797,0.6537,0.3071,0.3830,0.3512,0.4932`（geo 0.4143，`runs/ipc_base16` 复认，
    `base16syn`/`abc6`/`abc34` 三行既有值逐位一致）。全表 27 行逐列复核过，**这是唯一一处**
    参数/`ipc6` 不同源的行。教训（仍适用）：`snap.py` 的 `--ipc` 是**手抄**进去的，不校验机器；
    凡拿归档行的 `ipc6` 做对照，先确认它那棵树是哪套参数。`c1s1` 行补测时按此规矩单独造树复量。
11. **源文件列表一律用官方 `verilog/filelist.f`**（`run.sh` 的默认已改成它）。
    `core/memory.v` 在列表里但没被 `student_top` 例化，`hierarchy -top student_top` 会剪掉
    ⇒ 与去掉它的列表出同一份网表（`stat.json` 模块数=1 已证）。
    **`docs/timing/filelist_t4tmp.f` / `filelist_ic.f` 都是过期冻结列表**：前者不含
    `icache/dcache/mem_subsystem`，拿它综合会在 elaborate 阶段直接报
    `unsupported external module dcache`（2026-10-02 踩过一次）。
12. **官方 `timing.rpt` 只有 5 条路径，这不是巧合是写死的。** `scripts/timing.tcl` 里
   `report_checks ... -group_path_count 5` 是**官方框架文件，勿改**，所以判分产物
   **永远**只有 5 条。任何"设计里有几条长路径"的问题都必须外挂 `tools/census.tcl` 回答；
   拿 5 条路径去推断全局，会得出"瓶颈是一条链、切一刀就好"的错误结论（实测恰好相反，见 §3）。
13. **`pathsrc.py` 的 `?` 不等于"查不到"，`cone.py` 的 `?（无 src）` 是一批**确定的**寄存器。**
   全设计 8315 个触发器里 **5963 个有 `src`、2352 个没有**（28.3%）。这 2352 个
   全是 `$auto$ff.cc:337:slice`（Yosys 生成），在 `mapped.v` 里恰好是**两个连续块**：
   **2048** = `PRF_SIZE(64) × 32` = `prf.v:18` 的 `reg [31:0] regs [0:63]`，
   **304** = `LD_INFLIGHT(8) × (32 + 2 + 4)` = `mem_subsystem.v:156-158` 的
   `ld_addr_r`/`ld_width_r`/`ld_idx_r`。
   机制：这两处都是**变址切片写**（`regs[preg] <= …` / `ld_addr_r[p*32 +: 32] <= …`），
   Yosys 推不出整字 `$dff`，只能建"逐位 `$dff` + 译码器"，这些新单元不带 `src`。
   ⇒ 它们不是漏查，是**数组寄存器**；要按模块归因只能 `MODE=diagnose`。

14. **复用旧 `runs/<id>` 会踩两种陈旧（2026-10-02 实栽）。** `sweep.sh` 原来只在树**不存在**时
   拷贝 `testcases/`＋框架文件 ⇒ ①拿到 `run.sh` 造的树（**不拷 testcases**）时，`make perf` 直接
   `no perf_* testcases` 死掉、打印一行没有数字的 `SWEEP <label>`；②拿到几天前的扫描树时，
   `scripts/build.py`/`testcase.py` 是**旧版**（实测 `runs/w2` 是 09-28 的），而它们的行为直接进 IPC。
   两者都是**静默**的（RTL 每次 `rm -rf` 重取，所以"看起来是新的"）。现已改为：框架文件每次覆盖、
   `testcases/`＋`config.local.mk` 各自按存在性补齐。**判读口径**：`SWEEP <label>` 后面没有 6 个数字
   就是无效点，必须查 `/tmp/sweep_${ID}_perf.log` 的末尾，不能当成"跑过了"。

## 3. 已被这套工具确诊的机制（当作"该怎么用"的例子）

- **HEAD 参数下**：关键路径 94 级 / 17.90 ns，其中**两级吃掉 46%** ——
  `AOI21xp33` 驱动 **637 扇出**网（4066 ps）+ 下一级 `NAND2xp33` 驱动 148 扇出网
  （4100 ps，被**输入摆率**主导）。`path.py --loads` 把 637 逐级追回去，落到
  `lsq.v` 的 `merge_byte_f`：它被**例化 4 次**，每次把整个 544 位 `addr_r/data_r/width_r`
   传进去做 16 次**串行**扫描 ⇒ ABC 的 CSE 把它抽成一个 49 级深、扇出 637 的共享节点。
- **`lsq-tree` 负结果（37.43 ns）的根因**：改写时把 30 位归约 `~|hx[31:2]` 落在了
  **(字节道 × 条目) = 64 份**的叶子里 ⇒ ABC 抽出**扇出 2631** 的共享节点，整版退化 2 倍。
  教训：**宽比较必须提到条目级（16 份），不许按叶子复制**。
- **min-all 参数（全最小）**：6.61 ns / 151 MHz / 4744.77 µm²，**零 RTL 改动**，
  频率 2.7× / 面积 2.4×。但热点性质变了：top 网 `_00107_` 的**反向锥只有 1 个单元、逻辑深度 0**
  —— 它是一个**裸状态位**（DFF 输出）广播给 99 个负载，与 HEAD 的"ABC CSE 深锥"是**两种不同的病**。
- **算术算子归因**（`$alu/$macc` 计数，官方 `synth.log` 免费给）：lsq.v 39% / mem_subsystem.v 23%
  是最集中的两处；但**这是算术复杂度（面积）指标，不是频率预测器** —— 用 `path.py` 定频。
- **单条件写大数组 ⇒ CSE 共享使能（wb1 确诊）**：`rs.v:237` 把 RS 的 14 个字段 + `valid_r` 写在
  **同一个** `if (push_valid && pvalid_w)` 下，ABC 就把它抽成一个字面量，扇出 = 全部负载位宽
  （实测 **1023**，对应 16 槽 × 68 位 = 1088 位）。识别特征：热网的负载直方图里
  **同一个引脚（如 `AO21x1.A1`）出现几百次**，且这些门的 `.A2` 是**等分**的几十组
  （每组 = 一个槽）—— 那就是"一条写使能 × N 个槽"。
- **共享与否会随无关改动翻转**：同一份 RS 使能逻辑，pipe1 里**没有**被共享（热网是 XNOR 驱动、
  `AO21` 负载 0 个），插了 W 级之后就被共享了。**所以"这个网在上一版不存在"不能证明是新逻辑引入的** ——
  必须比对目的触发器的 ID 是否原样存在（wb1 里 884/884 都在 pipe1 中）。
- **深锥输出驱动大负载 = 双重惩罚**：`_144092_/Y` 到达时刻已累计 16.22 ns（slew 10.87），
  自己还有 5.40 ns 的负载延时，下一级 `NAND3` 再 +8.56 ns。判热点时要看
  **到达时刻 × 扇出**，只看扇出会漏掉"早期大扇出无害"的情况。
- **`ic1k` 的病是"一个锥"，不是"一条链"（census + cone 联合确诊）。**
  4000 条最差路径（12.1413 → 9.1638 ns，中位 10.4714）**起点全是同一个** `_141944_/QN`
  （`mem_subsystem.v:171.5-179.8`，`ld_wr_p`/`ld_rd_p` 指针），终点 4000 个互不相同，
  **4000/4000 都超过 3.333 ns**。该 bit 的正向组合锥 = **40850 个组合 cell（≈63% 的组合逻辑）**、
  到达 **6185 个触发器**（rob 980 / mem_subsystem 593 / rs 572 / axi_lite_master 532 /
  lsq 312 / execute_slot 239 / div 201 / rat 186 / fetch 164 / … / 无 src 2320）。
  与 OpenSTA 独立的终点普查交叉验证一致（rob 989/mem 589/axi 532/lsq 312/rat 186/fetch 164）。
  ⇒ **"挪一段寄存器"只会把延时从一批终点搬到另一批终点，是零和的** —— 这就是
  §15.10.26 那一刀（切 LSQ 发请求回环）实测全面退化的机制解释：起点没变（`_141838_` 同 src），
  只是终点换了。**下一刀必须是多级重划分，不能再是点切。**
  **把 `CENSUS_N` 开到 30000 后拿到全设计普查（8758 条 = 终点总数），结论更硬也更可执行**：
  设计是**严格双峰**的 —— 6191 个终点（70.7%）吊在 `_141944_` 上（6.0695–12.1413 ns），
  另外 2567 个终点（29.3%）来自 110 个起点、最差只有 **2.6416 ns**（已经满足 300 MHz），
  中间 `[3, 6) ns` **一条都没有**。⇒ 要动的只是这个锥（62.7% 的组合逻辑），
  但那 6191 个终点是**互不相同的终点**，必须同时压下来。见 `docs/plan.md` §15.10.29。
  另：`_141938_/QN`（execute_slot）看着像第二大起点（740 个终点），但它最差 2.6416 ns，
  **不是问题** —— 这正是"只取 top-N 会误判"的实例。
- **逐级模块归因（`cone.py --path 0`，100 级 / 12.0709 ns）**：级 0-4 mem_subsystem（1.4280 ns）
  → 级 5-53 **lsq（5.2956 ns）** → 级 55-77 execute_slot（1.3454 ns）→ 级 80-96
  **lsq 又一段（2.7459 ns）** → 级 97-99 icache/axi_lite_master（0.1392 ns）。
  lsq 两段合计 **8.0415 ns = 全路径的 67%**。最贵的两级都在 lsq：
  级 89 `XNOR2xp5` 扇出 279（**0.9504 ns**）+ 级 90 `NAND2xp33` 扇出 130（**1.2470 ns**）
  = 2.1974 ns = **18.2%**，与 §3 第一条的 `merge_byte_f` CSE 共享节点同源。

## 4. 资源纪律

容器 **3.89 GiB / 6 vCPU** ⇒ 并发上限 **2 容器 + 1 宿主任务**。
`make test`（`pi` 一条就 183 s）**不与两个容器同时跑**。
