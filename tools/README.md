# tools/ —— 频率归因工具链（**非官方**，不参与判分）

官方框架（`Makefile` / `Makefile.tb` / `scripts/` / `config.mk` / `verilog/filelist.f`）一律不动。
本目录只解决一个问题：**把"频率卡在哪"从猜测变成算术**。

## 0. 口径纪律（先读这条，否则后面所有数字都会骗人）

| 用途 | 唯一可信来源 |
|---|---|
| 频率 / 面积（**判分数**） | 容器 `cpu2026:local`（yosys 0.63 + ASAP7 **r28**）跑官方 `make synth` |
| RTL 名字归因（哪个信号、哪段 RTL） | 宿主 yosys 0.68 + ASAP7 **r27** 的 pre-ABC 网表 |

两套环境**不同源，数字绝不可混用**。宿主产物只能回答"这个网叫什么"，
不能回答"它多快"。跨环境比较是 §15.10.11 里花掉一整天才证伪的坑之一。

**已证伪、不许再当成功判据的量**：`ltp`、关键路径**级数**、面积、高扇出网**个数**、
单个网的扇出下降、跨环境比较。这五个里任意一个出现在"成功"栏里，就是把已经证伪的
东西请了回来 —— 实测它们与频率**反相关**。

## 1. 脚本

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

### `snap.py` —— 把一次综合的产物归档进仓库

```sh
tools/snap.py --artifacts build/synth_<id>/opt --tag <id> --rev <git> --params "..." --ipc "..."
```

只归档小文件（每版约 600 KB），丢弃 `design.json`(73 MB)、`elaborated.json`(30 MB)、
`mapped.v`(13 MB)；`synth.log`(2.3 MB) 里只蒸馏出 `$alu/$macc` 的 RTL 行号归因存成
`alu_sites.txt`。同时往 `docs/timing/results.csv` 追加一行自解释记录 —— 历史最优 f3 的
证据只活在 `/tmp` 里差点丢掉，这个脚本就是为此写的。

### `run.sh` —— 造变体树 + 跑官方容器综合

```sh
tools/run.sh <id> [参数=值 ...]     # 例: tools/run.sh lsq8 LSQ_SIZE=8
tools/run.sh <id> --no-synth       # 只造树不打综合
```

用 `cp` 而不是 `git archive`：要能测**未提交**的 RTL 改动（改一版测一版是常态）。
参数补丁只改 `student_top.v` 的 `parameter` 默认值，改完**回读校验**，对不上直接退出。

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
5. **`census.py` 是字级的**（见 §1），拿它算比特扇出会系统性放大 `W` 倍。
6. **一次容器综合 ≈ 20 min**，6 点扫描 ≈ 75 min ⇒ 先跑信息量最大的那一版。
7. **残留容器会 100% 烧 CPU 数小时**：容器里的 `make` 被终止后 `docker` 进程不一定退出
   （实测有一个跑了 5 小时、`SYNTH_OUT=build/synth_f3ctl`）。每轮结束 `docker ps` 核一遍。
8. **`timeout` 在 macOS 上没有**（`command not found`）。
9. **`run.sh <id>` 不带参数 = 提交默认值 `ROB=32/RS=16/BHT=32/SQ=8/WR=8`，不是 `ic1k` 那台机器。**
   `ic1k`/`t1d`/`hd16` 等归档行都是 ROB=16，由 `run.sh` 的**参数补丁**生成；`student_top.v` 的
   提交默认值自 `8998ca2` 起一直是 ROB=32。跑"与归档基线对比"的实验时**必须把参数补上**，
   否则综合出来的是另一台机器（面积差 41%、周期差 30%，看起来像改动引起的，其实不是）。
   同理，`make perf`（在仓库根跑）用的也是提交默认值 —— 要测归档行的配置，就用
   `run.sh <id> --no-synth` 造树（它会把参数补丁写进 `student_top.v`），再
   `make -C runs/<id> CONFIG=<绝对路径>/config.local.mk TESTCASES=<绝对路径>/testcases FILELIST=verilog/filelist_ic.f perf`。
10. **`results.csv` 的 `ipc6` 列与 `params` 列可能不对应。** `ic1k` 行记的是 ROB=16 的面积/频率，
   但它那串 `ipc6` 经逐位复现是 **ROB=32** 配置的数字。据 `ipc6` 做结论前先确认它测的是哪台机器。
11. **`docs/timing/filelist_t4tmp.f`** 是冻结口径的 22 文件列表 = 官方 `verilog/filelist.f`
   去掉 `core/memory.v`（已核对是**唯一**差异）。没有任何模块例化 `memory`，
   `hierarchy -top student_top` 会剪掉它 ⇒ 两个列表出同一份网表。冻结成文件是为了与已归档
   基线**逐位可比**；用它的行必须在 `results.csv` 里标注。

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

## 4. 资源纪律

容器 **3.89 GiB / 6 vCPU** ⇒ 并发上限 **2 容器 + 1 宿主任务**。
`make test`（`pi` 一条就 183 s）**不与两个容器同时跑**。
