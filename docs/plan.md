# RV32IM 乱序多发射 CPU — 计划与实现记录

> 本文件是**过程文档**：当前状态、阶段计划、实施过程记录（含 debug 台账）、消融矩阵与待办。
> 设计规格（设计决策 / 参数表 / 时序约定 / 模块接口 / 握手协议 / 陷阱清单，**含 Phase C 的目标架构**）
> 见 `docs/architecture.md`；评测口径一律以 `docs/description.md` 为准（该文件只由用户手动修改）。
>
> **目录已迁到官方框架布局**：`rtl/` → `verilog/`；根 `Makefile`/`config.mk`/`scripts/` 属官方（勿改），
> 自建 iverilog 流程在 **`Makefile.tb`**（`make -f Makefile.tb run/wave/bench`）。
> **本文档里 `rtl/…` 的写法凡出现在历史台账中都是当时的真实路径，未作改写**（避免篡改证据）。

## 当前状态

> **口径声明（2026-09-24）**：`docs/description.md` 已换成官方最终版，评测口径**全面变化**。
> 本节以下内容记录的是**旧口径下**已完成的工作与证据 —— 它证明"乱序核本身功能正确"，
> 但**不等于**官方评测已通过（两者的测试集、终止方式、内存模型、延迟都不同）。差异清单见 §13。

### 收口：三条对官方评测最要紧的差距（**三条均已解决**，原表存档；§1 见 §14，§2/§3 见 §15.10）

| # | 差距 | 后果 | 证据 |
|---|---|---|---|
| 1 | ~~**顶层不是 `student_top`、没有 AXI4-Lite 端口**~~ → 已实现（§14） | 官方 `make build` 直接报 `--top-module 'student_top' was not found`；官方 `make test/perf/synth` 全部不可用 | 实测：19 个源文件全部读入成功，仅缺顶层 |
| 2 | ~~**DIV/DIVU/REM/REMU 未实现（静默 NOP）**~~ → 已实现（§15.10） | 官方 19 个编译正确性程序里 **18 个**用到 `remu`（`course_put_result` 的 `% 253`）⇒ **每一个都算错** | `testcases/correctness_*/program.S`；缺口本体见 §12.3(乙) |
| 3 | ~~**LB/LBU/LH/LHU 未实现**~~ → **已实现，本条是陈旧记录** | 最终版 ISA 免除清单里已**删除**这四条（上一版是免除的）⇒ 现在是必答题 | description.md §架构要求与设计规范 · 1 |

> 第 3 条**从来没有真的缺过**（`de0cd27` 时代的快照）：`decode.v` 的 `ld_f3_ok` 收 `f3∈{0,1,2,4,5}`，
> `mem_width = f3[1:0]`、`mem_unsigned = f3[2]`，`lsq.v` 按 `width_r`/`is_unsigned_r` 做符号/零扩展，
> `mem_subsystem.v` 按 `addr[1:0]` 抽子字。单元证据 `tb_lsq` L12a/b/c（signed byte / unsigned byte /
> signed half）；端到端证据：**6 个 `perf_*` 程序全部使用 `lbu`**（`course_put_result` 之外的主程序路径）。
> 19 个 `correctness_*` 一条 lb/lh 都没有 ⇒ `lb`/`lh`/`lhu` 目前只有单元级证据。

> 另有一条**容易被忽略但会白干**的：官方 `testcases/correctness_*` 与我们 `tb/top/prog/*.data`
> **不是同一批二进制** —— 19 个程序里 **7 个**期望值不同（naive 97/94、expr 136/58、hanoi 184/20、
> magic 216/106、queens 144/171、qsort 81/105、pi 112/137，格式为`官方/本地`）。
> **本仓库 18 个程序的 PASS 证据不能平移到官方评测**，两边要分别看待。

### 正确性 · 功能配置（`MEM_LATENCY=3`，**旧口径**）—— 对应 description.md 的"仿真程序"阶段

`tb/top/prog/` 有 20 个镜像，其中 **18 个带 `ret` 期望值**（TB 的 `exp_ret_f` 表）；
另 2 个 `loopjal`/`loopld` 无终止指令，只配 `+PERF` 用作性能微负载，不参与判对错。
本轮全量复跑（2026-09-19，**计数器口径修复 + LSQ 修复之后**）：

| 程序 | ret | 期望 | 拍数 | 提交 | 冲刷 | 程序 | ret | 期望 | 拍数 | 提交 | 冲刷 |
|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|
| naive | 94 | 94 | 38 | 18 | 0 | hanoi | 20 | 20 | 260887 | 130220 | 12672 |
| gcd | 178 | 178 | 722 | 361 | 60 | bulgarian | 159 | 159 | 405842 | 283399 | 13982 |
| array_test1 | 123 | 123 | 233 | 138 | 12 | basicopt1 | 88 | 88 | 755408 | 472924 | 45051 |
| array_test2 | 43 | 43 | 270 | 158 | 13 | magic | 106 | 106 | 658904 | 451045 | 19445 |
| statement_test | 50 | 50 | 1406 | 794 | 90 | queens | 171 | 171 | 730406 | 422017 | 33337 |
| lvalue2 | 175 | 175 | 67 | 34 | 4 | superloop | 134 | 134 | 661656 | 485004 | 26895 |
| manyarguments | 40 | 40 | 83 | 42 | 6 | qsort | 105 | 105 | 1526733 | 1115140 | 27095 |
| expr | 58 | 58 | 659 | 487 | 19 | tak | 186 | 186 | 1654514 | 1365221 | 29375 |
| multiarray | 115 | 115 | 1856 | 1273 | 32 | **pi** | 137 | 137 | 154707280 | 93403298 | 8157425 |

**18 个全部 PASS —— `pi` 的判词已取得（2026-09-19，Verilator 链路，见 §11）。**
`pi` 此前"未取判词"**不是缺陷，是 harness 上限**：Icarus 实测 ≈0.845 ms/拍，而它要
**1.547 亿拍** ⇒ 单程序 **≈36 小时**。接上 Verilator 后同一程序 **183 秒**跑完（≈716×），
判词 `ret=137`，与期望相符，`pc` 全程落在代码段内。
`pi` 是 spigot 算法：外层 200 轮、内层累计 ≈28 万次迭代，每次含两个**变量除数**的除法 ——
RV32IM 无除法指令，GCC 调用 `__divsi3`/`__modsi3`（`pi.dump` 中可见这两个符号）。
§7 的三种"超时"分类里它属于 **c 形态（只是慢/未定）**，既非 a 真死锁、也非 b 跑飞 ——
**这一分类现已被实测判词证实**。

> **2026-09-27 注（口径）**：本段与上表的 `pi` 是**旧本地测试集**（`tb/top/prog/` 体系）里的 pi ——
> 93,403,298 条动态指令 / `ret=137` / `MEM_LATENCY=3`。官方 `testcases/correctness_pi` 是**另一个程序**
> （`metrics.json` = 3,117,658 条指令，`expected=112`），HEAD × W=1 × LATENCY=10 实测
> `PASS cycles=20,873,662`（占 1e8 上限 21%）。**两套周期数不可比**（`naive` 同理：本地 94 / 官方 97）；
> 判据以**官方**为准 —— 见 §15.10.16 §一。

基础程序阶段（75 分门槛）已过：`p1_sum` ret=86 / `p2_vecadd` ret=96 / `p3_vecmul` ret=72，
拍数 **417 / 213 / 181**（`tb_cpu_top`，本轮实测；早期文档记的 224/192 拍是 §8.2 修复**之前**的数）。

### 正确性 · 性能配置（`MEM_LATENCY=20`，**该口径已作废**）—— 当时搁置

> **口径变更**：最终版 description.md **只有 10 拍一个延迟**（框架 `LATENCY` 默认），
> 旧版的"功能 3 拍 / 性能档 20 拍"两分法**已不存在**。本节保留是因为
> **§7.4 与 §8.2 的三个缺陷正是被 20 拍配置逼出来的** —— 它们的修复是当前代码的基础，
> 而非因为 20 拍本身还有意义。

该配置曾暴露三个缺陷，**均已修复**：§7.4（rs push 被静默丢弃 → 死锁）、
§8.2 缺陷 A（LSQ load 重复发起）与缺陷 B（槽位复用 → 陈旧完成写坏目的寄存器）。

| 项目 | 20 拍下的状态 |
|---|---|
| `multiarray` / `statement_test` / `expr` / `gcd` 等中型程序 | **PASS**（§7.4 修复时验过） |
| `queens` | 修复前算错 `ret=7`（期望 171）；修复后**未取全量判词**（单程序墙钟 >30 分钟） |
| `tak` | 修复前 `commit=x`（20 万拍内仅 51 次分支）；**修复后同窗口 `commit=95850`、4320 次分支** ⇒ X 传播这一失败模式**已被证伪** |

即：20 拍下**没有已知的未修复缺陷**，但**完整判词未取齐**。恢复性能线工作时应先补这两项。详见 §8。

### 面积与 IPC

**面积**：默认参数单发射全核 **7768.5 µm²**（**旧流程**：`synth/cpu.ys` 直跑 Yosys、memory 当黑盒、
**无时序约束**、**不计 SRAM 估算面积**）。旧上限 10000 下的"余量 ≈22%"已作废；
按**新**上限 9000 算是 **86.3%（余量 13.7% / 1231.5 µm²）**，而且新口径还要**加上 SRAM 估算面积**
（`sram_fakeram` 约 0.042 µm²/bit）⇒ **真实余量未知，官方口径基线待重测**（见 `docs/area_budget.md`）。

**新档位**（面积上限 µm², 最低 IPC）= **(9000, 0.6000) / (18000, 0.8450) / (36000, 1.0985)**。
注意"档位按 IPC ×1.3 ↔ 面积 ×2"**只有 2→3 档成立**；1→2 档面积翻倍但 IPC 倍数是 **1.4083**。

**IPC（内部对照，非评测口径）**：`+PERF` 定拍窗口（首 20 万拍，20 拍 / `MEM_INFLIGHT=16`）——
superloop 0.732 / basicopt1 0.634 / qsort 0.550 / bulgarian 0.192 / magic 0.180 / hanoi 0.128
（单发射上限即 1.0；数值与出处见 §8 的表。**这组数字的延迟口径 20 拍已作废**，仅作纵向对照）。
`tak` 修复后在同窗口 `commit=95850` ⇒ IPC ≈ **0.479**；**其余程序未量**（不跑 lat=20）。
hanoi 的停滞归因已定位到 free_list 容量（空闲池余量 **0** 个 preg）——见 §8。

**新增：lat=3 全程序 IPC（`MEM_LATENCY=3`，跑完整程序而非 20 万拍窗口，Verilator 链路）**。
`pi` = 93403298 / 154707280 = **0.6037** —— 这是目前唯一一个"跑完整程序"量出的 IPC，
且它恰好**压在第 1 档门槛 0.6000 上**（余量仅 0.6%）。**这条比 §8 那些定拍窗口数字更值得警惕**：
定拍窗口（`+PERF`）测的是前 20 万拍的瞬时行为，全程序 IPC 才是评测口径。

> **2026-09-27 注**：这里的 `pi` 同上（旧本地测试集，**非**官方用例）⇒ 0.6037 与 1.547 亿拍
> 都不可与官方 `correctness_pi` 对照。口径澄清与官方 pi 的实测见 §15.10.16 §一。

`pi` 的停滞构成（TB 的 STALL 行，三个分类**恰好配满**总拍数）：

| 分类 | 拍数 | 占比 | 含义 |
|---|---:|---:|---|
| `issue` | 101,560,823 | **65.6%** | 本拍发射了 |
| `nobatch` | 36,831,601 | **23.8%** | **取指供不上**（`!have_batch`，`tb_cpu_prog.v:85`） |
| `flushcyc` | 16,314,851 | **10.5%** | 误预测/冲刷恢复中 |
| `block rob/rs/fl/lsq` | 0 / 0 / 0 / 0 | **0%** | 有批但被结构资源挡 —— **一次都没有** |

⇒ **瓶颈完全在"前端 + 冲刷恢复"，后端（ROB/RS/free_list/LSQ）一拍都没挡。**
发射拍占 65.6%，故 `issue` 拍的 IPC 是 0.6037 / 0.656 ≈ **0.92** —— 后端本身接近单发射上限。

误预测按指令类的**占比**（JUMP 行；各类之和 = 总数 8,157,425 ✓）：

| 类 | 误预测数 | 占总误预测 |
|---|---:|---:|
| `bxx`（blt/bge/bltu/bgeu） | 4,830,393 | **59.2%** |
| `beq` | 1,355,735 | 16.6% |
| `bne` | 845,108 | 10.4% |
| `ret` | 844,588 | 10.4% |
| `jalr`（间接跳转） | 281,601 | 3.5% |

**两个靶子，量级不同，别只盯 RAS**：
① **条件分支方向预测（`bxx`+`beq`+`bne` = 86.2%）是最大头**，指向 BHT
（`BHT_SIZE=32` 直接映射，冲突严重 —— 也正是下节候选表里的第 2 项）。
② **`ret` 的误预测率是 99.95%**（845,019 条返回指令里 844,588 条猜错）—— 指向 RAS 有效深度只有 7
（第 4 项）。虽然 `ret` 只占总误预测的 10.4%，但那是"几乎全错"的 10.4%，修起来是确定的收益。
> 口径提醒：`taken` 与 `misp` 的**分母不同**（被预测为 taken 而实际 not-taken 的分支计入 `misp`
> 但不计入 `taken`），故**不能用 `misp/taken` 算各类的误预测率**，只能用"占总误预测的份额"横向比。

**本轮不做优化**（用户决定）。

**IPC 口径**：官方测试点是 **`testcases/perf_*`**（submodule，6 个 workload：median / multiply /
qsort / rsort / towers / vvadd），IPC = `metrics.json` 的 `dynamic_instructions` ÷ 实际运行周期数，
**6 个点取几何平均**；动态指令数**由课程提供**，不由本 CPU 统计。
`tb/top/prog/` 的 18 个程序是**功能验证集**（能判对错），**不是** IPC 口径；
`+PERF` 在它们身上量出的 IPC 只是内部对照，报告中须写明这层差异。

**正确性判据**：每个 case 的 `expected.txt` 与 MMIO 退出值比较（如 `correctness_naive` → 97）。
注意它**不是**我们本地镜像的 94（见上文"不是同一批二进制"）。

### 下一步

按依赖序（详细规格见 `docs/architecture.md` 的「目标架构」）：

1. ~~**补 ISA 缺口**：DIV/DIVU/REM/REMU（§12.3 乙已记录改法）与 LB/LBU/LH/LHU 解码~~ ——
   **已完成**（§15.10）：DIV/DIVU/REM/REMU 多周期落地，LB/LBU/LH/LHU 本来就是好的。
   这是**正确性的必要条件**，且不依赖框架迁移，可以并行开工（官方 18/19 个程序要 `remu`）。
2. **`student_top` 包层 + AXI4-Lite 适配层**：让官方 `make build/test` 第一次能跑通。
   验收判据 = `make test` 的 19 个 `correctness_*` 全过（`expected.txt` 逐条相符）。
3. **MMIO 终止**：去掉 `TERM_RAW`/`ret_val` 通路，改由提交级 store 地址 + `WDATA` 判定（§13.2）。
4. **Cache**（`sram_fakeram` 阵列）+ MSHR：IPC 的主要杠杆。
5. 最后才是性能调优（候选已在 §8/§12.5 列全，且已标注面积代价与风险）。

> **原来的"接入 benchmark"计划（§9）作废**：官方 `testcases/perf_*` 直接提供**预编译好的
> `program.data` 镜像**（装载地址 0），不需要自写 crt0、不需要链接脚本、不需要 ELF→`.data` 转换，
> 也不再有 `__sync_fetch_and_add` 问题（那是 `CPU-2026-Benchmark` 源码树特有的）。

## 实施计划（两阶段，用户已确认）

### Phase A — 接口冻结 + cpu_top 总流水线（骨架）【已完成】

目标：**尽早冻结全部接口契约**，让工程先可编译、可综合检查。

1. ✅ 16 个模块全部按本规格写出**完整参数表 + 端口声明**，内部为可综合空壳（输出定值，标注 `// TODO(Phase B)`）
   （`docs/architecture.md` 的模块接口规格覆盖 16 个：exec 的 alu/branch、front 的 bht/ras/fetch/decode、
   core 的 rat/free_list/rob/rs/ready_table/prf/cdb/lsq/memory、top 的 cpu_top。
   `verilog/` 现为 **19 个 `.v`** = 上述 16 个 + 既有 `adder32`/`mul` + 实现期新增的 `exec/execute_slot.v`）
2. ⏳ **cpu_top 总流水线完整实现**：全部模块实例化 + 胶水 B1–B6 按接口契约写全（详见文件头注释）
3. ⏳ 验证（仅编译/综合级，无功能测试）：
   - 任意现有 TB（tb_mul）经 `make run` 编译全部 RTL → 语法 + 端口连接检查
   - yosys synth 骨架 → 尽早排除不可综合写法

**接口调整记录（Phase A 骨架定稿 vs 初稿计划）**：
- `RS_SIZE` 默认 12→16、`LSQ_SIZE` 默认 18→16（2 的幂：环形指针满判断/年龄回绕才正确）
- rat 新增 `map_arch`（ret_val 采样与调试）、`read_rs1/read_rs2`（读地址显式端口）
- ras 新增 `head_snap`（误预测恢复时取指批的 head 快照）
- fetch 新增 `imem_addr` 输出（memory 取指地址来源）
- lsq 删除 `set_prd`（load 目的 preg 在发射时经 `push_prs2_or_prd` 一次写入）；新增 `set_addr_idx/set_data_idx`（执行槽定位条目）；新增 `free_count`
- rs 删除 `clear_valid/clear_idx`（选中条目自清，无需外部清空口）；新增 `free_count`
- rob 新增 `free_count`
- memory 新增 `INIT_FILE` 参数（TB 加载；运行时 CPU 经 init 口逐字节写）
- 陷阱 #11/#12/#13 为 Phase A 推导新增

### Phase B — 逐模块实现 + 测试（按依赖序；每步：实现内部 → 跑该模块 TB（如有）→ 整机回归）

| 步 | 模块 | TB |
|---|---|---|
| 1 | decode.v | 无（整机覆盖：3 程序触及全部 imm 类型/单热/writes_rd） |
| 2 | rat.v, free_list.v | tb_rat（**批内前递** W=2/4、flush>rename、rd=0 抑制）；free_list 无 TB |
| 3 | rob.v, rs.v, ready_table.v | tb_rob（set_last 截断+head 收敛/终止检测）；tb_rs（**年龄优先 W 选**/flush_mask/空槽复用）；ready_table 无 TB |
| 4 | prf.v, cdb.v | 均无 TB（prf=索引 RAM、cdb=纯组合扇出，整机覆盖） |
| 5 | bht.v, ras.v, fetch.v | tb_fetch（stall 保持/redirect 清批/halt/BHT/RAS 交互）；bht/ras 无 TB |
| 6 | memory.v, lsq.v | tb_memory（$readmemh/同步读/倒计时 MEM_LATENCY/飞行槽满/字节写）；tb_lsq（push 同拍/set_addr+data/**store 前向字节合并**（部分/全部重叠）/排序条件/head 推进） |
| 7 | alu.v, branch.v | tb_alu（14 op 边界）；tb_branch（0x7fffffff/0x80000000 边界） |
| 8 | cpu_top 联调 | tb_cpu_top：3 手写汇编 hex + gcc 编译 C 程序，ret_val 对照参考 C++ 模拟器输出 |
| 9 | 消融 + 综合 | 报告素材 |

**TB 分层策略（用户已确认）**：
- 单独 TB 共 9 个：tb_rat、tb_rs、tb_lsq、tb_memory、tb_fetch、tb_alu、tb_branch、tb_rob、tb_cpu_top —— 复杂状态逻辑 / 正确性关键，错误在整机层面难以定位
- 整机覆盖 7 个：decode、free_list、ready_table、prf、cdb、bht、ras —— 其全部功能被 3 个程序触及（全部 imm 类型、环回、优先级、饱和计数），单独 TB 边际价值低
- 全部 TB 遵循契约：波形 `sim/<域>/tb_<模块>.vcd`；失败 `N TESTS FAILED`→`$stop`；成功 `ALL TESTS PASSED`→`$finish`；一律经 `make run/wave` 运行

**整机程序**（tb_cpu_top）：手写汇编 hex 优先（仅需 addi/add/sub/mul/lw/sw/beq/jal/jalr/li 约 10 种形式）——向量乘（16 元素点乘循环）、向量加（求和）、0-100 累加；结尾 `ori x0,x0,255` 标记；TB 断言 ret_val 与参考 C++ 模拟器输出一致（参考工程可直接跑对照）。**工具链升级**：`riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32`（multilib 已确认存在）编译 C → objcopy 转 hex → 经 init 口 $readmemh。

**进度（截至 2026-09-24）**：Phase A/B **全部完成** —— 19 个模块实现完毕，
`make -f Makefile.tb run` 的 **12 个 TB 全 `ALL TESTS PASSED`、退出码 0**；
18 个编译程序在 `MEM_LATENCY=3` 下**判词全对**（§10 + §11.4）；
§6 的仿真速度问题已由 Verilator 链路解决（§11，`pi` 从 36 小时降到 183 秒）。
**当前阻塞已换**：不再是内部缺陷，而是**与官方框架的对接尚未开始**（Phase C，见下）。

### Phase C — 官方框架对接【下一步】

**目标**：让官方 `make build / test / perf / synth` 四条命令**第一次真正可用**，
并使 ISA 补齐到最终版要求的全 RV32IM。规格见 `docs/architecture.md` 的「目标架构」（C.1–C.8）。

| 步 | 内容 | 验收判据 |
|---|---|---|
| C1 | **ISA 补齐**：DIV/DIVU/REM/REMU（改法见 §12.3 乙）。~~+ LB/LBU/LH/LHU 解码与访存~~ —— **LB/LH 早已实现**（`5fee7b7` 前后落地），此处系陈旧快照，证据见文首"收口"表注 | **已完成**（§15.10）：`make test` 19/19 PASS；新增 `tb_div`；自造角例程序 `tb/top/div_corner.data` PASS。原判据里"`tb_lsq`/`tb_alu` 加用例"不成立——除法器是独立多周期模块，`tb_alu` 覆盖不到（改用 `tb_div`）；`tb_lsq` 无需改（load 路径未动） |
| C2 | **`student_top` 包层**（复位取反 + 端口对接），`verilog/filelist.f` 顶层指向它 | `make build` 编译通过；`make run PROGRAM=testcases/correctness_naive/program.data EXPECTED=97` 出 PASS |
| C3 | **`axi_lite_master` + `mem_subsystem`（旁路档 `IC_SIZE=DC_SIZE=0`）** | `make test` → **19 个 `correctness_*` 全过**（`expected.txt` 逐条相符）；这是"总线路径功能正确"的独立证据 |
| C4 | **MMIO 终止**（提交级 store 地址判定 + `exit_value`，删 `TERM_RAW`/`ret_val`） | C3 的判据即可覆盖（`expected.txt` 就是靠 MMIO 退出值判的） |
| C5 | **`store_queue` + `tb_store_queue`**（架构 C.6 的时序洞专项） | 专项 TB：提交-失效-写生效三事件交错下 load 不读到旧值 |
| C6 | **`dcache`（MSHR/合并/装行）→ `icache`（`inst_valid`/`imem_stall`/跨行）** | 两级都过 `make test`；`IC_SIZE=0/DC_SIZE=0` 与缓存档**判词一致**（回退二分手段） |
| C7 | **清掉 `core/memory.v`** 出 `verilog/filelist.f`（留作本地回归后端） | 官方流程不再引用它；本地 12 个 TB 仍全绿 |
| C8a | **工具链就位 + 冒烟**：在 OrbStack 容器内跑通官方 `make synth`（Yosys+ABC+OpenSTA+ASAP7 r28） | **已完成 2026-09-24**：镜像构建成功（`cpu2026:local`），冒烟 `student_top{mul,adder32}` 九条判据全过（见 §13.5）。**此时仍拿不到真核数字** —— 见 C8b 的两条阻塞 |
| C8b | **真核面积/频率基线**：对真核 `student_top` 跑 `make synth` + `make perf` | 拿到官方口径的总面积（含 SRAM）、`F_max`、6 个 perf 点的几何平均 IPC。**依赖 C2（顶层）+ C7（清掉 `core/memory.v`）** —— 后者不落地则 `memory.v` 的 64KB 阵列会被 Yosys 降成触发器，面积数字无意义 |

**纪律**：每步 **双门禁** —— `make -f Makefile.tb run`（12 个单元 TB）+ `make test`（19 个官方正确性点）；
C2 之后本地 `tb_cpu_prog` 的 18 个镜像**仍应全绿**（它们走 `LEGACY_TERM=1` 的旧终止通路）。

#### 官方入口速查（**已实测**，读 `Makefile` + `scripts/*.py`；写 Phase C 时按此调用）

| 命令 | 语义 / 必填 | 备注 |
|---|---|---|
| `make` / `make code`（**默认目标**） | `make build` 后 `cp build/sim code` | **OJ 提交物就是 `./code`**（要跟着 `verilog/` 一起交） |
| `make build` | `FILELIST=verilog/filelist.f` → `build/sim`（Verilator） | `JOBS=4`；本机需 `CONFIG=config.local.mk` |
| `make run` | **必须给 `EXPECTED=`**（否则退出码 2）；`PROGRAM=`（默认 `program.bin`）、`WAVE=`、`LOG=` | 走 argv 协议，stdout 打 `PASS/FAIL cycles=…` |
| `make test` / `make perf` | 走 **OJ 协议**（stdin），`TESTCASES=` 默认 `<仓库>/testcases`；`Case=` 单跑一个 | `MAX_CYCLES=1000000`、`LATENCY=10` 是默认值 |
| `make synth` | `MODE=opt\|diagnose`、`CLOCK_PERIOD_NS=2.0` → `build/synth/<MODE>/` | 宿主缺 `sta` ⇒ **走容器**；链路已跑通，见 §13.5 |
| `SIM=/path/to/prebuilt/sim` | 跳过 `build`，复用已编译的 `sim` | **迭代 RTL 时省一次 Verilator 编译**（约数十秒） |
| `BLACKBOXES=...` | **已被框架移除**，一给就 `$(error)` | 对应的正确做法是例化 `sram_fakeram` |

> 终止序列已在官方题面里**证实**：19 个 `correctness_*` 的反汇编里，每个都有一条
> `sw a0,0(t0)`，其中 `t0 = lui 0x80000`（= `0x80000000`），另有 `sw` 到 `# 2d0 <N>` / `# 5c4 <seed>`
> 这类**数据符号**（地址在代码段之上）。⇒ C4 的 MMIO 判定与"子字 store 不终止"两条都有真实用例兜底。
> 另注意 `--max-cycles` 默认 **1e6**：任何 `correctness_*` 跑到 1e6 拍未终止即判 `FAIL: timeout`。

## 实现过程记录（供"架构设计探索"报告取材）

记录实现中被验证抓出的**真实缺陷**及其设计层面的取舍，按时间顺序。

### 1. free_list 重复分配活跃物理寄存器（tb_cpu_top 抓出）
初版 free_list 用 FIFO 回收顺序，flush 回滚 + 提交回收交错时会把**仍被未提交指令引用的 preg** 放回空闲表 → 同一 preg 被两条活跃指令占用 → 值互相覆盖（表现为程序算错、commit 与参考不符）。
修正：改为 **LIFO 栈**（后释放先复用），并在 flush walk 与提交回收之间保持"栈内 preg 恒 ready"的约定（陷阱 #12）。收益是复用的 preg 更年轻，长依赖链上唤醒更早。

### 2. issue/flush 路径与"错路批"泄漏（tb_cpu_top 抓出）
`issue_en` 漏了 `!misp_valid`：walker 触发当拍仍发射的错路批落在 flush 窗口尾部之外 → RAT/preg 泄漏（陷阱 #11）。同轮把 fetch 的握手从"自由跑 PC"改为**请求标签制**（tag 计数配对，用于丢弃错路到达）。

### 3. 取指握手重构：标签制 → 地址比对制（tb_fetch 重写驱动）
标签制能工作但代价高：需要 `tag_r/arr_tag_r/del_tag_r/kill_r` 4 个寄存器与"在途请求数"的对齐逻辑，且 stall/redirect/预测跳转三种情形各有一套作废规则。重构为**单一期望地址指针**：
- 用 `imem_addr_d`（与 `inst_data` 同址的延迟地址）与 `exp_pc_r` 做一次相等比较即可判定"到达的是不是下一批"；
- 三种作废情形自动统一（重复读出、错路读出都被地址不等丢弃），省掉全部作废信号；
- 代价：需要一条"重取"规则兜底（见 3.4）。

重构过程本身也暴露了两个 TB 侧的坑（记录以便复用）：模型必须在 **posedge 时刻**采样组合量（激励在 posedge 前已施加，DUT 正是在此刻用它决策），以及 `$random` 拼接的位宽不定问题。

### 3.1 满批丢弃丢指令（严重，会算错/跑飞）
稳态下 `pc_r = exp_pc_r + 4W`（领先一批）。后端 stall 时批寄存器满，此时**恰好到达的正是 `exp_pc` 批** → 被丢弃，而 PC 已越过它，该批**永远不会再交付**（TB 中直接复现：pc 跑到 0xa0、exp 卡在 0x20）。
修法：丢弃拍把 PC 回退到 `exp_pc_r` 重取（`rewind_w`）。回退后 memory 每拍重复读出 `exp_pc`，故 stall 一解除立即接收，**不付额外气泡**，代价仅"stall 期间不预取"。
**为什么必须修**：`tb_cpu_top` 三个短程序后端从不满，修前修后周期数逐项一致（p1 417/305/2/100），说明整机测试**根本触不到**这条路；而性能档要求 `MEM_LATENCY=20`，长延迟访存必然把 LSQ/ROB 占满 → 正好是触发条件。

### 3.2 截断后的槽污染 RAS（严重）
批内首个预测跳转之后的槽属**错误路径**（`f2i_valid` 已截断，指令稍后从跳转目标重新取），但它们仍在接收拍驱动了 push/pop → head 被弹错、RAS 内容错位。
修法：`ras_ops_w[g]` 增加 `!pt_c[g]` 门控，只让"取指路径上的前缀"动 RAS。

### 3.3 PC/exp 跟随"最后一个"预测跳转（严重）
原流式链是"高槽覆盖"，于是错误路径上的第二个预测跳转会**劫持 PC**（实测 pc_r 变 X 并扩散）。修法：改为"**首个**预测跳转决定 PC/exp"（低槽优先），与 3.2 的门控同源。

### 3.4 RAS 满栈判定失效 + 栈未复位（中等）
head 只有 `RA` 位，满栈 `head = RAS_SIZE` 被截断为 0 → 满栈判据 `hprev != RAS_SIZE` 永不成立，第 9 次 push 覆盖栈底。取舍：把"深度"从 `RAS_SIZE` 降为 `RAS_SIZE-1`（head 必须能原样喂给恢复通路，宽度不可少），换来判据与快照都精确。
栈数组同时随复位清零：head 被 restore 到未写过的位置时原会读出 X（仿真）/垃圾目标（硬件），清零后等价于空栈预测 0，只损失一次预测精度。

### 3.5 BHT 同索引多槽写序（轻微）
原为倒序应用（同索引时**低槽赢**），与 rat/free_list 的"后槽覆盖"约定相反。改为正序（更年轻者最后写 → 它赢）。残留简化：各槽新值都基于旧值快照，故同批同索引别名时只体现最年轻分支的一次更新（可接受：同批别名要求两分支相距 `4*BHT_SIZE` 字节）。

### 3.6 单元 TB 的期望值修正（非 RTL 缺陷，但记录设计契约）
- **RS 唤醒契约（tb_rs 25 处失败）**：TB 模型原按"同拍执行槽 CDB 旁路"判就绪，DUT 只用 `rt_ready`（写回拍置位）唤醒执行依赖。这不是 DUT 漏功能，而是**组合环规避**的必然结果：若执行槽广播参与就绪判断，就有 `ready_e → sel_valid → cdb_valid → ready_e` 环路（回绕后 prd 撞旧映射即成风暴）。故执行结果唤醒**晚一拍**（1-cycle wakeup），load 槽广播因由 memory 寄存器驱动、天然无环，才可同拍命中。TB 改为只让 load 槽参与模型就绪，并补 R7c/R7d 两个断言把这个契约固化（防止日后有人"顺手"加回执行槽旁路）。
- **LSQ 发起索引语义（tb_lsq 15 处失败）**：DUT 的 `ld_start_idx` 是**物理条目号** `(head + 距离) & (LSQ-1)`，TB 模型的 `cand[]` 按"距 head 的距离"索引，却把距离直接当成期望条目号并据此查地址 → 仅当 `head != 0` 时暴露（15 处失败全部落在随机段，directed 段 head=0 掩盖了它）。改 TB 的期望为 `(head + 距离) & (LSQ-1)`，与 DUT 的 `pidx` 公式一致；字节合并前向那条路径本来就是"距离 vs 物理"分开处理的（`(j - head)`），未受影响。
- 两者都说明同一件事：**TB 的期望值必须是"设计契约"的精确复述**，含糊（同拍/次拍、距离/物理）在 head=0、无 stall 的短测里会被静默掩盖。

### 3.7 待办/已知简化
- 同批 call→ret（相距 4 字节）时 ret 预测读到的是**旧栈顶**（push 在 posedge 才写栈，无前递）→ 预测错一次，可恢复；若值得可加"批内 push 前递"
- 取指气泡：一次预测跳转 = 1 拍（在途顺序批作废）。若把 `imem_addr` 直接由 `exp_pc_r` 驱动可再省 1 拍，代价是 PC 与请求地址解耦、预测链位置改变（收益见 p1_sum 的 100 次分支）
- 乘法器 TB 耗时极长，按用户要求不频繁跑；面积/综合（Yosys+ASP7）按用户要求后置
- `tb_cpu_top` 内仍留有调试脚手架（F/R/ISS/CMT/BR/PUSH/POP trace、架构影子寄存器、`/tmp/cpu_top_prog.log`、`dump_stuck`、`DBG` 打印），交付前清理
- ~~**整机 TB 仿真速度 30~50 ms/拍**（gcd 726 拍 23 s、tb_cpu_top 833 拍 41 s）~~ → **已由 §6 解决**：
  根因是 `alu.v` 未门控纯组合乘法器输入 + `mul.v` 华莱士树的两处写法，改后 **33.1 → 0.72 ms/拍（46×）**。
  （"宽向量网络"这一原假设已被隔离实验证伪，勿再按它下手。）
  **全量回归的墙钟代价另见 §10**（本轮实测：串行 CPU 时间 ≈9200 s，长尾是 qsort/pi/tak）。

### 4. 取指 PC 被"陈旧指令的预测"劫持 → 整机死锁（gcd 卡死抓出，严重）
**现象**：`+PROG=gcd` 永不停机（`timeout @2000000 (halt=0 pc=00001004 commit=9)`）。逐拍 trace 显示 ROB 已空（robh=robl=9）、无批可发，而 pc 在 `0x1018 → 0x109c → 0x10a0 → 0x1000` 乱跳、`f2i_valid` 长期为 0 —— 即"取指还在动，但到达的数据永远不等于 `exp_pc_r`"。

**根因**：`pc_next` **无条件**采用当拍到达数据的跳转预测（`pt_c[W] ? flow_c : pc + 4W`），但到达数据并不总是"本流"指令：
- 预测跳转（predicted-taken）后 1 拍：到达的是**顺序后继**（已属错路）；
- 重定向后 1 拍：到达的是**重定向前旧地址**的数据；
- stall 期间：memory 重复读出同一地址（陈旧）。

这些陈旧指令若恰是分支/jal/jalr(ret)，其预测目标就会改写 pc → pc 被劫持到任意地址 → `imem_addr_d` 再也追不上 `exp_pc_r`（而 exp_pc 只在 `cap_w`/redirect 时改变）→ **永久失步死锁**。naive 与 p1~p3 能通过纯属"错路后继恰好不是跳转指令"的运气。

**修复**：新增 `pred_ok_w = arr_ok_w && !halt`（到达数据正是期望批），只有它成立时预测才可改写 pc；否则 pc 只做顺序推进——它只是"在途请求"，不改变 exp_pc 的推进。`exp_pc` 的推进本就在 `cap_w` 下（隐含 `arr_ok`），无需改动。

**契约更新与教训**：`tb_fetch` 的参考模型里**复刻了同一条未门控路径**，所以此前"逐拍 300 拍全绿"是模型与 DUT 一起错。TB 与被测同源时必须警惕这类**共模错误**：逐拍对照只能证明"实现符合模型"，模型本身的语义要靠独立的边界推演（此处是"到达数据可能不属于本流"）来审。已在模型里加同一门控。

**验证**：`tb_fetch` 全绿；`tb_cpu_top` 三程序周期数逐条不变（417/305、224/178、192/146）→ 修复只影响"陈旧预测劫持"这条路径；gcd 由死锁变为 PASS。

### 5. 编译程序整机验证链路（85 分阶段）
- **终止约定**：编译测试程序以 `addi a0,x0,255`（0x0FF00513）结尾表示停机。decode 把它视作"写 x0"（不写 a0）→ a0 保留 main 返回值；cpu_top 同时认手写程序的 `ori x0,x0,255`（0x0FF06013）。
- **访存宽度**：测试程序实际用到 `lbu`(36) 与 `sb`(3) → decode 放开 `lb/lbu/lh/lhu/sb/sh`（f3[1:0] 作宽度、f3[2] 作无符号），取消原先"只支持 lw/sw"的限制。
- **参考模拟器作 oracle**：`RISC-V-Tomasulo-CPU-Simulator/build/code` 从 stdin 读 `.data` 镜像、stdout 打印 `ret`；18 个测试用例期望值已采集，与 TB 内 `exp_ret_f` 表逐条吻合（无 div/rem/mul 指令，GCC 把 `% 253` 强度削减掉了）。
- **harness**：`tb/top/tb_cpu_prog.v`（`+PROG=<名>` 选程序、`+DUMP=N` 只记前 N 拍、`+TRACE=N` 逐拍 trace rob/rs/lsq/mem）+ `tb/top/prog/*.data`（**20 个镜像** = 18 个可判对错的程序 + `loopjal`/`loopld` 两个无终止指令的性能微负载，后者只配 `+PERF` 用，故不在 `exp_ret_f` 表内；`$readmemh` 直载）；Makefile `ARGS=` 透传 vvp。
  注：TB 一次只跑一个程序（`+PROG`，缺省 `naive`），全量回归需外部循环。
- **⚠ 陷阱：`+PERF=N` 是"定拍窗口"模式，与判对错互斥**。`while` 条件含 `cyc < perf_n`（`tb_cpu_prog.v:214`），
  故一旦给了 `+PERF`，程序**跑到 N 拍就退出**，永远走不到 `PASS/FAIL` 分支（输出只有 `PERF:` 一行）。
  反过来说：**要判对错就不能给 `+PERF`**，要量 IPC 就不能指望它判对错 ——
  本次查 lat=20 判词时误加了 `+PERF=200000`，白跑一轮（只拿到 IPC，无判词）。§9 量 IPC 时须显式分开两次运行。
- **已通过**：`naive` ret=94（45 拍）、`gcd` ret=178（726 拍 / 364 提交 / 60 冲刷）。

### 6. 整机仿真速度调查（已定位并修复：根因在 mul.v 的华莱士树写法）

**目标**：整机 TB 30~50 ms/拍（gcd 726 拍 ≈ 23 s；`tb_cpu_top` 833 拍 41 s），而 pi/queens/superloop 可能 10^5~10^6 拍 → 必须降下来才能跑完全部 18 个程序与消融矩阵。

**测量方法（含噪声警告）**：同一个 vvp 二进制重复跑 gcd 200 拍，得到过 7.6 s 与 14.3 s —— **机器负载带来 ~2x 抖动是常态**。故此前所有 ±3% 级的对比（典型："rs.v 重构后 23.2 → 22.6 s"）都落在噪声内，**不可作为结论**。今后一律在同一次运行内交替 A/B 并重复，只认 ≥2x 的差异。

**基线（`+PERF=N` 定拍数、`+DUMP=0`）**：

| 负载 | 每拍成本 | 说明 |
|---|---|---|
| 固定开销（`PERF=1`） | 0.38 s 总额 | 清 26 万字节 + `$readmemh` + 复位，与拍数无关 |
| `loopjal`（jal 自循环，IPC≈1，flush=0） | **1.10 ms/拍** | 正常流水本身不慢 |
| `loopld`（lw+分支循环，IPC≈1） | **1.10 ms/拍** | 访存路径也不额外慢 |
| `gcd` 200 拍（commit=113, flush=13） | **38 ms/拍** | 35 倍差距**跟着 flush 走** |

**已排除**：
1. **VCD 机制** —— 把 `$dumpfile/$dumpvars/$dumpoff` 全删的 TB 副本 14.95 s vs 原 TB `+DUMP=0` 14.31 s（噪声内）→ `$dumpoff` 已足够。
2. **TB 循环结构 / 内存初始化** —— 固定开销仅 0.38 s；微 TB 用同一 `#1;#8;#1` 节奏仍是 0.05~0.3 ms/拍。
3. **宽打包阵列总线（原"方向 a"假设）** —— 隔离微 TB（1500 拍满负荷流量，`+STATIC` 冻结输入作对照）：`rob` **0.047**、`lsq` **0.33**、`memory` **0.09** ms/拍；三者合计 ≈0.5 ms/拍，比整机低 60 倍。`+STATIC` 与动态无差别 → 与"数据变化触发 concat 重建"无关。据此做的 rs.v 整阵列→逐槽重构实测零收益，**已回退**（接口改动无收益、无面积收益，徒增 diff）。
4. **内存阵列规模** —— `MEM_SIZE` 65536 → 0.08 s、262144 → 0.16 s（1500 拍，0.1 ms/拍），与整机差 300 倍。
5. **单模块固有开销** —— `rob/lsq/memory` 三个"大数组"模块本身都不慢。

**已排除的调查手段**（工具限制，勿重试）：
- `iverilog -tvvm` 导出 vvp 汇编、按 `-pfileline` 定位 `concat8` 现场：oss-cad-suite 14.0-devel 与 homebrew 13.0 **两个安装都缺 vvm backend**（`Code generator failure: -2`）。
- `iverilog -P`：**只对 root 模块生效，对其他模块静默忽略**（实测 `-Psub.P=8` 仍得 32，无任何警告）。消融矩阵必须用 `defparam` 或把参数提到 TB（root 层），否则会得到"所有参数都不影响性能"的假结论 —— 本次已踩坑：`rob8/rs8/lsq8/...` 一整列数字全等于 base。

**根因（已定位，netlist 级证据，非推测）**：`rtl/exec/mul.v` 的华莱士树写成「**打包向量 + 逐位索引**」。

用 `iverilog -g2005 -s tb_cpu_prog -o /dev/stdout tb/top/tb_cpu_prog.v rtl/*/*.v`（vvp 输出实为**可读文本**）解析全设计网表：

- 全设计 **9466 个 `.part`（位选）节点，其中 8573 个（91%）在 `mul`**；单编译 mul+adder32 时，`mul` 占该编译 **15274 条语句的 76%**。整个组合逻辑只有 ~9000 functor / ~20000 net —— 30~50 ms/拍不可能来自网表规模，只能是某些部分每拍被反复重算/重投递。
- 具体形状：`mul.v:21` 把 18 个部分积行**按行主序打包进一个 1152 位向量** `rows_pk`，`tree_level` 再对每一列每一位做 `in[(3k+0)*64 + c]` 这样的**单位索引**。实测各打包向量的读者数（全部是 1 位 `.part`）：

  | net | 位宽 | 1 位读者数 |
  |---|---|---|
  | `rows_pk` | 1152 | **3042** |
  | `l1` (t1 out) | 768 | 2028 |
  | `l2` (t2 out) | 512 | 1268 |
  | `l3` (t3 out) | 384 | 1014 |
  | `l4` (t4 out) | 256 | 571 |
  | `l5` (t5 out) | 192 | 507 |

- 与运行时 profile 完全吻合：99% 采样落在 `vvp_fun_concat8::run_run → vvp_send_vec8 → reduce4 → set_bit` —— 即「一个大 concat 建起来、再逐位投递给上千个 1 位消费者」。任一输入位变化 → 整棵树重算 → 向 3042 个目标逐位重投递。
- **解释了全部旧观测**：a) 成本跟随「流水线活动量」而非 flush —— `loopjal` 是 `jal x0,0` 自循环，操作数长期不变 → 树不翻转 → 零传播，故 1.10 ms/拍；gcd 每拍都在换指令 → 每拍全量重算，故 32 ms/拍。b) 与 flush 的相关性是巧合（flush 多 = 在飞指令多 = 活动量高），这正是"每次 flush 固定成本模型两点不自洽"的原因。c) 隔离微 TB（rob/lsq/memory）快，因为里面没有乘法器。d) `tb_mul` 极慢，同一个原因。e) **C 的 `concat8` 采样不是振荡，是逐位扇出**；A/D 是同一现象（活动量）的两种描述；B 由本次定位排除。

**另经核验**：全设计 **0 个组合环**（Tarjan SCC 分析；此前一度出现的"213 个环"是图构建把「共享同一输入的 functor」误判成环，已修正）。

**修复（三处，纯重构 + 活动门控，功能逐位一致、周期数不变）**：

1. **`mul.v` — `tree_level` 改词级运算**（主要收益）。保留端口 `input [IN*64-1:0]`，内部对 **64 位整行**做压缩，彻底消除逐位索引。要点：进位行 `<< 1` 精确复现 `c-1` 列索引（列 0 自然得 0，列 63 的进位同样丢弃，且是确定 0 而非 X）；`(x&y)|(x&z)|(y&z)` 是多数函数展开；**半加器进位必须是 `(x & y) << 1` 而非多数表达式**；`thru` 行整行原样搬运；**`<<` 优先级高于 `&`/`^`/`|`，外层括号必须照写**。
2. **`mul.v` — 校正位行改整行单驱动**。原先第 17 行用 64 次**单位写**构造，改成一条 64 位拼接 `hot_row`（位 `2i` = `pp_neg[i]`，i=0..16，其余为 0）。**不要**把 `rows_pk` 改成单驱动：实测 Icarus 对**常量基址的 `+:` 目的端写**（17 个 booth 行写）不产生任何 `.part` 节点，已在编译期合并、运行时免费，收益为零而代价是 `$mem` 推断风险。
3. **`alu.v` — 非乘法指令时门控乘法器输入**。`mul` 是纯组合的，即使指令不是乘法，只要 `a`/`b` 变（几乎每拍）整棵 1152 位树就重算 —— gcd 里一条乘法都没有却要 32 ms/拍，就是这个原因。`wire sel_prod = (op >= 5'd10)` 把输入钳到 0。**必须用 `>=` 而非枚举**：`result` 的 default 分支取 `product[63:32]`，编码 14..31 也消费它。

**效果（实测）**：

| 测试 | 修复前 | 修复后 | 加速 |
|---|---|---|---|
| `tb_mul` (2400 checks) | 202.01 s | 1.79 s | **113×** |
| `tb_cpu_top` (833 拍) | 42.01 s / 50.4 ms·拍 | 0.61 s / 0.73 ms·拍 | **69×** |
| `tb_cpu_prog +PROG=gcd` (726 拍) | 24.00 s / 33.1 ms·拍 | 0.52 s / 0.72 ms·拍 | **46×** |

**等价性证据**（改的是纯组合网络的求值方式，必须逐位一致）：`tb_cpu_top` 三行 PASS 逐字符一致（`p1_sum ret=86 cycles=417 commit=305 flush=2 branch=100`、`p2_vecadd ret=96 cycles=224 commit=178`、`p3_vecmul ret=72 cycles=192 commit=146`）；`tb_cpu_top.v:194` 写的 4298 行逐拍 trace `/tmp/cpu_top_prog.log` 与基线 **byte-identical**；gcd `ret=178 cycles=726 commit=364 flush=60 branch=120` 不变；`make` 12 个 TB 全绿（退出码 0）。

**网表收敛**：`mul` 的 `.part` 节点 8573 → 211，每拍位操作量从 ~6.35M 降到 ~38k（~167×）；全编译语句数 20066 → 2142。综合面积（YoSys + ASAP7，同一条命令前后各跑一次）：`mul` 555.191820 → **554.608620** µm²（−0.10%），`cpu_top` 7765.351740 → **7774.741260** µm²（**+0.12%**，门控 mux 的代价）—— 都在"纯重构"的预期内，面积未动。

> 踩坑记录：`synth/out/` 在 `.gitignore` 里，此前留着的 `cpu_stat.txt` 是 **8月18** 的陈旧产物（远早于本轮改动），拿它当基线会得到"面积涨 6.8 倍"的假结论。面积门禁必须**当场重跑基线**（本次做法：`git stash` 改动的 RTL → `make synth synth-cpu` → `git stash pop`），不能复用工作区里的历史文件。

**教训**：§6 前面几轮把注意力全放在"数据结构大的模块"（rob/lsq/memory）和"flush 路径"上，是因为**先用采样 profile 猜了成分再去找模块**，而采样只给到 `concat8`/`send_vec8` 这种通用 functor，不含模块名。真正定性的是**网表级统计**（`.part` 节点按模块归类）——它直接指出 91% 的位选挤在一个模块里。这类问题下次应当**先按模块统计网表节点**，再谈 profile。

### 7. 18 个编译程序只过 9 个：控制流跳出代码段 / 停滞（已定位并修复：两个独立缺陷）

**背景**：§6 的速度问题解决后，18 个测试程序第一次跑得完。结果 **9 过 9 挂**（原始 RTL，未加任何 LSQ 补丁）。全量 run 墙钟 2928 s。

```
naive          PASS ret=94    cycles=45      commit=27
gcd            PASS ret=178   cycles=726     commit=364
array_test1    PASS ret=123   cycles=244     commit=145
array_test2    PASS ret=43    cycles=287     commit=171
lvalue2        PASS ret=175   cycles=67      commit=35
manyarguments  PASS ret=40    cycles=83      commit=43
expr           PASS ret=58    cycles=661     commit=488
basicopt1      PASS ret=88    cycles=755464  commit=472952   ← 修复前跑不动
superloop      PASS ret=134   cycles=661668  commit=485005   ← 修复前跑不动

statement_test FAIL timeout@2000000 halt=0 pc=000011fc commit=780
multiarray     FAIL timeout@2000000 halt=0 pc=00001178 commit=772
hanoi          FAIL timeout@2000000 halt=0 pc=0000103c commit=273
bulgarian      FAIL timeout@2000000 halt=0 pc=000013bc commit=4555
magic          FAIL timeout@2000000 halt=0 pc=007a1b6c commit=429     ← pc 远在代码段外
qsort          FAIL timeout@2000000 halt=0 pc=000010e8 commit=184820
queens         FAIL timeout@2000000 halt=0 pc=000011dc commit=410
pi             FAIL timeout@2000000 halt=0 pc=000011f8 commit=1210197
tak            FAIL timeout@2000000 halt=0 pc=00001084 commit=365
```

**先分清三种"超时"，不要当成同一个 bug**（此前一轮的记录把它们混为一谈，是错的判读）：

| 形态 | 判据 | 命中 |
|---|---|---|
| **a. 真死锁** | commit 数冻结在很小的值，逐拍 trace 状态完全不变 | `hanoi`（commit=273，见下） |
| **b. 跑飞** | `pc` 跳出代码段 | `magic`（pc=0x007a1b6c，远超 `MEM_SIZE`=0x40000；程序装载在 0x1000） |
| **c. 只是慢/未定** | commit 数很大，可能仍在推进，只是 2M 拍不够 | `pi`(1.21M)、`qsort`(18.5万)、`bulgarian`(4555)、`statement_test`(780)、`multiarray`(772)、`queens`(410)、`tak`(365) |

**b 形态就是最初的问题（"控制流为什么跳出代码段"），而它现在有了确定的最小复现：`magic`。** 之前一直拿 `hanoi` 当复现，但 hanoi 其实是 a 形态（停滞），两者的根因未必相同 —— 这是本轮最重要的认识修正。

**a 形态（hanoi）已定位到 `rtl/core/lsq.v`，证据链**：

- 冻结拍状态：`pc=0000103c f2v=1 raw=00054783 iss=0 hb=1 misp=0 flsh=0 halt=0 robh=17 robl=31 rdy=0`。
  `raw=0x00054783` 解码 = `lw x15, 0(x10)`；`rob_ready_w[17]=0` —— ROB 头是一条永不完成的 load。
- `issue_en=0`，而 `have_batch=1`、`misp/flushing/halt` 全 0 → **发射是被资源门挡住的，不是没批可取**。
  `resources_ok` 的四项里只有 LSQ 那项不成立：`lsq_free_w + n_inv >= n_mem` → `0 + 0 >= 1` = 假。
- LSQ 探针（`hanoi` 第 396~397 拍）：`free=1 h=1 l=0 win=15 valid=1111100000000000`
  → **窗口 15 槽里只有 5 条活的，10 个洞**；下一拍一次 push 后 `free=0 h=1 l=1 win=0`。

**两个缺陷**：

- **Bug A（主因）**：`winlen = (last_r - head_r) & (LSQ_SIZE - 1)` **分不清空与满**。`free_count_r` 复位成 16，允许占满 16 槽，于是 `head == last` 既表示空也表示满 → `winlen` 翻成 0 → `in_win = (gd < winlen)` 对所有 `gd` 为假 → `cand` 全灭 → 没有任何 load 能发起；同一拍 `free_count=0` 又挡住新发射 → ROB 头那条 load 永不完成 → 不提交 → `head` 不动 → **闭环死锁**。
- **Bug B（次因）**：`flush_skip_f` 只跳过"**当拍被 flush 掩码命中且正好落在 head**"的条目。但被冲刷的条目是窗口的**后缀**（年龄 > fs），所以 `flush_skip` 几乎恒为 0；这些条目变成只能靠提交时 `|invalidate` 一条条回收的洞 → 窗口被洞撑大（实测 15 槽只剩 5 条活）。

**C++ 参考（用户指定为权威语义）确认了意图**：`src/core/cpu_top.cpp:291-296` 每拍**无条件** `while (lsq_hd != lsq_lt && !valid[lsq_hd]) lsq_hd++;` 跳过 head 处的无效条目；`include/storage/lsq_module.hpp` 里 `full = ((last+1) % LSQ_SIZE == head)`，即**保留 1 槽**、占用 ≤ 15，`head == last` 唯一表示空；**根本没有 `free_count`**（由 head/last 导出）；flush 期间 `issue_lsq_.suppressed = 1` 抑制 push。

**已经排除的可能原因**：

1. **不是 §6 的性能修复引入的** —— mul/alu 改动是逐位等价的（`tb_cpu_top` 三行 PASS 逐字符一致、逐拍 trace byte-identical、gcd 周期/提交/冲刷全不变），不可能改变程序语义。18 个程序这次跑的结果就是**未加任何 LSQ 补丁的原始 RTL** 产出的。
2. **不是取指 PC 被陈旧预测劫持**（那个已在 `5fee7b7` 修掉，gcd 由死锁变 PASS）。
3. **不是 ROB 满 / RS 满 / 写口不足 / 没有批可发** —— 探针显示 `rob_full=0`、`have_batch=1`、`misp=flushing=halt=0`，`resources_ok` 四项里只有 LSQ 那项为假。
4. **不是 flush 未收敛** —— hanoi 冻结拍 `misp=0 flsh=0`。
5. **`lsq.full` 输出根本没被 cpu_top 使用**（只声明、只连到实例端口），所以 `full` 这个信号本身不参与任何判断，它只通过 `free_count` 起作用 —— 排查时不要盯 `full`。
6. **模块级新旧等价测试（`/tmp/muleq`）未跑完就被终止**，输出只有 `=== compiled ===`。但这条已被更强的证据覆盖：`tb_mul` 直接对 2400 组输入逐位比对 64 位积且 PASS，整机逐拍 trace 与基线 byte-identical。**不必重跑**。
7. **§6 的 A/B/C/D 四个嫌疑**（flush 路径 / 未隔离模块 / 组合振荡 / 占用度）在 §6 已全部关闭，与本节无关。

**结论：a 与 b 两个形态是**两个独立缺陷**，各自修复后 hanoi 才通过。**

#### 7.1 修复 1 — LSQ 窗口语义（a 形态真死锁），commit `c641e71`

照 C++ 参考语义重写 `rtl/core/lsq.v`：

- **环形保留 1 槽**：占用 ≤ `LSQ_SIZE-1`，`head == last` 唯一表示"空"（与参考 `full = ((last+1) % LSQ_SIZE == head)` 一致）。Bug A 由此根除：不再出现 `winlen` 分不清空/满而翻成 0 → `cand` 全灭 → 无 load 可发起 + `free_count=0` 挡住发射的闭环。
- **head 每拍跳过 head 处连续死条目**：`dead = ~valid_r | flush_mask | invalidate`，`skip = dead_skip_f(dead, head_r, winlen)`。Bug B 由此根除：被 flush 的条目不再只在"恰好位于 head 的那一拍"才回收。
  - 关键是 `dead` 必须含 `flush_mask | invalidate`：flush/invalidate 到 posedge 才清 `valid_r`，**组合跳过必须提前把它们算作死**。这一点是单元 TB 的 L7/L8 抓出来的（漏了 `flush_mask` 会多推窗口）。
- **`free_count` 改为组合导出**（`(LSQ_SIZE-1) - winlen + skip`），删掉 `free_count_r` 寄存器 —— 参考实现根本没有这个状态，去掉它消除了一整类状态失步 bug。`cpu_top` 的发射门随之从 `lsq_free_w + n_inv >= n_mem` 改回 `lsq_free_w >= n_mem`（`free_count` 已含本拍失效腾出的槽），并删掉孤立的 `n_inv`/`inv_acc` 链。
- **原"候选 1"（head 多推一格）不成立**：最终版本 head 只加 `skip`，当拍失效的条目已由 `dead` 覆盖，不存在 `flush_skip + |invalidate` 两项相加。
- 验证：`tb_lsq` ALL TESTS PASSED（L1/L2/L7/L8/L9/L10/L15 期望值按新语义更新）；hanoi 提交由 273 解冻到 130151。**但随即暴露 b 形态跑飞** —— 说明 a 与 b 确实不同源（§7.2）。

#### 7.2 修复 2 — 取指失步（b 形态跑飞），commit `a7ce958`

先用探针拿到第一拍：`tb_cpu_prog` 加 `+BAD=<hex>`（pc 首次越界即打印拍号并 `$finish`，省得每次跑到 2M 拍），
`+PROG=hanoi +BAD=8000` 得 `BAD: pc=00008004 > 00008000 at cyc=346498`；按 +4/拍反推失步发生在 cyc≈339K、pc 仍在代码段内（此前 hanoi 的 trace 探针只在"卡死"时有用，跑飞场景要靠 `+BAD` + `+FROM/+TRACE` 回放窗口）。

根因在 `rtl/front/fetch.v`：`pc_r` 是"下一次请求地址"、`exp_pc_r` 是"下一批交付地址"，两者必须同步推进（pc 领先恰好一个批）。到达批被接收时若批内有预测跳转（jal/ret），`exp_pc_r` 跳到该目标，而 `pc_r` 被 `stall` 按在原地 —— 而 `stall=1` 恰是**冲刷期的常态**（`cpu_top`: `fetch_stall = (have_batch && !issue_en) || flushing_r || halt_q_r`），递归程序里"jal 后面紧跟 jal/ret"又极常见，重定向目标正好落在这类地址上。命中即永久失步：`exp_pc` 停在目标不动，`pc` 只做顺序推进，到达地址流再也追不上 `exp_pc` → **pc 每拍 +4W 走进未映射区，commit 冻结**（这正是 §7 表格 b 形态的成因，`magic` 的 `pc=0x7a1b6c` 同源）。

修法：预测跳转 `pc_jmp_w = pred_ok_w && pt_c[ISSUE_WIDTH]` 提到 `stall` 保持之前，**并把 `pc_jmp_w` 纳入 `pc_wr_w`** —— 否则 stall 拍写使能为 0，跳转目标根本写不进 pc。这个漏改是先跑测试才抓到的（实测炸出 417 个用例），不是靠读代码看出来的。`stall` 且到达批无预测跳转时仍保持 pc：那种情况 `exp_pc` 只 +4W，到达地址流下一拍即与之重合，不失步（已写进注释）。

**方法论教训（重要）**：`tb_fetch` 段 2 的 300 拍随机模型对照**不可能**独立发现这类缺陷 —— 模型与 RTL 同源，只验证"等价"而非"正确"。故补了独立期望的定向用例 **F14**（重定向到 `0x300` 的 `jal -16` + `stall=1` + 批寄存器空）：修前 `pc=00000300 / exp=000002f0` 并跑飞，修后 PASS。

#### 7.3 修复后的程序结果

| 程序 | 修复前 | 修复后 |
|---|---|---|
| hanoi | timeout@2M, commit=273（a 形态死锁） | **PASS** ret=20 cycles=326181 commit=130306 |
| statement_test | timeout@2M, commit=780（原判"c 形态：只是慢"） | **PASS** ret=50 cycles=1504 commit=822 |
| multiarray | timeout@2M, commit=772（同上） | **PASS** ret=115 cycles=1901 commit=1289 |
| 前述 9 个 PASS | — | 逐字符不变（cycles/commit/flush/branch 全同，无回归） |

**"c 形态只是慢"这个判读也是错的**：`statement_test`/`multiarray` 的 commit 数在几百就冻住，本就是停滞/失步，修完两处后 1.5~1.9K 拍就跑完了。

**修复后的全量结果（`MEM_LATENCY=3` 功能配置，17/18 已验证）**：naive / gcd / array_test1 / array_test2 /
statement_test / lvalue2 / manyarguments / expr / multiarray / basicopt1 / hanoi / bulgarian / magic /
qsort / queens / superloop / tak 全部 `PASS`，ret 与期望值逐一相符。`pi` 未跑完（其仿真墙钟时间是同批程序的数倍，用户决定本轮先放过，**列为待办**），非缺陷。
（**`pi` 的最终定性见 §10**：harness 的 `MAX_CYCLE` 上限，论证为非缺陷；本节的"待办"已销。）

**§7.4 修复后的 3 拍重型回归（进行中）**：§7.4 改的是发射资源门，理论上 `MEM_LATENCY=3` 下不该有任何
影响（实测全部程序 `block rs=0`）。用**修复后的 RTL** 重跑重型程序确认：

| 程序 | cycles | commit | flush | branch | 与上表 |
|---|---|---|---|---|---|
| basicopt1 | 755464 | 472952 | 45051 | 155139 | 一致 |
| hanoi | 326181 | 130306 | 12830 | 17459 | 一致（cycles/commit 逐位相同） |

其余 6 个（bulgarian/magic/qsort/queens/superloop/tak）跑到 `bulgarian` 时**按用户指示停止后台作业**
（`bulgarian|` 后无结果）—— 即**已确认 2/8，余 6 个未测**。结论：§7.4 的修复在已测的两个重型程序上
确实零影响（这与"3 拍下全部程序 `block rs=0`、该门不可能生效"的推断一致）。

**注意**：这批结果全部是 `MEM_LATENCY=3` 下的。按 description.md，性能档要求内存延迟 20 拍 ——
换到 20 拍后立刻炸出**第三个独立缺陷**（§7.4），说明"功能配置下全过"并不等于"性能配置下可用"。

**本节数字的时间戳**：以上（含 §7.3 的两张表）都是 **§8.2 的 LSQ 修复与 §8.3 的计数器口径修复之前**
的实测值。修复后重跑同一批程序，**`ret` 全部不变**（判据不变），但特征量有变化：`basicopt1`
755464 → **755408** 拍、`hanoi` 326181 → **260887** 拍、`p2_vecadd` 224 → **213** 拍。
（未逐条归因；§8.2 去掉无用的重复发起、§8.3 让计数器在 halt 后冻结，两者都会动这些数。）
**当前值以 §10 与「当前状态」的表格为准**，本节保留为当时的现场记录。

#### 7.4 缺陷 3 — RS push 被静默丢弃（性能档 `MEM_LATENCY=20` 下死锁）

**发现路径**：按用户要求先把延迟切到性能档要求的 20 拍。`multiarray` 立刻挂死（commit 冻结在 411、
pc=0x1158，`+BAD` 未响 ⇒ 是停滞不是跑飞）。二分延迟：`MEM_LATENCY=3` 过，**4 就挂**；且 `MEM_INFLIGHT`
取 4/8/16 全部复现 ⇒ **与访存吞吐无关**，是纯粹的时序巧合（4 又正是 `CNTW` 从 2 位涨到 3 位的点，但
`rtl/core/memory.v` 的倒计时本身经查无误）。

**定位**（探针全在 TB 侧，不改 DUT）：停滞归因给出 `block rs=19319/20000`（RS 满且一条都发不出去）。
再加"ROB 头任期就绪历史"探针得 `head_ever_ready=0 in_rs=0 in_lsq=0`：ROB 头（`00279793` = `addi x15,x15,2`）
**从未完成过**，且既不在 RS 也不在 LSQ。ROB 窗口 dump 确认依赖链：`ROB[7].rdy=0`，而 `RS[2].prs1=39 rdy1=0`
等的正是 rob=7 的 prd（p39）—— 一条纯 ALU 指令，其唯一完成通路是 CDB 回写。

**根因**：`cpu_top.v` 的发射资源门把"本拍正被选中、即将腾出的 RS 槽"算作可用：

```verilog
wire resources_ok = !rob_full && (rs_free_w + sel_cnt >= ISSUE_WIDTH) && ...
```

但 `rs.v` 的 push 分配器（`prec` / `cand_p` / `pvalid_w`）**只认 `!valid_r`，看不到本拍 clear**
（`clear` 在 posedge 才生效）。于是当 `rs_free_w == 0 && sel_cnt == 1` 时：门放行 → `issue_en=1` →
`push_valid=1`，而 `pvalid_w=0` → `rs.v` 的 `if (push_valid[k2] && pvalid_w[k2])` **静默丢弃这次 push**。

后果比"少发一条"严重得多：指令已经进了 ROB，RAT / free_list / 架构映射**都已按发射更新**，只有 RS
条目没落地 ⇒ 该指令永不执行 ⇒ 其 prd 永不置 ready ⇒ 依赖它的整条链全挂 ⇒ RS 灌满且无可选条目
⇒ `sel_cnt` 归零 ⇒ 死锁（`sel_cnt` 归零后连"下拍补上"都不可能）。

**为什么在 3 拍潜伏**：触发需要"RS 恰好全满 + 本拍恰有选中"这一拍级巧合，访存延迟一改，指令流的
时序整体平移就撞上了。这也解释了为什么它在 18 个程序 × 3 拍的回归里一次都没出现。

**同族排查**（其余三个门都是严格式，只有 rs 项不是）：

| 门 | 模块侧口径 | 结论 |
|---|---|---|
| `!rob_full` | `free_r == 0` | `ISSUE_WIDTH=1` 下正确（≥1 槽）；**W>1 时只保证 1 槽，需 ≥W，列为多发射待办** |
| `fl_count >= n_wr` | `free_list`：`count_out = sp`，注释明确"本拍 push 的项本拍不可分配(无旁路)" | 严格，正确 |
| `lsq_free_w >= n_mem` | `lsq.v`：`dead = ~valid_r \| flush_mask \| invalidate` + `free_count_w` 同为 dead-aware | 严格，正确 |
| `rs_free_w >= ISSUE_WIDTH` | `rs.v`：`prec`/`cand_p` 只看 `!valid_r` | **修复后一致** |

**修法**（最小、可证安全）：rs 项改用真空闲槽数 `rs_free_w >= ISSUE_WIDTH`。`free_count` 是 `!valid_r`
的计数，`pvalid_w[gk]` 的候选数恰等于它，故"门放行 ⟹ 必有槽可分配"，push 不再可能被丢。代价是 RS
恰好满时最多迟一拍发射 —— 而实测 RS 从来不是瓶颈（`MEM_LATENCY=3` 全部 18 程序 `block rs=0`）。

**验证**：lat=3 下 9 个快程序 `cycles/commit/flush/branch` 与修前**逐位相同**（multiarray 1901/1289/32/162）；
lat=4 与 lat=20（`MEM_INFLIGHT` 4/8/16/20/32）下 multiarray / statement_test / expr / gcd 全部 `PASS`。

**仍未排除 / 当前卡点（已全部关闭，保留备查）**：

- 忠实照 C++ 语义改出的版本（`/tmp/fix/rtl/core/lsq.v`：`flush_skip = flush_skip_f(~valid_r, head_r, winlen)` + `free_count_r <= (LSQ_SIZE - 1)` 复位）**能编译、能过单元 TB，但 `hanoi` 从"卡在 pc=0000103c"变成 `pc=xxxxxxxx (commit=x)`** —— 出现 X 传播。这堵住了整条路。
- **候选 1：补丁细节错**。`cpu_top.v:551` 的 `inv_one` 只由 `ce_w[c] && is_memop_w[c]` 产生，**没有按 `lsq_valid_w[cmt_lsq_tag]` 门控**。我的补丁把 `head_r <= head_r + flush_skip + (|invalidate)` 写成两项相加：`flush_skip` 数的是"洞"，`|invalidate` 数的是"当拍提交"；**若两者命中同一条目就会把 head 多推一格，丢掉一条活条目**，随后 `free_count` 多算、窗口错位。这是最可疑的一处，应当先查。
- **候选 2：被掩盖的另一个 bug**。修好 LSQ 后 hanoi 第一次能跑过原来的死锁点，可能撞上此前根本到不了的代码路径上的缺陷；X 的来源可能是 PRF 读到从未写过的物理寄存器、或分支/访存前向路径。若如此，这正是 b 形态（`magic` 跑飞）的同源问题。
- **候选 3：X 根本不来自 LSQ**（尚未做任何排除）。
- **候选 4：那 7 个"c 形态"程序**（commit 数很大）是不是同一个 bug，**完全没查**。它们可能只是 2M 拍不够（那就该先量一下它们的 IPC 是否正常），也可能是另一类缺陷。

**下一步（探针已备好、尚未执行）** → **已执行**：探针没按原计划加在 `/tmp/fix/tb_dbg.v`，而是直接落在 `tb/top/tb_cpu_prog.v`（`+BAD=<hex>` 越界即报第一拍并结束；`+FROM/+TRACE` 回放窗口）。hanoi 用它拿到 cyc=346498 越界，比原计划的"X 或越界"更省事，也不再需要跑到 2M 拍。

**优先级建议** → **复盘**：这条判断对了一半。a/b 形态确实不同源（§7.1 修完 LSQ 后 hanoi 立刻从"死锁"变成"跑飞"），但"先用 `magic` 复现跑飞"这一步**没必要** —— 修完 LSQ 的 hanoi 自己就成了 b 形态的最小复现，且在 hanoi 上取第一拍比在 `magic`（2M 拍级别）上快得多。教训：**同一程序修掉一层缺陷后暴露的下一层，往往是更新鲜、更便宜的复现**，不必执着于"最初的见证者"。

### 8. 性能配置（`MEM_LATENCY=20`）实测：瓶颈归因 + 新缺陷 `queens`

**方法与其局限（先说清楚）**。为省墙钟时间用了 `+PERF=N`：跑满 N 拍即报 IPC，**不看 ret、不判对错**，
窗口取前 20 万拍。所以它既不是全程序 IPC，也不验证正确性 —— 凡要判对错的必须去掉 `+PERF` 跑完。
（`MAX_CYCLE` 已提成 `parameter` 以便按需放大超时上限：默认 200 万拍对 20 拍配置偏小，
`magic` 在 3 拍下就已 81.9 万拍。）

**首 20 万拍窗口，`MEM_LATENCY=20` / `MEM_INFLIGHT=16`**（IPC 由 `commit/cyc` 现算）：

| 程序 | commit | IPC | flush | branch |
|---|---|---|---|---|
| superloop | 146508 | **0.732** | 8129 | 131148 |
| basicopt1 | 126977 | **0.634** | 10808 | 42440 |
| qsort | 109969 | **0.550** | 4 | 19995 |
| bulgarian | 38469 | 0.192 | 3280 | 8772 |
| magic | 36044 | 0.180 | 1652 | 6710 |
| hanoi | 25799 | 0.128 | 2801 | 3449 |

三档门槛（**当时的口径** 0.6000 / 0.7800 / 1.0140；现行档 2/档 3 已改为 0.8450 / 1.0985，
档 1 未变。单发射上限即 1.0）。**三个在线下，hanoi 差 4.7 倍。**
> 这组数字的量测延迟是 20 拍（**已作废的口径**），仅作纵向对照，**不能当作评测基线**。

**延迟敏感度（3 拍 vs 20 拍）**。有全程序 3 拍数据的两个程序：

| 程序 | 3 拍（全程序） | 20 拍（首 20 万拍窗口） | 倍数 |
|---|---|---|---|
| hanoi | 130306 / 326181 = **0.399** | 0.128 | **3.1×** |
| basicopt1 | 472952 / 755464 = **0.626** | 0.634 | 1.0×（不敏感） |

hanoi 的 3 拍窗口值与全程序值同为 0.399（见 `PERF: hanoi m3` 那行），说明对该程序窗口有代表性。
**同一台机器、同一个程序，只因访存延迟从 3 变 20，IPC 掉到 1/3** —— 且 §8 的归因说明这不是
"等内存"，而是**物理寄存器容量被长延迟钉死后发射停摆**。basicopt1 则几乎不受影响（它访存少）。

**hanoi 的停滞归因**（同一 20 万拍窗口；TB 侧每拍采样，不改 DUT、不进综合面积）：

```
lat=3 : issue=125778 nobatch=24089 flushcyc=48922 misp=7857 | block rob=0  rs=0     fl=1211  lsq=130
lat=20: issue=60260  nobatch=11906 flushcyc=35921 misp=2801 | block rob=12 rs=28340 fl=88291 lsq=6600
```

**20 拍下的主因是 `fl`：free_list 无空闲物理寄存器，挡了 88291 拍（窗口的 44%）**；`rs` 次之（28340 拍）。
3 拍时这两项几乎为 0。也就是说 hanoi 在性能配置下既不是被访存带宽拖住、也不是被分支预测拖住，
而是**发射被自己的物理寄存器容量掐死**。

**为什么自由表会枯竭：余量是 0，不是"不太够"**。`free_list.v` 里 `BASE = 32`（preg 0..31 恒等映射、
永不复用），故空闲池 `FREE_NUM = PRF_SIZE - 32 = 32`；而 `ROB_SIZE` 也是 32 —— **空闲池恰好等于
ROB 能同时压住的待写指令数，一点余量都没有**。3 拍时提交快、preg 回收及时，看不出问题；20 拍时
长延迟把 ROB 灌满并长时间钉住 preg → 池空 → 发射停摆 → ROB 更退不动（正反馈）。
这不是配置写错，是**参数配比**：要让 `fl` 门不成为瓶颈，需要 `PRF_SIZE - 32 > ROB_SIZE`。
→ 优化候选第 1 项（**但按用户指示，先确认正确性再谈优化**）。

**同窗口的前端预测质量**（`JUMP` 行：TB 侧按 `raw` 指令编码分 bin，纯诊断、不进面积）：

| 类别 | lat=3 被预测取 | lat=3 误预测 | lat=20 被预测取 | lat=20 误预测 |
|---|---|---|---|---|
| jal | 4170 | 0 | 2580 | 0 |
| **ret** | 4799 | **3698** | 3153 | 1459 |
| beq | 419 | 392 | 151 | 127 |
| **bne** | 10047 | **3767** | 34442 | 1215 |
| jalr | 0 | 0 | 0 | 0 |

（两项计数的分母不完全一致：被预测取的 ret 一定计入左列，被预测不取却实际跳了的 ret 只计入右列，
故 **ret 误预测率介于 43%~77%**，无论取哪端都说明返回预测极不准。lat=20 列也不要与 lat=3 列比
绝对值 —— 同一窗口内完成的指令数差 3 倍。）

`ret` 与 `bne` 是前端两大失分项，各自对应一个**已知的结构性偏小**：返回地址栈有效深度只有
`RAS_SIZE-1 = 7`（`architecture.md` 已记：head 宽度受恢复通路限制），`BHT_SIZE=32` 是直接映射表。
消融矩阵里的 `RAS{4,8,32}` 与 `BHT{16,32,128}` 两行正是为此设的（`RAS_SIZE` 无法取 0，见 §"消融 + 综合"）。

**新缺陷一：`queens` 在 20 拍下算错**

```
FAIL: queens ret=7 exp=171 cycles=110575 commit=13989 flush=2244      (lat=20, inf=16)
```

**不是超时**：程序跑完并 halt 了（110575 拍），只是答案是错的。同一程序在 `MEM_LATENCY=3` 下
PASS，3 拍的整批回归里从未出问题。与 §7.4 同属"只在特定时序下暴露"，但表现不同
（§7.4 是死锁，这里是算错 → 更像某条路径在长延迟下取到了陈旧或错误的值）。

**新缺陷二：`tak` 在 20 拍下出现 X 传播**

```
PERF: tak cycles=200000 commit=x ipc=x.00x flush=29 branch=51          (lat=20, inf=16)
```

`commit_count` 本身变成了 `x` —— 这不是"慢"，是**状态里真的出现了未知值**（读到了从未写过的
寄存器，或某条路径在长延迟下取到了不定态）。旁证：20 万拍里只做了 **51 次分支、29 次冲刷**，
即它几乎立刻就走不动了。tak 在 3 拍下 PASS。

**这两个是当前最高优先级**（正确性优先于一切性能工作），归因见 §8.1。

### 8.2 `queens` / `tak` 根因**已定**：LSQ 重复发起 → 槽位复用 → 陈旧完成写坏目的寄存器【已修复】

**根因（两个独立缺陷叠加，都在访存返回通路）**

**缺陷 A — `lsq.v` 的 load 可重复发起（主因）**

`cand[gd]` 的抑制条件只有 `!done_r[idx]`，而 `done_r` 只在**完成脉冲回来**时才置位。
于是从发起到完成之间的整个 `MEM_LATENCY` 窗口里，同一个 load **每拍都被重新发起一次**，
灌满全部 `MEM_INFLIGHT` 个飞行槽，之后产生**一串**完成脉冲。

探针实测（`tak`，lat=20，inf=16）：LSQ 条目 14 在 T1885 起**连续发起 18 次**，随后
**连续回 18 个完成脉冲**（`LDDN idx=14`），而正确的语义是各 1 次。

**缺陷 B — 完成脉冲按"条目号"识别请求，但条目号会被复用（致命放大）**

`load_cdb_prd` 是**组合**读 `prs2_or_prd_r[mem_done_idx]`（完成当拍才取值），
而 `ld_ok` 只检查 `valid_r[idx] && is_load_r[idx]`，**不检查这条完成对应的是哪个请求**。
一旦该条目被提交失效（`invalidate`）并**被新 load 复用**，余下的陈旧完成脉冲就会把
**旧 load 的数据**写进**新 load 的目的物理寄存器**。

实测的完整链条（`tak`）：
1. 条目 14 = `lw` 到 `preg 40`（rob 19），`addr=0x1fc24`，在飞 18 份。
2. T29075 第一个完成回来 → `done_r[14]=1`，CDB 写 `preg 40 = 0x00000002`（**正确**）。
3. ROB 19 因此就绪 → 提交 → `invalidate[14]` → `valid_r[14]=0` → head 跳过 → **槽位被新 load 复用**，
   新条目 `prs2_or_prd_r[14] = 41`（= `ra`）。
4. T29195 起，剩余 17 个陈旧完成陆续回来，`ld_ok` 因 `valid_r[14]=1`（**新条目**）而成立，
   于是 `preg 41 ← 0x00000002`（**旧数据**）。
5. 0x1088 的 `ret` 读到 `prs1=41`（`ra`）已就绪 → `br_target = 0x00000002` → 重定向 → pc 跳到 0x2
   → 在 0 填充区里每拍 +4 走到 `MEM_SIZE` 之外 → 越界读 → `x` 传播。

⇒ **plan.md 原先"`tak` 出现 X 传播"是误判**：X 是**后果**，第一现场是物理寄存器 41 被写坏。
`inf=4`/`inf=16` 都出 X 也由此解释：与飞行槽数量无关，只与"重复发起 × 延迟窗口"有关 ——
**延迟越长，陈旧完成落在复用条目上的窗口越宽**，所以只在 lat=20 暴露。

**顺带审查过、但确认不是缺陷的一处（记录以免日后重复怀疑）**

`memory.v` 的 `ld_done_valid_r` 是在**逐槽 for 循环里**赋值的，同拍多个槽到期时只有最后一次
生效、其余完成会永久丢失 —— 看着像缺陷，**但在当前接口下不可达**：
`ld_start_valid` 是**单比特**口，每拍只武装一个槽；定长 `MEM_LATENCY` 下"武装拍互不相同"⇒
"到期拍必然错开"⇒ 每拍至多一个槽到期。（曾按"修 A 后丢完成 = 永久挂死"的理由加过一套
仲裁逻辑，复核后判定属于**为不可达场景加防御**，按项目风格已回退，改为在该处写明这条不变量。
若将来改成多 load 口，此处必须一并重做。）

**修复**

| 文件 | 改动 |
|---|---|
| `rtl/core/lsq.v` | 新增 `issued_r`（在飞标志）：发起置位、完成清位。`cand` 加 `!issued_r` 与 `!kill`；`dead` 加 `& ~issued_r`；新增 `kill = flush_mask \| invalidate` |
| `rtl/core/lsq.v` | 组合发起链整体上移到 posedge 块之前（iverilog 要求先声明后使用） |
| `rtl/core/memory.v` | **仅注释**：写明"每拍至多一个槽到期"这条不变量（无逻辑改动 ⇒ 面积不变） |

`issued_r` 把"条目号 → 请求"重新变回一一对应，这是完成通路正确性的前提：

- `cand` 排除在飞条目 ⇒ **一个 load 只进一个飞行槽**（灭缺陷 A）。
- `dead` 排除在飞条目 ⇒ 被 flush/失效的在飞条目**不被跳过**，槽位在完成回来前**不可复用**
  ⇒ 完成当拍读到的 `prs2_or_prd_r` / `addr_r` / `width_r` / `rob_tag_r` 必然还是原请求的（灭缺陷 B）。
  代价：flush 时若恰有在飞 load，head 最多阻塞 `MEM_LATENCY` 拍（飞行槽必定倒计时到期，不会死锁）。
- `cand` 再加 `!kill`（本拍就被 flush/失效的条目不发起）：否则 `issued` 与 `valid` **同拍**翻转，
  而 head 的 `skip` 用的仍是边沿前的 `issued=0` ⇒ 条目照样被跳过、槽位照样被复用，身份又丢了。

**单元测试（先复现再修）**

`tb/core/tb_lsq.v` 的参考模型同步加入 `m_issued`（`calc_cand` 在边沿前后各算一次：
边沿前算的用于决定"本拍发起是否被接受"，边沿后算的作为 `ld_start_valid` 的期望值），并新增：

- **L3c/L3d/L3e**：发起被接收后进入 in-flight ⇒ **不得重复发起**；完成回来后清 in-flight。
  （旧断言 `L3c re-issue after busy` 期望"忙解除后重新发起"，正是把缺陷 A 当成契约写进了测试。）
- **L16**：在飞条目被 flush ⇒ head **不跳过**（`free_count` 相应减少）；陈旧完成**不写 CDB**；
  完成回来后 head 才放行。
- **L17**：发起与 flush 同拍 ⇒ **不得发起**（覆盖上面 `!kill` 那条边）。

**性能侧影响（待实测）**：修掉重复发起会**减少**无用的飞行槽占用（利好），
但 flush 撞上在飞 load 时 head 会短暂阻塞（利空）。两者都要在 §7.3 的 3 拍回归与
20 拍 IPC 上复测后才好下结论。

**验证**

| 项目 | 结果 |
|---|---|
| `tb_lsq` 小规模+极端 + 300 拍随机模型对照 | **ALL TESTS PASSED** |
| 全部 12 个单元 TB（`make`） | **ALL TESTS PASSED**（无回归） |
| `queens` lat=3 | **PASS** ret=171 cycles=730406 commit=422018 |
| `tak` lat=3 | **PASS** ret=186 cycles=1654514 commit=1365221 |
| `gcd` lat=3 修复前/后 | 726 拍 / 364 提交 → **722 拍 / 362 提交**（略快，非回归） |

`gcd` 的提交数少 2 属于既有已知瑕疵（§4：错路条目偶尔仍会被提交），修复后错路工作量减少 ⇒ 反而更接近正确值。

**面积代价**：`lsq.v` 新增 `LSQ_SIZE` 位 `issued_r`（默认 16 个触发器）+ `cand`/`dead` 各多一级与门。
`memory.v` **无逻辑改动**（仅注释）。需在 §"消融 + 综合" 里复测综合面积。

### 8.3 提交计数口径修正（commit `0299197`）

**问题**：`commit_count` 把 halt 标记**之后**的 ROB 排空也算进去了。

`rtl/top/cpu_top.v` 三处事实合起来导致：提交使能 `ce_w[0]`（`:541`）**没有** halt 门控，
而发射被门控（`issue_en`，`:371`）；同时 `ret_sample`（`:607`）必须等 `rob_empty` 才采样返回值。
于是 halt 抬起后，标记**后面**的条目仍继续提交并累加，多出 ≤ `ROB_SIZE`=32 条，
且随 halt 时刻的 ROB 占用浮动。实测 `naive` 真值 **18** 条（由 `naive.dump` 手工推演）
被记成 **27** 条，27 = 18 + 9（标记后方 rob 内的条目数）。

**修法**：三个计数器（commit/flush/branch）一律在 `halt_q_r` 抬起后冻结，与 TB 侧
STALL/JUMP 的采样窗口（`tb_cpu_prog.v` 的 `rst_n && !dut.halt_q_r`）对齐，
使 PASS 行与 STALL/JUMP 行描述同一个窗口。

**影响面：就 IPC 而言为零。** 三个计数器是**纯输出**（`:23` 声明 output、`:646-648` 赋值、
RTL 内无处读取），且 `+PERF=N` 是定拍窗口模式 —— lat=20 下 tak/queens/hanoi 在 20 万拍
窗口内 `halt_q_r` 根本不抬起，计数器行为**逐拍不变**。故 §8 的全部 IPC 数字**无需重测**。

| 验证项（lat=3） | 结果 |
|---|---|
| `naive` | 27 → **18**（= `.dump` 推演真值） |
| `gcd` | 362 → **361**（ROB 近空，符合预期） |
| `array_test1` | 145 → **138** |
| `hanoi` | 130221 → **130220** |

**独立 ISS：已放弃，记录结论。** 曾写过一个不依赖任何 RTL 代码的 RV32IM 模拟器作第四方
oracle。它复现了 20 个程序中 **19 个**的 TB 期望 `ret`，但在 `expr` 上给出 136，
而其余三方一致为 **58**（`expr.c:116` 源码注释、参考模拟器 `./build/code < expr.data`
的输出、以及本 RTL）。即 **ISS 自身有 expr 才触发的 bug**，与 RTL 无关。因正确性判据
（`ret`）已由"源码注释 + 参考模拟器 + RTL"三方一致支撑，ISS 无必要性 ——
留一个已知会错的 oracle 比没有更危险，故已删除，不在其上继续投入。

**遗留（记录在案，不追）**：§8.2 提到"错路条目偶尔仍被提交"（§4）这条既有瑕疵
**本轮未被独立证伪**。`hanoi` 在 lat=3 下修复前/后提交数差 **85 条**
（130306 / 130221），**超过 `ROB_SIZE`=32，排空解释不了** —— 说明两版的执行流确有差异。
当前判断：修复前那版可能因陈旧完成写坏中间值而使控制流走了不同路径（两版 `ret` 都是 20，
故未被结果暴露）。提交数不是正确性判据，不进一步追查。

### 8.1 `queens` / `tak` 归因【已定，见 §8.2】

**已观测**：

| 程序 | 配置 | 结果 |
|---|---|---|
| queens | lat=20, inf=16 | FAIL ret=7 exp=171, cycles=110575 |
| tak | lat=20, inf=16 | `commit=x` flush=29 branch=51 |
| **tak** | **lat=20, inf=4** | **`commit=x` flush=26 branch=57** |
| tak / queens | lat=3 | PASS（§7.3） |

**`tak` 在 `inf=4` 与 `inf=16` 下都出 X** ⇒ 与 `MEM_INFLIGHT` 无关，只跟 `MEM_LATENCY=20` 有关。
（`MEM_INFLIGHT` 是**本设计的**参数、非评测规定；它被排除后，嫌疑集中在延迟相关的时序假设上。）

**复现状态：已定案，结论见 §8.2。** 两个症状同源 —— LSQ 的 load **重复发起** + 槽位复用导致
**陈旧完成写坏目的寄存器**，且只在长延迟下暴露。修复后同窗口（lat=20、inf=16、20 万拍）复测：
`tak` 由 `commit=x / branch=51` 变为 **`commit=95850 / branch=4320`** ⇒ **X 传播这一失败模式被证伪**；
`queens` 的完整判词**未取**（单程序墙钟代价大，用户决定不跑）。本节保留为当时的现场记录。

**为什么值得优先**：这是**正确性**问题，而用户的口径是"先确保程序正确性，再谈优化"。
且它只在性能配置下暴露 → 若性能档评测（`MEM_LATENCY=20`）下算错，IPC 再高也无意义。

**当时列的排查方向 → 事后复盘**（三条，按 §7 已验证的方法论）：

1. **配置相关性**（已实测）：`tak` 在 `inf=4` 与 `inf=16` 下**都**出 X ⇒ 只与 `MEM_LATENCY` 有关，
   与 `MEM_INFLIGHT` 无关。这条排除干净了，后面的方向才对得准。
2. **"X 会传播、可顺藤摸瓜"**（**没用上**）：最后不是追 X，而是靠 §8.2 的 `+TRACE` 探针直接看到
   "同一 LSQ 条目连续发起 18 次"定位的 —— 比回放 X 快得多。
3. **"与前向/失效路径的取值时机有关，窗口随延迟变宽"**（**命中了**）：根因确在 LSQ 的发起/完成握手，
   且正是"延迟越长，陈旧完成落在**复用槽位**上的窗口越宽"这一类。

**教训**：同时出现"只在长延迟下犯"+"与访存有关"两个特征时，**先查 LSQ 的发起/完成握手**；
且**症状更刺眼的那个（X 传播）不一定是更好的入口**，能被探针直接观测到的时序事实才是。

### 9. Benchmark 接入（真正的 IPC 评测口径）

**用户已把评测仓库放入 `CPU-2026-Benchmark/`**（`ACMClassCourse-2025/CPU-2026-Benchmark`，自带
`.git` 的克隆）。**入库方式已定：不入库、只留本地**（已加进 `.gitignore`；评测口径引用的是上游仓库，
本地副本仅作编译输入）。6 个 workload：`median` / `multiply` / `qsort` / `rsort` / `towers` / `vvadd`。

**必须分清两个集合**：本仓库 `tb/top/prog/` 的 18 个 CPU-Simulator 程序是**功能验证集**（有确定的
`ret` 期望值，能判对错）；`CPU-2026-Benchmark` 才是 **IPC 评测口径**（description.md 指定）。
此前用 `+PERF` 在 18 个程序上量 IPC 只是内部对照，报告里必须写明这层口径差异。

**已勘察到的接入障碍**（`common/` 是轻量头，`common.original/` 是原始裸机支持文件）：

| 障碍 | 具体情况 | 处理方向 |
|---|---|---|
| 工具链 | 本机 `~/opt/riscv64-unknown-elf-gcc`（GCC 8.3.0）**支持 rv32im/ilp32 多库** | 可用；Makefile 默认的 `-march=RV64IMAFDXhwacha` 必须改成 `-march=rv32im -mabi=ilp32` |
| 启动代码 | `crt0.S` 用 `csrw mtvec`/`csrs mstatus`/`csrr misa`/`csrr mhartid` —— **CSR\* 本 ISA 明确不含** | 必须自写 crt0（置 sp → `call main` → 执行停机指令），不能用原文件 |
| 链接地址 | `test.ld` 把 `.text.init` 放 `0x80000000` | 按本仓库 TB 约定改到 `0x1000`（栈 `0x20000`、停机 `0x30004`） |
| 终止/判对 | 原始流程走 `tohost` MMIO + newlib `_init` | 用本 CPU 既有约定：`main` 返回值留在 a0，末尾 `addi a0,x0,255` 触发 halt；`common/util.h` 的 `verify()` 已保证"返回 0 = 通过" |
| `rsort` | 大量 `__sync_fetch_and_add`（**A 扩展**，本 ISA 不含） | 需单线程等价替换或确认 libatomic 可用 |
| 数据规模 | 最大 `DATA_SIZE=2048`（qsort/rsort，8KB/数组）；`towers` 无数据集（`NUM_DISCS=7`） | `MEM_SIZE=262144` 够用 |
| 镜像格式 | TB 用 `$readmemh` 的 `@地址` + 16 字节/行（源自 C++ 模拟器格式） | 需写 ELF→`.data` 转换脚本（`objcopy -O binary` 后按段地址打包） |

**计划**：① 自写 crt0 + 链接脚本 → ② ELF→`.data` 转换脚本 → ③ TB/Makefile 接入 →
④ 先在 `MEM_LATENCY=3` 下跑通 6 个 workload 并判对错 → ⑤ 再在 20 拍下量 IPC。

> ### ⚠ 本节整节**已作废**（2026-09-24，口径换官方最终版之后）
> 官方 `testcases/perf_*` 直接提供**预编译好的 `program.data` 镜像**（装载地址 0），
> 于是：crt0/链接脚本/ELF→`.data` 转换脚本**都不需要写**（①②），TB 侧也不再是"接入自建镜像"
> 而是走框架的 `make perf`（③）；`rsort` 的 `__sync_fetch_and_add` 也不再是障碍
> —— 那是 `CPU-2026-Benchmark` **源码树**特有的（官方镜像已完成编译）。
> 延迟也不再分 3/20 拍两档（④⑤ 的二分法消失）。
> **本节保留的价值**是 §12.1 里那批"上游构建系统已损坏"的勘察结论 —— 它解释了**为什么当初以为要自建**。

### 10. lat=3 全量回归：18 个程序的完整判词（2026-09-19）

**这是"功能正确性"的主证据**（description.md 的**仿真程序阶段，85 分**；本仓库的 18 个程序即该阶段
的判据集）。**判据只有一条：`ret` 等于期望值** —— 提交数/冲刷数/拍数都只是特征量，不是判据。

**范围与边界**（说清楚这次回归**没有**覆盖什么）：

| 覆盖 | 未覆盖（及原因） |
|---|---|
| `tb/top/prog/` 中 **18 个带 `ret` 期望值**的程序 | `loopjal`/`loopld`：**无终止指令**，跑不到判词，只配 `+PERF` 作性能微负载 |
| `MEM_LATENCY=3`（description.md 的**功能**配置） | `MEM_LATENCY=20`（性能配置）：本轮**搁置**，见 §8 与"当前状态" |
| 单发射 `ISSUE_WIDTH=1`（唯一已实现的配置） | 多发射 W>1：结构参数化已就位但未实现 |
| 全核 + 12 个单元 TB（`make`，退出码 0） | `CPU-2026-Benchmark` 的 6 个 workload：**全新正确性面**，见 §9 |

> **本节记录的是 Icarus 那一轮（2026-09-19 早些时候）**。当时 `pi` 无判词（harness 上限）。
> 表内 `pi` 一行已按 §11.4 的 Verilator 判词补全；**其余 17 个程序的数字未变**
> —— §11.3 已用 Verilator 逐字段复验过（16 个完全一致，`tak` 仅提交差 1）。

**复现方法**（TB 一次只跑一个程序，全量需外部循环）：

```bash
SRCS=$(ls rtl/*/*.v)
iverilog -g2005 -s tb_cpu_prog -o /tmp/all.vvp tb/top/tb_cpu_prog.v $SRCS
for p in naive gcd array_test1 array_test2 statement_test lvalue2 manyarguments expr \
         multiarray hanoi bulgarian basicopt1 magic queens superloop qsort pi tak; do
  vvp -N /tmp/all.vvp +PROG=$p | grep -E "^(PASS|FAIL):"
done
```

**⚠ 绝不能带 `+PERF`** —— 定拍窗口模式与判对错互斥（§5 已记；本次误加过一次，白跑一轮）。
也可用 `make run TB=top/tb_cpu_prog ARGS="+PROG=<名>"`（注意 `make wave` **不传 ARGS**）。

**结果**：完整表格在本文档开头的「当前状态」；本节只记**结论与口径**。

**这批评词对应的 RTL**：commit `0299197`（统计计数器 halt 后冻结）。此后 `rtl/` 与 `tb/` 的
**唯一改动**是 §11.1 的两处 generate 标签重命名（`rs.v` 的 `begin : bit` → `begin : bg`，
**纯标签、无语义/面积/时序影响**，且全仓库无任何层次化引用到它）—— 除此之外只有文档提交，
故该 commit 的 RTL 即本文档所描述的正确性状态。

- **17 个 PASS**，`ret` 与 `tb_cpu_prog.v` 的 `exp_ret_f` 表**逐条相符**；结论与 §7.3 的既有记录一致。
- **`pi` 当时未取判词**（本节记录的是 Icarus 那一轮），**不是缺陷、是 harness 上限**：
  它在 `MAX_CYCLE`=2000000 拍时 `commit=1210197` 且**仍在推进**，`pc=000011f8` 落在代码段内（不是跑飞）。
  按 §7 的三形态分类属 **c 形态（只是慢/未定）**，既非 a 真死锁、也非 b 跑飞。
  **该定性已于 §11.4 被实测判词证实**：接入 Verilator 后 `pi` 跑完，**`ret=137`（符合期望）**、
  154,707,280 拍、墙钟 183 s（Icarus 等效 36.3 h）。**18 个程序现全部有判词。**

**墙钟代价（单核串行，供排期参考）**：多数程序 <1 s；长尾是 **qsort 1727 s / pi 1691 s /
tak ≈1950 s**，其余重型程序 288~824 s。全量串行 ≈2.6 h。用 `xargs -P4` 并行跑长尾程序可压到
≈35 min（本轮的实测做法；短程序先串行跑完）。**注意 vvp 是单线程的，并行才有意义，且并发写同一
日志文件会截断行** —— 每个作业写自己的文件。

**已知瑕疵（记录在案，不追）**：

| 瑕疵 | 说明 | 为什么不追 |
|---|---|---|
| halt 标记**之后**的条目仍会提交 | `ce_w[0]` 无 `halt_q_r` 门控（`cpu_top.v:541`）⇒ RAT/free_list 会被标记后的指令改动、store 真的写内存 | 18 个程序的标记后代码都不写 a0，故不暴露；修它要同时改 `ret_sample` 采样时机（`:607`），有行为风险，且与 IPC 无关（§8.3） |
| "错路条目偶尔仍会被提交"（§4） | `hanoi` 修复前后提交数差 85 条 > `ROB_SIZE`=32，排空解释不了 | **提交数不是正确性判据**（判据是 `ret`，两版都是 20）；判断是修复前陈旧完成写坏中间值导致走了不同路径（§8.3） |

**结论**：**`MEM_LATENCY=3` 下功能正确性成立**，18 个程序中 17 个有直接判词、1 个（`pi`）经论证
归因于 harness 拍数上限而非缺陷。**description.md 的两个阶段中，"仿真程序"阶段（85 分）的功能
基础已具备**；剩余的正确性缺口是**新面**（benchmark 6 个 workload，§9），不是已知缺陷。

### 11. Verilator 仿真链路接入（2026-09-19）—— 解决 `pi` 跑不完

**动机**：`docs/description.md` §评分标准与时间安排 · 2. 性能 规定「**IPC：使用 Verilator 仿真测量实际运行周期**」，
但本仓库此前**只有 Icarus（`iverilog`/`vvp`）一条链路**，Verilator 从未接入。
后果有两层：① `pi` 因 Icarus 太慢（≈0.845 ms/拍 × 1.547 亿拍 = **36 小时**）取不到判词；
② §9 的 benchmark 接入（IPC 正赛口径）**没有测量手段**。
本轮**只接工具链，不动任何 RTL 架构**。

#### 11.1 Spike 结论（先实测再动代码）

按计划先做 spike，结论**推翻了计划里的主要假设**：

| 预判 | 实测 |
|---|---|
| 最可能卡在 TB 的**层次化写子模块数组**（`tb_cpu_prog.v:200-202` 的 `dut.u_mem.mem[mi] = 8'h00`） | **不成立** —— Verilator 完全支持，`$readmemh` + 运行期 `$sformatf` 文件名 + `$value$plusargs` 也一并可用 |
| 为此要在 `memory.v` 加 `+INIT=` 运行期装载路径（计划步骤 1） | **不需要，已取消** ⇒ `rtl/core/memory.v` **一字未改**，面积无影响（V5 自动满足） |
| `$stop` 在 Verilator 下可能不给非零退出码 | 实测**给 1**，与 `vvp -N` 一致 ⇒ Makefile 无需额外 grep 判据 |
| 会撞上系统任务不支持 | **撞上一个真问题**（见下） |

**唯一真实的阻塞：`bit` 是 SystemVerilog 关键字。** `rtl/core/rs.v` 有两处 generate 块
`begin : bit`（`:156`、`:173`），Icarus 用 `-g2005` 接受，Verilator 直接报
`%Error: syntax error, unexpected bit`。**改法是纯标签重命名 `bit` → `bg`**：已确认全仓库
**没有任何层次化引用**到 `.bit`，故**无语义、无面积、无时序影响**。
> **副产物结论**：在改这两行之前，**本设计根本无法用 Verilator 编译** ——
> 即 §10 那批数字**只可能来自 Icarus**（这也限定了下面的 V2 该跟谁比）。

#### 11.2 做法：`make bench`（复用同一个 TB）

```bash
make bench ARGS="+PROG=pi +DUMP=0"        # 默认 VMAX=2 亿拍
```

- **复用 `tb/top/tb_cpu_prog.v`，不新建 TB 文件** —— 这是刻意的：打印格式、plusarg、
  诊断逻辑完全一致，两个引擎的数字才能**逐字段直接比对**；新建 TB 会引入"两边测的不是同一件事"的风险。
  附带好处：`TBS := $(wildcard tb/*.v)` 是自动发现，不新增 TB 就**不会**被 `make` 默认目标误跑到。
- 产物落 `sim/bench/`（已被 `make clean` 覆盖），不污染 `sim/<域>/`。
- `MAX_CYCLE` 是 **top 模块的 parameter**，用 `-pvalue+MAX_CYCLE=<VMAX>` 在 verilate 时烘焙
  （默认 200 万对 `pi` 远不够）；`-o ../bench` 相对 `-Mdir` 解析，实测产物落在 `sim/bench/bench`。
- 一律 `+DUMP=0`（关 VCD）—— 开着 `--trace` 会吃掉速度优势。

#### 11.3 一致性验证：Verilator 与 Icarus 逐字段比对（**本轮最关键的证据**）

对 §10 已记录的 **17 个有判词程序**全部用 Verilator 复跑，与 §10 表格**逐字段**比
（`ret`/拍数/提交/冲刷）：

| 结果 | 程序 |
|---|---|
| **四个字段全部逐位相同（16 个）** | naive / gcd / array_test1 / array_test2 / statement_test / lvalue2 / manyarguments / expr / multiarray / hanoi / bulgarian / basicopt1 / magic / queens / superloop / qsort |
| **仅"提交"差 1（1 个）** | `tak`：Verilator `commit=1365220` vs 文档 `1365221`（**拍数 1654514、冲刷 29375 完全相同**） |

**`tak` 差的这 1 条不追，理由有三，且都是本文档既有的口径**（**经用户决定：不为此新跑 Icarus 复现**，
按"无法溯源就标注"处理 —— 复现一次要 23 分钟，而结论不改变任何判据）：
1. **提交数不是正确性判据** —— §10 开篇即写明「判据只有一条：`ret` 等于期望值」，
   `tak` 的 `ret=186` 两方一致；§8.3 也已有先例（`hanoi` 修复前后提交数差 **85 条**，
   远超 `ROB_SIZE`=32，同样按"不追"处理）。
2. **量级**：1 / 1,365,220 ≈ **7×10⁻⁷**。
3. **机制上可解释**：`commit_count` 在 `!halt_q_r` 门控下逐拍累加（`cpu_top.v:636`），
   差 1 等价于**恰好某一拍**的 `n_commit` 两方不同；Verilator 是 **2-state**（X 一律按 0 解），
   而 `tak` 正是 §8 记录的**唯一**出现过 X 行为的程序。**本条属推断，未经波形证实**，故如实标注为推断。

**边界（必须写进报告）**：Verilator 是 **2-state，无法复现 X 传播类缺陷**。
所以分工是死的：**Verilator 管速度与 IPC 测量，Icarus 保留为正确性签署工具** ——
lat=20 的正确性、以及任何 X 相关排查，一律回到 Icarus。

#### 11.4 `pi` 判词与墙钟

| 项 | 值 |
|---|---|
| 判词 | **`PASS: pi ret=137`**（与 `exp_ret_f` 期望一致）✓ |
| 拍数 / 提交 / 冲刷 | **154,707,280 / 93,403,298 / 8,157,425** |
| IPC（全程序） | **0.6037** |
| **Verilator 墙钟** | **182.7 s ≈ 3 分 03 秒**（单线程；与 `tak` 的 Icarus 复跑并发，故为**保守上界**） |
| Icarus 等效墙钟 | 154,707,280 × 0.845 ms ≈ **36.3 小时** |
| **加速比** | **≈716×**（实测吞吐 847k 拍/秒，对比 Icarus 1.18k 拍/秒） |

**`pi` 的定性就此闭环**：§7 判它属 **c 形态（只是慢/未定）**，现在有了实测判词 —— 分类正确，
不是缺陷，纯粹是 Icarus 的墙。

#### 11.5 本轮验证项对照

| # | 标准 | 结果 |
|---|---|---|
| V1 | Verilator 能构建全核并跑通一个程序 | ✅ `make bench ARGS="+PROG=naive"` → `PASS: naive ret=94 cycles=38 commit=18 flush=0` |
| V2 | Verilator 与 Icarus 语义等价 | ✅ 17 个中 **16 个逐字段相同**；`tak` 仅提交差 1（见 11.3，已论证不追） |
| V3 | `pi` 拿到判词 | ✅ `ret=137`，见 11.4 |
| V4 | 现有 Icarus 流程未被破坏 | ✅ `make` 退出码 **0**，**12 个 TB 全 `ALL TESTS PASSED`**，0 个 `TESTS FAILED` |
| V5 | 面积未被改动 | ✅ **自动满足** —— `memory.v` 未改；RTL 改动仅 `rs.v` 两处 generate 标签重命名 |
| V6 | 过程有记录 | ✅ 本节 + 「当前状态」已更新 |

**遗留（记录在案）**：
- `tak` 的 1 条提交差：已判定不追；若日后要做"提交数逐位对齐"，须在 Icarus 侧加波形逐步比对，
  属**独立课题**，与 IPC 无关。
- `loopjal`/`loopld` 两个无终止指令的微负载**未在 Verilator 下跑**（它们只用 `+PERF` 窗口，
  在 Icarus 下工作正常；需要时同样一条 `make bench` 即可，不是缺口）。

### 12. IPC 优化第一轮 —— **勘察已完成，计划已记录，暂不执行**（2026-09-19）

**状态**：用户接到通知，**benchmark 部分待定** ⇒ 本轮**不执行**，只存档勘察结论与计划。
本节是勘察结论的**存档**，下面每条都有出处；benchmark 定型后直接照此执行，**不要重查**。

**为什么"先接 benchmark 再优化"**：description.md §评分标准与时间安排 · 2. 性能 规定 IPC 评测点是
`testcases/perf_*`。而我们目前唯一的全程序 IPC 是 `pi` 在 **lat=3** 下的 0.6037 —— **既不是评测集、
也不是评测延迟**（评测延迟现为 **10 拍**）。**"档 1 是否已经达到"至今仍是未验证状态。**

更关键的是 **lat=20 下瓶颈画像与 lat=3 相反**（§8 实测）：

| | lat=3（`pi` 全程序） | lat=20（`hanoi` 20 万拍窗口） |
|---|---|---|
| 后端结构阻塞 | `block rob/rs/fl/lsq` **全 0** | `block fl=88291`（**窗口 44%**）、`rs=28340` |
| 主因 | 前端：`nobatch` 23.8% | 后端：free_list 空闲池枯竭 |

⇒ **不能拿 lat=3 的画像指导优化**。用户已确认范围：**先接 benchmark 拿真口径**，
且**先把档 1（IPC 0.6000 / 面积 9000 —— 旧文档写的 10000 是上一版上限）坐稳，
能往上够多少算多少**（不预设冲档 2/档 3）。

#### 12.1 Benchmark 接入：勘察结论（**纠正 §9 的两处判断**）

**① 工具链可用**：`/Users/audience/opt/riscv64-unknown-elf-gcc/bin/`，GCC 8.3.0，
`rv32im/ilp32` multilib 实测存在，`as/ld/objcopy/objdump/readelf/nm` 齐全。

**② §9 说 rsort「需单线程等价替换或确认 libatomic 可用」—— 后一条被实测证伪**：
rv32im/ilp32 的 `libgcc.a` 里 **`atomic.o` 一个符号都没有**（连 `_1`/`_2` 都没有），
全工具链无 libatomic，`size_t` 是 4 字节 ⇒ 必然 `__sync_fetch_and_add_4` undefined reference。
而 `-march=rv32imac` 会生成 `lr.w/sc.w/amoadd.w`，被 `decode.v` 当 NOP **静默算错**（比链接失败更危险）。
⇒ **只能改源码**，共 11 处（`rsort/rsort.c`，三处同型，机械替换；单核单线程下与原子版逐位等价）。

**③ §9 没点破、但实机上会致命的：benchmark 自带的构建系统目前 100% 跑不通。**
`bmarks` 列表含 8 个**已删除**的目录；`VPATH` 只指 `common/` 而 `crt.S`/`syscalls.c`/`test.ld`
已被搬到 `common.original/`；`incs` 指向已删除的 submodule（`riscv-pk/machine`/`libamf/src`）。
⇒ **另写独立构建脚本，不修补上游文件**（便于日后对上游 diff）。
> 顺带核实 §9 关于 `common/` 的说法**成立**：`common/` 是新写的轻量头（`util.h`/`amf.h`），
> `common.original/` 是原始裸机文件。但**目录重组只做了一半** —— 文件搬走了、引用没改，
> 且 `common.original/syscalls.c` 自身也因 `amf_ntiles`/`encoding.h` 缺失而编不过，**同样不可复用**。

**④ 必须新写的 4 件**（全放 `bench/`，不污染 `rtl/`、`tb/`）：

| # | 文件 | 要点 |
|---|---|---|
| 1 | `crt0.S` | 上游 `crt.S` 用了 **10 处 CSR/特权指令** + 已不存在的 `encoding.h`；而 `decode.v` 把非法指令当 NOP ⇒ **不报错只跑飞**。新 crt0 只有四行：`lui sp,0x20` → `call main` → `addi a0,x0,255` → 自跳。⚠ **`_start` 必须在地址 0**：`rtl/front/fetch.v:155` 复位后 `pc_r <= 32'd0` |
| 2 | `test-rv32im.ld` | 入口 `0x0`，正文 `0x1000`，**必须显式写 `.rodata`**（上游 `test.ld` 没有）；约束 `text+data+bss < 0x20000`（最大 rsort ≈24KB） |
| 3 | ELF→`.data` 脚本 | 格式已确认（`tb_cpu_prog.v:3`）：`@<8 位 hex 字节地址>` + 每行 16 个 2 位 hex 字节、小端；`objcopy -O binary --only-section=<sec>` 逐段取字节，`.bss` 跳过（TB 已整体清零） |
| 4 | `bench/build.sh` | `-march=rv32im -mabi=ilp32 -O2 -nostdlib -nostartfiles -DPREALLOCATE=0 -DHOST_DEBUG=0`。**`PREALLOCATE=0` 是刻意的**：默认 `=1` 会让每个 workload 跑两遍（warm-up + 计时窗口），而 `setStats()` 是空实现 ⇒ 白跑一倍拍数 |

**⑤ 两条已排除的风险**（省掉一轮试错）：
- **不会有 `div/rem`** —— `rsort` 的 `% BASE`（`BASE = 1<<8`）与 `qsort` 的 `/2` 都是常量幂次，
  强度削减成 `and`/`srl`；`multiply.c` 是软件移位加法 ⇒ **ISA 缺口不阻塞接入**（缺口本身见 12.3）。
- **不用 FP** —— 6 个 workload 无一处 `float/double`。

**⑥ TB 侧接入的三个坑**：
- **`qsort` 会撞名**：`exp_ret_f` 里 `qsort → 8'd105` 是功能集那个 qsort，而 benchmark 的 qsort
  通过时返回 **0** ⇒ 同名**直接判 FAIL**。⇒ **镜像一律加 `bm_` 前缀**。
- **`exp_ret_f` 未知名字默认返回 `8'h00`**，而 benchmark 通过时**恰好返回 0** ⇒ **名字拼错会静默"通过"**。
  必须把默认值改成哨兵（或加"名字必须在表内"检查），否则验收是假绿。
  （`towers` 失败时返回 **2~6** 而非 1，8 位 `ret` 装得下。）
- 镜像放 `tb/top/prog/bm_*.data`（TB 路径写死 `tb/top/prog/%0s.data`，改路径要动 TB，不值得），
  **并加进 `.gitignore`** —— benchmark 本身不入库，派生产物也不该入库。

#### 12.2 面积单价：实测校准（**`docs/area_budget.md` 的消融估算系统性偏低**）

`area_budget.md` §3 的"面积影响"列是**纯 FF 位 × 0.29**，漏掉了阵列外围逻辑。按
`synth/out/cpu_synth.log` 逐模块实测反推的单价（**建议以此为准**）：

| 参数 | 单价 µm²/条 | 增减示例 | 备注 |
|---|---:|---|---|
| **MEM_INFLIGHT** | **0** | 任意 | `synth/cpu.ys:15` 用 `read_verilog -lib` 把 memory 当黑盒 ⇒ **改它面积恒不变** |
| BHT_SIZE | 1.12 | 32→128 = **+107** | |
| RAS_SIZE | 13.0 | 8→32 = **+313** | |
| PRF_SIZE | 21.3（+free_list 3.85） | 64→96 = **+804** | |
| ROB_SIZE | 24.9 | 32→64 = +797 | |
| RS_SIZE | 74.7 | 16→24 = +597 | |
| **LSQ_SIZE** | **119.6（超线性）** | 16→32 ≥ **+1914** | 地址比较 O(N²)，**尽量不动** |

与 `area_budget.md` §3 的偏差倍数：ROB 2.1× / RS 1.8× / LSQ **5.0×** / PRF 1.9×。
**档 1 的面积余量只有 2231 µm²（22.3%）** ⇒ 动 LSQ 或 PRF 一档就吃掉大半。

> 附带发现（不在本轮范围）：全设计 4543 个 `ASYNC_DFFHx1`（贵 0.37908 vs `DFFHQNx1` 0.2916）
> **恰好等于** rs+rob+rat+ready_table 的 FF 数 —— 改同步复位可省 **≈397 µm²（5.1%）**，代价是复位路径时序。
> 另：`area_budget.md` §2 用 0.29 统一估算，正是漏掉了这 397 µm²。

#### 12.3 动手前必须先处理的已知隐患（**属正确性，不是性能**）

**（甲）W>1 的两个潜伏缺陷 —— 核实存在，且合计只需约 2 行**

| 缺陷 | 位置 | 实测 |
|---|---|---|
| ROB `full` 只保证 1 槽 | `rtl/core/rob.v:139` `full = (free_r == 0)` | `rob_free_w`（`cpu_top.v:131` 声明、`:151` 接线）**全仓库从未被读** |
| 幻影槽进 ROB/RS | `rtl/top/cpu_top.v:398` `rob_push_valid[s] = issue_en;` | 缺 `f2i_valid[s]`；同一条线还喂给 RS（`:198`） |

后果不是"少一条"而是**窗口永久失同步**：W=2 且 `free_r==1` 时放行 → `free_r <= 1-2` 在 6 位下回绕成 63
→ `keep_head` 几乎恒真 → `set_last` 截断不再收敛 head，同时 last 继续覆盖活跃条目。

**修法（两行）**：`:398` 加 `&& f2i_valid[s]`；`:369` 的 `!rob_full` 换成 `rob_free_w >= ISSUE_WIDTH`
（正好用上那条死线）。**之所以够**：`fetch.v:189-192` 的 `f2i_valid` 是**前缀形态**（1…10…0），
故有效槽必是 `s = 0..v-1`，rob 内部 `psum[k] == k`，与 `cpu_top.v:414/419` 写死的 `rob_last_w + s`
**恰好一致** ⇒ 不需要改 tag 运算。
> ⚠ **不要动 `rob.v:139` 的 `full` 语义**（备选方案）：`tb/core/tb_rob.v:140` 断言
> `full == (m_free == 0)`，`:267/:288` 也查它，`tb_cpu_prog.v:88` 还用它做停滞归因。

**配套**：`tb/top/tb_cpu_prog.v:41` 把 `.ISSUE_WIDTH(1)` **写死了**（不是参数）⇒ W>1 目前**没有整机回归入口**。

**其余 W>1 相关模块已逐个核过，均无需改动**：`cdb.v` 多写口已是独热译码后 OR 归约（且两个槽写同一 preg
不可能发生）；`ready_table.v` **没有 per-slot 端口**，`ready` 是广播掩码；`prf.v` 已参数化（2W 读口）；
`lsq.v` 的 load 发起仍 1 条/拍、store 提交被截断成 ≤1/批 ⇒ 不用改。
真正的 W>1 风险是**规模与关键路径**（`rs.v:110-139` 的年龄仲裁链在 W=2 时是 32 级串行），不是写死。

**（乙）RV32IM 的 DIV/DIVU/REM/REMU 未实现 —— 静默 NOP**

- `rtl/exec/alu.v:34-47` 只用到 `op 0..13`；`decode.v:50` 的 `mul_f3_ok = f3 ∈ {0..3}`，
  `:63-66` 的 `r_ok` 也只放 `f7=0000000`/`0100000,f3∈{0,5}` ⇒ **div/rem 编码静默变 NOP**
  （不报错、不陷入，还照占一个 ROB 条目）。**description.md §架构要求与设计规范 · 1. 指令集 要求 RV32IM（含 div/rem）
  ⇒ 这是功能空缺，不只是性能问题。**
- **当时的判断"不阻塞"已作废**：12.1 ⑤ 只看过 `CPU-2026-Benchmark` 的 6 个 workload；
  官方 `testcases/correctness_*` 的**每一个编译程序**都在 `course_put_result` 里用 `remu`（`% 253`）
  ⇒ 缺口从"可能触发"变成"**必然触发**"，**C1 步必须先修**（Phase C）。
- **若日后要修**（记录结论，省得重查）：**已按此落地，多周期实现 —— 验收见 §15.10**。
  - op 空间 `14..31` 空闲，可用 14=DIV/15=DIVU/16=REM/17=REMU。
  - ⚠ **只放开 `decode.v:50` 而不动 `execute_slot.v` 会更糟**：`execute_slot.v:82` 的
    `is_mul = is_r && (func7 == 7'h01)` 配上 `:122-124` 的编码 mux，`f3 >= 4` 会落到 `op=5'd13`（MULHU）
    ⇒ **DIV 会被当成 MULHU 执行**。
  - 全设计**唯一的 in-flight 机制是访存的飞行槽**（`memory.v:65-69`）；ROB/RS **没有**"占用执行槽 N 拍"
    的机制（RS 条目选中当拍即清，`rs.v:239-241`）⇒ 多周期除法器只能照抄访存那套协议。
    单周期组合除法器代码省（~150-250 行 / 4-5 文件），但 **32 级借位链很可能成为关键路径**，
    威胁 ≥300 MHz 的硬性前提（综合默认 `CLOCK_PERIOD_NS=2.0`，即 500 MHz 目标）。
    面积 +500~1500 µm²，而档 1 余量（**新上限 9000 下是 1231.5 µm²**，且还要减去 SRAM 估算面积）
    很可能不够 ⇒ **倾向多周期除法器**。
  - 本仓库 18 个 `.data` 镜像里 **div/rem 命中 0 条** ⇒ 用它们**没有现成的题可测**；
    但官方 `testcases/correctness_*` 里遍地是 `remu`，修完直接拿官方点验收即可（Phase C 的 C1）。
    → **实际两条都用了**：官方 19 条给常规路径（G2），另自造 `tb/top/div_corner.*` 补"官方题库
    一条都没有"的除零与溢出（G3，见 §15.10.6）。

#### 12.4 一个尚未验证的达标项：**频率**

`synth/cpu.ys` **全篇没有任何时序约束**（无 `create_clock`、无 `abc -D`、无 `.sdc`），
`synth/mul.ys:12` 明文写"时序: 暂不约束; 面积导向用 `map -a`"。
⇒ **7768.5 µm² 是无时序约束的面积最优解，不代表能满足频率要求。**

**官方口径（最终版）**：频率 **≥300 MHz 是硬性前提**（不是加分项），达标后另有加分：

| 最低频率（MHz） | 加分 |
|---:|---:|
| 300 | +0 |
| 400 | +2 |
| 500 | +4 |

综合与 STA 的时钟基准是 `CLOCK_PERIOD_NS`，**默认 2.0 ns**（= 500 MHz 目标）；
框架会把该周期传给 ABC 做时序驱动映射（`abc -D 2000`，单位 ps）并用 OpenSTA 检查建立时间。
⇒ 官方流程**自带**我们旧 `synth/cpu.ys` 缺的那一环，**这条缺口在 Phase C 迁移后自动闭合**，
但要重新用官方口径测一遍（`make synth CLOCK_PERIOD_NS=2.0`）。
**本阶段的应对**：优先选**不加长关键路径**的改动（改容量而非改结构）——
尤其 §12.3(乙) 的除法器如果是单周期组合实现，32 级借位链会成为新的关键路径。

#### 12.5 待执行的计划（benchmark 定型后照此走）

**Phase 0 — 接入**【**已作废**，2026-09-24】：原计划按 12.1 的 4 件新写 + `rsort` 源码替换 +
`bm_` 前缀 + `.gitignore` + 自建 Makefile 目标。**实际做法改为直接接官方框架**（§13）：
`testcases/perf_*` 自带预编译镜像，`make perf` 直接给 IPC 表格与几何平均；
延迟口径也统一成 10 拍（不再有 lat=3/lat=20 两轮）。
下面 Phase 1 的**候选清单与性价比排序仍然有效**，只是"面积余量"的数字要按新上限重算。

**Phase 1 — 按性价比优化**（**一次只改一个参数**，改前后各记 IPC + 面积 + 全量回归）：

| 优先级 | 候选 | 为什么 | 面积 |
|---|---|---|---|
| 1 | **MEM_INFLIGHT 4→16** | MLP 上限 = `MEM_INFLIGHT / LATENCY`；10 拍下 4/10 = **0.4 loads/cycle** 是**硬结构性天花板**（旧 20 拍口径下只有 0.2）。Phase C 后等价物是 AXI 侧未完成读槽/MSHR 数 | **0**（旧流程）/ MSHR 寄存器（新流程） |
| 2 | **RAS_SIZE 8→32** | 有效深度只有 `RAS_SIZE-1 = 7`；`ret` 误预测率 **99.95%**（`pi`：845,019 条里错 844,588） | +313 |
| 3 | **BHT_SIZE 32→128** | 条件分支类占 `pi` 全部误预测的 **86.2%**（`bxx` 59.2% / `beq` 16.6% / `bne` 10.4%） | +107 |
| 4 | **PRF_SIZE 64→96** | free_list 池 `FREE_NUM = PRF_SIZE-32 = 32` **恰好等于** `ROB_SIZE=32`，**余量 0**。lat=20 下 hanoi 被它挡了 **44%** 的拍 | +804 |
| 5 | ROB_SIZE 32→64 | 但会**同时**要求 free_list 池更大，否则第 4 项的正反馈更严重 | +797 |
| 6 | RAT 快照 walker | lat=3 下 `flushcyc` 占 15%（hanoi）；属中等改造 | 中 |
| 7 | I-cache / D-cache | **升格为必需项**：description.md §架构要求与设计规范 · 2 把"Cache 容量与相联度"列为**必须参数化**的项；10 拍外部延迟下 cache 是 IPC 的主要杠杆。面积代价现在**有官方公式可算**（≈0.042 µm²/bit，见 architecture.md C.6） | 大，但可预估 |
| 8 | 双发射 W=2 | IPC>1 的唯一途径（档 3 需要）。解锁只要 12.3（甲）的 **2 行**，但**验证成本是大头** | **无实测数据** |

**stretch goal**：把 12.3（甲）的 2 行修掉 + `tb_cpu_prog.v:41` 参数化，使 W=2 至少**能跑**。
验收标准是"**W=1 逐位不回归**"，不是"W=2 更快" —— W=2 的性能调优另开一轮。

**纪律**：每项优化后 **`make perf` + `make test`（官方两档）+ `make -f Makefile.tb run`（12 个单元 TB）** 三门禁。
Verilator 让功能回归从 2.6 小时降到分钟级，但**正确性签署仍以 Icarus 为准** ——
Verilator 是 2-state，**无法复现 X 传播类缺陷**。每项后 `make synth` 当场重跑
（`build/` 在 `.gitignore` 里，**残留文件是陈旧产物，不能当基线**）。

### 13. 官方框架接入（2026-09-24）—— 口径换版 + 布局迁移 + 综合链路打通

**背景**：用户把 `docs/description.md` 整体换成官方模板 README（**最终版**，只由用户手动修改）。
评测口径**全面变化**，四份文档（`plan.md`/`architecture.md`/`area_budget.md`/`CLAUDE.md`）全部还是旧口径，
且若干处**显式引用旧文件的 行号**（如 `description.md:42`）⇒ 换文件后指针全部失效。
本次范围（用户已定）：**文档对齐 + 框架布局迁移**；RTL 的 `student_top`/AXI4-Lite 移植写成 Phase C 方案，**本次不动 RTL**。

#### 13.1 口径对照表（旧 → 新）——所有文档改动的唯一依据

| 项 | 旧 | 新（最终版） |
|---|---|---|
| ISA 免除清单 | CSR\*/ECALL/EBREAK、FENCE/FENCE.I、**LH/LHU/LB/LBU** | 仅 CSR\*/FENCE(.I)/ECALL/EBREAK ⇒ **LB/LBU/LH/LHU 转为必须实现** |
| 面积 / IPC 档位 | (10000, 0.6000) / (20000, 0.7800) / (40000, 1.0140) | **(9000, 0.6000) / (18000, 0.8450) / (36000, 1.0985)** |
| 频率 | ≥300 MHz，无加分 | ≥300 MHz **硬性前提**；400 MHz +2、500 MHz +4；`CLOCK_PERIOD_NS` 默认 **2.0 ns** |
| 内存延迟 | 功能 **3 拍** / 性能档 **20 拍** | 框架 `LATENCY` 默认 **10 拍**，`--latency` 可调；**只有这一个口径** |
| 内存 | 统一内存；不综合、不计面积 | 外部 **256 MiB AXI4-Lite 从机**；`sram_fakeram` 的**估算面积计入**总面积；仍禁止寄存器组当内存 |
| 顶层 | 未规定（本仓库自定 `cpu_top`） | 必须叫 **`student_top`**，AXI4-Lite 端口模板，**`reset` 高有效**（初始化保持 5 拍） |
| 终止约定 | 未规定（本仓库自定 `ori x0,x0,255` + `ret_val=a0[7:0]`） | 向 MMIO **`0x80000000`** 做 32 位 store（`WSTRB=4'hf`），退出值 = **`WDATA[31:0]`** |
| 参数化 | 发射宽度、PRF、ROB | 追加 **发射队列深度**、**Cache 容量与相联度** |
| IPC 口径 | Verilator 统计；测试点 = `CPU-2026-Benchmark` | `动态指令数 / 运行周期数`；`testcases/perf_*` 的**几何平均**；分子取自 `metrics.json` |
| 正确性集 | "CPU Simulator 中的程序" | `testcases/correctness_*`（submodule） |
| 框架 | 无 | `config.mk` / `Makefile` / `verilog/filelist.f` / `scripts/`（勿改）/ `testcases/`(submodule) |

#### 13.2 布局迁移结果（已完成并回归）

- `rtl/` → **`verilog/`**（19 个源文件，`top/front/core/exec` 四域不变）；
  新增 **`verilog/filelist.f`**（路径相对 `verilog/`，官方 `build.py` 就是这么解析的）
- 根 `Makefile` 换成**官方框架版**（`build/test/perf/synth/run/clean`）；
  自建 iverilog 流程改名 **`Makefile.tb`**：`make -f Makefile.tb run/wave/bench TB=...`
- 官方 `config.mk` **原样保留**（机器相关路径不入库）；本机路径写 `config.local.mk`（已 gitignore），
  用 `make CONFIG=config.local.mk <target>`
- `scripts/`（12 个文件 + `ram/sram_fakeram.sv`）、`docs/{axi4-lite,sram}.md` 原样引入；
  `packaging/` **不引入**（description.md 说可删，且本机是 macOS）
- `testcases` 加为 **submodule**（`ACMClassCourse-2025/RISC-V-CPU-2026-Testcases`）；
  本地 `CPU-2026-Benchmark/`（C 源码参考，已 gitignore）保留，两者关系：**同一批 workload，
  官方那份带预编译镜像**
- **回归证据**：`make -f Makefile.tb run` → **12 个 TB 全 `ALL TESTS PASSED`、退出码 0**；
  抽检 `naive`(94) / `expr`(58) / `hanoi`(20) / `magic`(106) 判词与期望一致
- **已知过渡态**：官方 `make build` 现在会报 `--top-module 'student_top' was not found in design`。
  这是**预期失败**（缺 Phase C 的顶层），不是配置错误 —— 已验证 19 个源文件都被成功读入

#### 13.3 本机工具链实测

| 工具 | 状态 |
|---|---|
| `verilator` 5.051 / `iverilog` / `yosys` 0.68 / `yosys-abc` | ✅ 在 PATH |
| ASAP7 RVT TT 五个 `.lib` | ⚠️ `/Users/audience/opt/asap7sc7p5t_27/LIB/NLDM/`（该目录下恰好 5 个 `*.lib`，符合 `synth.py` 的校验）—— 但这是 **r27 `_201020`**，官方容器是 **r28**，**数字不可比**（见 §13.5） |
| `riscv64-unknown-elf-gcc` 8.3.0（rv32im/ilp32 multilib） | ✅ |
| **OpenSTA（`sta`）** | ❌ 宿主缺失；**改走容器**（容器内 3.1.0）⇒ 见 §13.5 |
| 课程 AppImage | ❌ Linux x86-64，macOS 不可用 |
| **OrbStack + `cpu2026:local` 镜像** | ✅ **已构建（2026-09-24）** ⇒ 官方 `make synth` 可在容器内跑通，见 §13.5 |

⇒ **`make synth` 已不再是拦路石**（走容器）。但注意：**即便在宿主装上 OpenSTA 也不该用它出数** ——
宿主库是 r27、容器是 r28，revision 不同 ⇒ 数字与官方口径不可比。

#### 13.4 与官方测试集对照后的三个发现（**都不是本次改动引入的**）

1. **官方正确性集是另一批二进制**：19 个 `correctness_*` 与我们 `tb/top/prog/*.data` 里
   **7 个期望值不同**（naive 97/94、expr 136/58、hanoi 184/20、magic 216/106、queens 144/171、
   qsort 81/105、pi 112/137，格式`官方/本地`）⇒ **本地 18 个 PASS 的证据不能平移到官方评测**。
2. **DIV/REM 是必答题**：官方每个编译程序都在 `course_put_result` 里用 `remu`（`% 253`）——
   我们的 `decode.v` 把 M 扩展 funct3 4–7 静默当 NOP ⇒ **19 个里 18 个会算错**（见 §12.3 乙）。
   > **后续实测修正（§14.4）**：实际是 **17 个失败**——`lvalue2` 的 `hash = 175 < 253` 使那条 `remu`
   > 成了恒等运算，NOP 化恰好得到同一结果，是巧合不是实现。
3. **§9 的接入计划作废**：官方 `testcases/*/program.data` 是**预编译镜像**（装载地址 0），
   不需要 crt0 / 链接脚本 / ELF→`.data` 脚本 / `rsort` 源码替换（详见 §9 的作废说明）。

> **教训（值得写进报告）**：这三条都是"文档口径与实际交付物不一致"造成的 ——
> 旧文档把 `CPU-2026-Benchmark`（源码树）当成了评测集，而真正的评测集是
> `testcases/`（预编译镜像 + `expected.txt` + `metrics.json`）。
> **后续凡是"判据/期望值"类结论，一律以 `testcases/` 为准。**

#### 13.5 官方综合链路（OrbStack 容器）—— 已跑通 + 冒烟实测

**为什么走容器**：官方 `make synth` 硬性依赖 OpenSTA（`synth.py` 缺 `sta` 直接报错），宿主缺失。
`docs/description.md` 的「方案 B：使用 Docker 容器」就是官方给的路径；**全仓库/上游都没有预构建镜像可拉**，
必须本地 `docker build`。Dockerfile 把四个依赖全部 pin 到 commit，镜像内 `PATH` 已铺好，
**不需要 AppImage、不需要改 `config.mk`**（实测 `config.mk` 全默认即可：`ASAP7_LIB` 空 ⇒ 容器内 `/opt/asap7/lib`；
`APPIMAGE` 指向的文件不存在 ⇒ `toolchain.py:22-30` 静默 no-op 退回 PATH）。

**溯源戳（可复现）**：

| 项 | 值 |
|---|---|
| 上游 commit | `54fc150ffc290f52aa024209ffb9a29d43856f6d` |
| `Dockerfile` git-blob | `f0bd0fffb01b542121e81870655a06b55d62724e` |
| `Dockerfile` sha256 | `20ad4d62cc91e358458b95efb0fce570b07adacf56e7124d924b1cd922d3cf8b` |
| 构建上下文 | 框架根副本（含 `scripts/`），**放在仓库外** |
| 镜像 | `cpu2026:local`（`5ee20bd4624a`，963 MB） |
| 平台 / 参数 | `linux/arm64` **原生**；`BUILD_JOBS=2`（OrbStack VM 仅 3.9 GiB 内存，Dockerfile 默认 8） |
| 构建日期 | 2026-09-24 |

```sh
docker build -t cpu2026:local <框架根副本>          # 约 20–40 min @ arm64/-j2
docker run --rm -v "$PWD":/work -w /work cpu2026:local \
  make synth FILELIST=… SYNTH_OUT=… MODE=opt        # MODE=opt|diagnose
```

> **注意**：容器只 `COPY scripts/` 到 `/opt/cpu2026/` 并做 `/usr/local/bin/synth` 符号链接；
> 但 `Makefile` 的 `FRAMEWORK_DIR` 取自 Makefile 自身位置 ⇒ `make synth` 在 `/work` 下实际跑的是
> **挂载进来的本仓库 `scripts/synth.py`**，不是镜像里那份。两者同源，但"镜像提供了脚本"这个说法是错的。

**环境事实（与官方文档不同，必须记录）**：

1. **Docker Hub 在本机不可达**（`auth.docker.io` 连接重置）。镜像改为**单独拉取后本地打官方 tag**
   （`ubuntu:24.04`、`docker/dockerfile:1` 各一份）。**未改动 `~/.orbstack/config/docker.json`**
   （仍为 `{}`，即**没有**配置任何 daemon 级 registry mirror）。构建期只访问 GitHub（可达）与 apt 源。
2. 容器内 `verilator` 是 **apt 版 5.020**，本机是 **5.051** ⇒ **IPC 数字跨环境不可直接比**（见文末待办）。

**镜像自检**（每次用前必查，任一不过即停）：

| 检查 | 实测 |
|---|---|
| `/opt/versions.txt` | Yosys 0.63 `70a11c6b…` / ASAP7 **r28** `f970bd3c…` / OpenSTA `f89887b5…` / CUDD `f54f5333…` |
| `/opt/asap7/lib` | **恰好 5 个 `*.lib`**，含 `_SEQ_`（`_211120` / `_220122` / `_220123`） |
| 工具版本 | `yosys 0.63`、`sta 3.1.0`、`verilator 5.020`、`python 3.12.3` |

五个库的 sha256（供 `report.json.libraries[].sha256` 对账）：

```
b1ece108c0a2acd8d01c05cee6daee2834425037b1d9aad625d6f1dd640f1940  AO_RVT_TT_211120
a4ceb32e418e1aac8667e28fbd8e9e46baf520180be4db075598a4d7c681a56e  INVBUF_RVT_TT_220122
6529c6c72465cd133dfbfb03952327ab2774bb6aa4be866d78fd7bc6c58c9f6f  OA_RVT_TT_211120
57a0b403485b99ebd676942af4673ac086b86c7c75fbdc3e5c0038501dd22ba3  SEQ_RVT_TT_220123
fa92e6ab1481810602811b1eea54bc016a341f11fb5188d7512c026599adf038  SIMPLE_RVT_TT_211120
```

**r28 的触发器常数**（`dfflibmap -info` + 逐 cell 读 `area`）—— **这条推翻了旧文档的表述**：

| cell | 面积 (µm²) | 对应 Yosys | 复位 |
|---|---:|---|---|
| `DFFHQNx1_ASAP7_75t_R` | **0.2916** | `$_DFF_P_` | **无复位**，只有 `QN` 输出 |
| `DFFLQNx1_ASAP7_75t_R` | 0.2916 | `$_DFF_N_` | 无复位 |
| `DFFASRHQNx1_ASAP7_75t_R` | **0.37908**（+30.0%） | `$_DFFSR_PNN_` | 异步 set/reset |

⇒ **库中不存在同步复位触发器** —— `$_DFF_PN0_` / `$_DFF_PP0_` 等**全部 `unmapped`**。
`dfflegalize` 给出的合法集合只有 `$_DFFSR_PNN_` / `$_DFF_N_` / `$_DFF_P_` 三个。
**故"同步低有效复位"这个写法在本流程下会被拆成软逻辑（更贵）**；RTL 实际用的是
`always @(posedge clk or negedge rst_n)`（异步），**方向是对的**（`CLAUDE.md` 的措辞已同步修正）。

**冒烟（2026-09-24）**：被测对象 = `student_top{mul, adder32}` 包一层 ——
`mul` 是全核最大的单块组合逻辑、且**没有时钟端口**（`student_top` 必须有），
故包层给输入 66 位 + 输出 64 位**各打一拍**（共 130 个无复位触发器），把"面积数字能不能信"变成**可证伪**。

| 运行 | 总面积 | 组合 | 时序 | SRAM | F_max | 最小周期 | 最差建立裕量 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `MODE=opt` | **460.436** | 422.528 | **37.908** | 0 | **478.95 MHz** | 2.0879 ns | −0.0870 ns |
| `MODE=diagnose` | 527.738 | 489.830 | 37.908 | 0 | 421.57 MHz | 2.3721 ns | −0.3718 ns |
| `MODE=opt` + `sram_fakeram(256×32, 粒度 32)` | 815.284 | 424.059 | 47.239 | **343.985** | 488.32 MHz | 2.0479 ns | −0.0475 ns |

**九条判据全过**（`opt` 档）：

| # | 判据 | 实测 |
|---|---|---|
| 1 | 退出码 0 | ✅ |
| 2 | `minimum_period_ns` / `estimated_fmax_mhz` **非 null** | 2.0879 / 478.95（为 null 说明 STA 等于没跑） |
| 3 | `constraints.sdc` 含时钟与 IO 约束 | `create_clock -name core_clock -period 2.0000` + 逐端口 `set_input_delay/set_output_delay` |
| 4 | `clock_checks.rpt` 非空且无 `VIOLATED` | 非空，`0.9719 (MET)` |
| 5 | `timing.rpt` 含单元名与逐级延时 | 580 行、460 处 `_ASAP7_75t_R`；关键路径穿 `MAJI/XNOR/XOR`（Wallace 压缩器） |
| 6 | `report.json.tools` 非空 | `yosys 0.63 (70a11c6bf)` / `opensta 3.1.0` |
| 7 | `libraries[].sha256` == 容器 r28 | **5/5 全等**（证明没误用宿主 r27） |
| 8 | `mapped.v` 无 `$_` 内部单元 | 0 处 |
| 9 | `sequential_area_um2 == 130 × 0.2916` | **37.908** ✅（同时证明 `dfflibmap`、`stat -json` 面积对账、sequential 拆分三件事） |

另两条独立对账也精确成立：加 `sram` 后 `sequential = 47.239 = 162 × 0.2916`（130 + `rdata_r` 32 位）；
`组合 + 时序 + SRAM == area_um2` 逐位相等；`sram_area = 256 × 32 × 0.0419904 = 343.985357`
与 `ram/manifest.json` 的 `macros.fakeram_asap7_256x32.area_um2` 一致。

`MODE=diagnose` 的层次树为 `student_top → u_mul → {t1…t6 (tree_level ×6), fin (adder32)}`，
与 `docs/area_budget.md` §1 的乘法器分解（Booth 编码 + 部分积生成 / 6 层 Wallace 树 / 64 位加法器）**形状对应**。

> **允许存在的"同步可接受项"**：三档的最差建立裕量均为负、最小周期均 > 2.0 ns。
> 32×32 Booth+Wallace **打不进 2 ns 是预期结果**，判据是"有限且自洽"，不是"收敛"。

**⚠ 口径声明（不得混用）**：本次冒烟的被测对象是 `student_top{mul, adder32}` + 130 触发器包层，
**不是全核，也没跑 IPC**。它与旧流程的 `mul = 554.6 µm²` **仅数量级可比**，差异来源至少有四层：
① 库 revision 不同（r27 vs r28）；② 旧流程的库是**手拼的 comb-only 单文件**（剔了 TIE、避开了
`Scl_LibertyFindMatch` 断言）；③ **ABC 脚本不同**（旧 `map -a` 面积导向 vs 官方 `abc -D 2000` 延时导向）；
④ 顶层不同（多了 130 个触发器）+ 面积口径不同（旧 `stat -liberty` 含 `$paramod` 重复计 vs 官方逐实例叶子求和）。
**真核基线是 C8b，不是本节。**

**🔴 本节最重要的架构发现 —— 乘法器是 500 MHz 的单点硬瓶颈**：

`mul` 的**自身**触发器到触发器延时（= `minimum_period_ns`）= **2.0879 ns**。
拆开看：clk-to-Q **0.0808** + 纯组合 **1.9472** + 时钟不确定度 0.05 + 建立 0.009（四项相加 = 2.087，
与报告值自洽）。把它放到三档频率下：

| 目标频率 | 周期 | `mul` 触发器到触发器占比 | 仅其**组合**部分占比 |
|---:|---:|---:|---:|
| 500 MHz | 2.0 ns | **104.4%**（**超了**） | 97.4% |
| 400 MHz | 2.5 ns | 83.5% | 77.9% |
| 300 MHz | 3.333 ns | 62.6% | 58.4% |

⇒ **单周期 `mul` 在 500 MHz 档下不可能成立**（乘法器一项就超出整个周期）；
400 MHz 档下它吃掉 83.5%，留给"RS 读口 → 旁路 → CDB 写回"的余量只剩 16.5%（0.41 ns）—— 同样不现实。
这**比 §12.4 的预期更严峻** —— §12.4 只预警了"除法器的 32 级借位链可能成为新关键路径"，
实测是**已经在用的乘法器**先撞线。Phase C 若要把 500 MHz 作为目标，
`mul` 必须做**流水化/多周期化**（在 execute 级插寄存器），或把频率目标定在 300 MHz（硬性前提）先保住。

**待办**：

- **C8b（真核基线）**：需先落 `student_top`（C2）并清掉 `core/memory.v`（C7）——
  后者不落地则 64 KB 阵列被 Yosys 降成触发器，面积数字无意义。
  `synth.py:83/:104/:121` **硬编码** `hierarchy -top student_top`，顶层不到位就跑不了。
- **IPC 的跨环境可比性**：容器内 Verilator 是 **5.020**、本机 **5.051**。
  `make perf` 的 IPC 若在容器里跑，须与宿主结果**分开记录**，不得混在同一张表里取几何平均。

### 14. Phase C2+C3+C4 — 打通 AXI 闭环（2026-09-24）—— `student_top` + AXI4-Lite 主机 + MMIO 停机

**本次范围（用户已定）**：只做 C2（存储接口外露）+ C3（AXI master）+ C4（MMIO 停机），**不碰 ISA**
（DIV/REM 留在 C1）。目的：把"总线/停机"这个变量与"ISA 缺失"这个变量**隔离开** —— 两者混在一起时，
首次失败无法归因。频率策略：**先保 300 MHz**（硬性前提），mul/div 不重构（见 §13.5 的瓶颈结论）。

**为什么必须先做**：`build.py:74` 硬编码 `--top-module student_top`、`synth.py:83/:104/:121` 硬编码
`hierarchy -top student_top`，两者都不接受覆盖 ⇒ 没有 `student_top` 就**一个官方数字也拿不到**。
它是 C8b（真核面积基线）与 C1（DIV/REM）共同的前置。

#### 14.1 步骤与产出（S1–S5 已逐条提交）

| 步 | 提交 | 内容 |
|---|---|---|
| S1 | `674f6a8` | `cpu_top` 存储接口外露为端口（纯重构，零行为变化）；TB 改为本地例化 `memory u_mem` |
| S2 | `d794013` | `fetch.v` 支持变长取指延迟（新增 `imem_valid`；`cap_w`/`rewind_w` 门控） |
| S3 | `c76fe72` | `core/axi_lite_master.v`（纯协议层：5 通道握手 / VALID 稳定性 / tag FIFO）+ 单元 TB |
| S4 | `07b42dd` / `99f5c12` | `core/mem_subsystem.v`（预取窗口 / load 适配 / 已提交 store 队列）+ `tb_mem_axi`；`cpu_top` 提交路径接受 `sw_ready` 背压 |
| 修正 | `d5e0da7` | S5 接线过程中定位并修掉的两个缺陷（见 §14.3） |
| S5 | `7ec0b10` | `top/student_top.v`（19 端口）+ MMIO 停机判据 + `filelist.f` |

**设计要点**（细节在各文件头注释，这里只记"为什么"）：

- **不改 `core/memory.v`**：TB 继续把它当"固定 1 拍内存"用；`mem_subsystem` 只对位复刻它的 CPU 侧接口。
  仿真链路与官方链路各走各的存储实现 ⇒ 回归风险最小。
- **`student_top` 不引出 `halt`/`ret_val`**：官方从机在 B 握手时从 `WDATA` 取退出值（`sim.cpp:119-121`），
  退出值不经 CPU 的调试口。手写程序的 TERM marker 判定保留（OR 并存）：TB 走 marker、官方走 MMIO。
- **预取窗口就是 I-cache 的数据通路**（直接映射、每行 1 字、无替换）：下一轮加容量/相联度参数化时在它上面长，
  不重写。本轮**不做** I-cache —— `description.md` 把 Cache 容量/相联度列为消融维度，现在加会把"总线"与
  "缓存"两个变量重新混在一起。

#### 14.2 验收判据（全部实测通过，2026-09-24）

| 判据 | 实测 |
|---|---|
| ① `make -f Makefile.tb run` | **14 个 TB 全 `ALL TESTS PASSED`**，退出码 0（S3/S4 新增两个 TB） |
| ② `make CONFIG=config.local.mk build` | 退出码 0，产出 `build/sim` |
| ③ `make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050` | **PASS cycles=645 result=5050 expected=5050** |
| ④ `make CONFIG=config.local.mk test` | **19 条结果：2 PASS / 17 FAIL**，17 条全部可归因到 DIV/REM（见 §14.4） |
| ⑤ 负例：`sh`（半字）写 `0x80000000`，`EXPECTED=7` | **FAIL cycles=1000000（超时）** —— 判据不过松，见 §14.5 |

> **不把 IPC 当本次判据**（用户明确要求）：DIV/REM 缺失、取指窗口未调优，此刻的 IPC 没有意义。
> `add_to_100` 的 **645 拍**只作"链路真通了"的旁证 —— 若贴近 1e6 上限就说明 S4 的窗口没起作用。
> **不给"固定 1 拍存储"下的对照周期数**：官方 `program.data` + `EXPECTED` 的入口是 `make run`（走 `student_top`），
> 而 TB 入口（`tb_cpu_prog`）读的是另一套 `.data` 格式，跑不了官方镜像 ⇒ 本轮没有同口径的可比数字。
> AXI 往返延迟的代价留给消融/优化一节，用**同一入口**测。

#### 14.3 Debug 记录：`add_to_100` 从死锁到 645 拍

S5 接好线后官方 run 直接卡死（`FAIL cycles=1000000`）。用 VCD 逐拍取证，查出**两个独立缺陷**，
都只在"存储不再固定 1 拍"这一前提下才成立 —— 这正是 S2 想隔离的那个变量。

> **可复现的证据边界**：失败运行的 VCD 是临时文件（约 460 MB，未入库），且产生它的 RTL 已被后续提交覆盖
> ⇒ 下面每个数字都**标注来源**：能从当次 VCD 抽出的是**实测**（附抽取命令），从代码规则直接推出的是**推导**。
> 后文所有周期数则都来自框架自己的输出行（`PASS cycles=N` / `FAIL cycles=N`），可直接重跑核对。

**缺陷 1：`fetch` 的 PC 失步（死锁的直接原因）**

| 阶段 | 现象 | 结论 |
|---|---|---|
| 旧 `hold_w` 规则（S2 原方案） | **推导**（无留存证据）：数据迟到时 `!stall` 分支仍推进 pc，而 `exp_pc_r` 不动 | `arr_ok_w` 只比地址 ⇒ 永不成立 ⇒ 接收门永远关着 ⇒ ROB 排空后全机死锁。`fetch.v:74-75` 的注释本就预警了这一条 |
| 第一次修正（无条件"落后就补发"） | **实测**（1e6 拍超时那次运行的 VCD，抽取命令见下）：`pc_r` 全程**每拍翻转**（全程 1e6 拍里变化 999988 次）、`halt_q_r` 从未抬起、`sw_valid` 从未脉冲、**AR 握手总计只有 286 次，且最后一次发生在 VCD 时刻 1215**（全程到 2000009；即 ~600 拍后近 1e6 拍一条 AR 也无）；提交停在 **414** 条（该程序 `metrics.json` 记 **421** 条动态指令 ⇒ 失败发生在临近结尾处） | 请求地址每拍翻转 ⇒ 预取流的 demand 每拍变 ⇒ 取指流在 ~600 拍处被自己彻底掐死，pc 抖动到超时 |
| 最终方案（新增 `imem_hit` 端口） | `PASS cycles=645`（框架输出行） | 只有**期望批已在窗口里**（`imem_hit`）才允许把请求提前到下一批；否则把请求**退回 `exp_pc_r`** 重复请求它 —— 于是存储查找的地址恒等于期望地址，数据一到即接收 |

> 上表第二行的数字来源（VCD 已删，仅记抽取方式；信号 id 取自该 VCD 的 `$var` 行、且仅对该次 dump 有效）：
> `arvalid`/`arready` 同时为 1 的拍数计数得 **286**，最后一次在时刻 1215；`awk '/^b[01xz]+ X-$/{n++} END{print n}'`
> 数 `pc_r` 取值变化得 **999988**；`grep -ac '^1Y-$'` 得 `halt_q_r` 恒 0；`sw_valid`（id `<`）恒 0；
> `n_commit` 按拍加权求和得 828 个 tick 有提交，VCD 是 **2 tick/拍** ⇒ **414 条**。

- 不变量：`pc_r ∈ { exp_pc_r, exp_pc_r + 4W }`（相等 = 还没发出下一批请求；差一批 = 已有一条在飞）。
  固定 1 拍存储下 `imem_hit` 恒 1 ⇒ `cap` 每拍成立 ⇒ 新规则与改动前**逐拍等价**（`tb_fetch` 逐拍比对过）。
- **这条推翻了本轮计划里 S2 的写法**（"三处改动缺一不可"，核心是 `hold_w`）：那套在变长延迟下是错的，
  正确的抽象是"**请求地址即需求地址**；数据没到就把请求停在需求地址上重复请求它"，`imem_hit` 只是
  判断"能否先把请求推到下一批"的可用性依据。
- `tb_fetch` 的 F15b 断言随之改写：旧断言"数据迟到时 pc 必须冻结"**编码的是旧规则**，
  新断言是真正的不变量 `pc ∈ {exp, exp + 4W}`。

**缺陷 2：`mem_subsystem` 里一条零延迟组合环（综合/STA 无解）**

`make build` 时 Verilator 报：

```
%Warning-UNOPTFLAT: verilog/core/mem_subsystem.v:71:39: Signal unoptimizable:
                   Circular combinational logic: 'student_top.u_mem.sw_valid'
  Example path: u_mem.sw_valid → u_mem.ld_m0 → u_lsq.mem_done_data → u_lsq.mb0
              → slt[0].u_slot.load_cdb_result → slt[0].u_slot.u_br.ucmp.a
              → slt[0].u_slot.u_br.target → slt[0].u_slot.misp_det
              → u_cpu.ce_w → u_mem.sw_valid
```
（原样摘自**修复前** `make CONFIG=config.local.mk build` 的输出，Verilator 5.051。）

- **根因**：S4 为了让"提交与完成同拍"的那一拍也能被合并，把**本拍正在提交的 store** 组合地并进了
  load 的回包数据。环的另一半是 `ce_w` 的 `!misp_valid` 项（防提交副作用重复，见 `cpu_top.v` §4/§5
  的注释），两处都不可动。
- **该旁路本就冗余**：本拍提交的 store 此刻**仍在 LSQ 里**（失效发生在 posedge），且它必然**比正在完成的
  那个 load 老**（提交前提 `rob_ready` ⇒ 它的操作数早到一拍，而完成的 load 数据本拍才到）⇒ 必然命中
  `lsq.v:257` 的 `(j - hd) < dd` 合并分支（`dd` = 完成 load 距 head 的距离，比 `dd` 小 = 更老）。
  即：**这一拍由 LSQ 兜，`mem_subsystem` 只需兜"已进入队列"的 store**。
- **修法**：删掉 `sq_merge_byte_f` 的 `sv` 参数（无新增端口）。删后 `add_to_100` **周期数不变**（645），
  `Circular combinational` 告警归零。
- **教训（值得写进报告）**：这是"按直觉加保险"造出来的环 —— 保险本身冗余，代价却是综合不可用。
  组合环在仿真里被 Verilator 的迭代求解**掩盖**（多数拍地址不重叠，环上的值不真的翻转），
  只在"跨部件组合路径 + 地址重合 + 同拍误预测"时才可能取到非确定解 ⇒ **必须靠综合/告警发现，
  不能靠跑程序发现**。

#### 14.4 `make test` 的 17 条失败归因（**结论已被 §15 推翻，本条仅作存档**）

> **2026-09-27 更正**：本条的"17 条全部可归因到 DIV/REM"**不成立**。实测 6 条 mismatch 的退出值
> 恰好满足 `R % 253 == expected`（核心算对了，只缺末尾那一条 `remu`），而 `hanoi`/`magic`/
> `multiarray`/`qsort`/`queens`/`tak` 是**核内物理寄存器泄漏导致的死锁**，与 DIV/REM 无关。
> 证据与命令见 **§15**。

| 事实 | 出处 / 实测 |
|---|---|
| `decode.v` 的合法性门只覆盖 `f7=0000001 && f3∈{0,1,2,3}`（`mul/mulh/mulhsu/mulhu`） | `decode.v:50`（`mul_f3_ok`）、`:66`（`v_mul`） |
| DIV/DIVU/REM/REMU 的 `f3∈{4,5,6,7}` ⇒ `valid=0` ⇒ **译成 NOP**（不写回、不报错） | `decode.v:75`（`valid` 不含它们） |
| 19 个程序**每个**都含 ≥1 条 DIV/REM（`course_put_result` 里 `remu a0,a0,253`） | 官方 `program.S` 反汇编逐条统计 |
| 实测：2 PASS / 17 FAIL | `add_to_100`（**0 条** div/rem）645 拍；`lvalue2`（**1 条**）254 拍 |

- **`lvalue2` 为什么也过了**（这条容易被误读成"ISA 没问题"）：它唯一那条 `remu` 在
  `course_put_result` 里算 `hash % 253`，而该程序的 `hash = 175 < 253` ⇒ 真实 RISC-V 下这条 `remu`
  是恒等运算，**NOP 化**（`a0` 保持 `lw` 读来的 `hash`）恰好得到同一结果。是巧合，不是实现。
- 失败的两种形态都可解释：**算错**（`exit result mismatch`，如 `expr` expected 136 / actual 3271831050）
  与**超时**（`remu` 化 0 后程序自旋到 1e6 拍）。
- ⇒ **C1（DIV/REM）落地后这 17 条才有意义**；在此之前不得用 `make test` 的数字判断存储通路的正确性
  （判据③ + 判据⑤ + `tb_mem_axi` 三件套才是本轮的正确性证据）。
- ⚠️ **上一条的前提（"17 条全等 C1"）已作废**：其中 ≥6 条等的是 §15 的物理寄存器泄漏，
  C1 单独落地**达不到 19/19**。判据③ 与判据⑤ 的结论（存储通路正确）不受影响。

#### 14.5 负例：停机判据"不过松"的可证伪证据

`sim.cpp:91-92` 只在 `address == 0x80000000 && wstrb == 4'hf` 时置 `exit`，否则回 **SLVERR 且不停机**。
若我们的 `halt` 判据写松（例如只看地址、或把 `sw_width` 映射错），半字写就会被误判成停机并**输出一个假结果**。
故构造反例（手写 4 条指令）：`lui t0,0x80000; addi a0,zero,7; sh a0,0(t0); j .`，
用 `EXPECTED=7`（"若判据松了就会看到的那个值"）跑：

```
FAIL cycles=1000000 (timeout or finish before exit write response)
```

⇒ 判据**按设计拒绝**了半字写：既没有假 PASS，也没有把 `7` 当退出值。同时反证了
`sw_width==2'b10 ⇔ wstrb==4'hf` 这条映射是对的（`cpu_top` 侧只用 `sw_width` 判停机，不直接看 `wstrb`）。

#### 14.6 本轮遗留（下一轮的前置）

- **C1（DIV/DIVU/REM/REMU）**：§14.4 的 17 条全等它。乘法已按 Booth+Wallace 实现，除法尚未落地。
- **C7（清掉 `core/memory.v`）**：`student_top` 已不例化它，但它仍在 `filelist.f` 里（TB 要用）。
  真核面积基线（C8b）前必须确认 `hierarchy -top student_top` 把它剪干净，否则 64 KB 阵列会被降成触发器。
- **组合环类缺陷的例行检查**：把 `Circular combinational` / `UNOPTFLAT` 纳入"每次改存储接口后必看"的
  清单（见 §14.3 缺陷 2 的教训）。
- **`mem_subsystem` 的已知简化**：不支持跨 4 字节边界的非对齐访问（`memory.v` 的平铺字节数组支持）；
  编译产出的 C 代码不会产生这种访问。若 C1/C8 引入新 workload，需重新确认。

### 15. C1 前置勘察：§14.4 归因被推翻 + 物理寄存器泄漏死锁（2026-09-27）

> 本轮原计划执行 **C1（DIV/DIVU/REM/REMU）**。按计划的执行顺序先取"改动前基线"
> （`make test` + `make perf`），基线一取就发现两件事：**§14.4 的归因是错的**，
> 且 **`make perf` 根本取不到数**。C1 的 G2/G4 判据在修掉本节缺陷前不可达。
> **RTL 未做任何改动，工作树停在 `dd695f9`。**
>
> **证据边界**：15.1–15.4、15.5b、15.6 全部为**实测**（命令与输出行在正文给出，可重跑核对）。
> 15.5 保留了"原稿推错 → 实测推翻 → 定出真因"的完整过程：**15.5 开头那段推导当时是错的**，
> 已在原地标注并改写，勿把它当结论引用。

#### 15.1 实测：`make test` 基线复现，但 6 条 "mismatch" 的成因不是"算错"

`make CONFIG=config.local.mk test` → **2 PASS / 17 FAIL**，与 §14.2 ④ 逐条一致。
但把官方镜像直接喂给 `build/sim` 读出**真实退出值**后，"算错"这一类的成因与 §14.4 的说法相反：

```
./build/sim testcases/<case>/program.data <expected.txt> 5000000 10
```

| 程序 | 实测退出值 R | `R % 253` | `expected.txt` | 判词 |
|---|---|---|---|---|
| array_test1 | 1388 | **123** | 123 | 只差末尾 `remu` |
| array_test2 | 1561 | **43** | 43 | 只差末尾 `remu` |
| expr | 3271831050 | **136** | 136 | 只差末尾 `remu` |
| naive | 350 | **97** | 97 | 只差末尾 `remu` |
| manyarguments | 293 | **40** | 40 | 只差末尾 `remu` |
| superloop | 893 | **134** | 134 | 只差末尾 `remu` |

`course_put_result` 就是 `lw a0,hash; remu a0,a0,253`（各 `program.S` 的 `0x5c` 段）。
`remu` 被译成 NOP ⇒ `a0` 保持未取模的 `hash` ⇒ 退出值恰是"**正确结果的模前值**"。
**六条全中 `R % 253 == expected`** ⇒ 这些程序**主体完全算对了**，唯一缺的就是那一条 `remu`。
即 §14.4 表格末行说的"算错"，真实含义是"**只剩最后一条指令没算**"。

另两条 mismatch（`basicopt1` 2173、`statement_test` 1564）不满足该关系：它们的 `main` 自身
也用了 div（各程序 div/rem 条数：`basicopt1` 3、`statement_test` 2，其中 1 条属 `course_put_result`）
—— 这两条属真正的 C1 范围。

#### 15.2 实测：1e6 默认上限本身会制造"超时"

`superloop` 在 `MAX_CYCLES=1e6` 下超时，放宽后 **1,984,114 拍正常完成**（退出值同样满足
`893 % 253 == 134`）。⇒ §14.4 把"超时"一律解释成"`remu` 化 0 后程序自旋"不成立：
**有一部分超时只是预算不足**，默认 1e6 拍下"超时"不等于"死锁"。

#### 15.3 实测：剩余 6 条是**核内死锁**，与 DIV/REM 无关，与 AXI 也无关

`hanoi`/`magic`/`multiarray`/`qsort`/`queens`/`tak` 六条与 15.2 的"预算不足"不同形：
把**官方镜像**（去掉开头 `#` 注释行）放进 `tb/top/prog/`，用 `tb_cpu_prog` 的**单元 TB 路径**
（`core/memory.v`，`MEM_LATENCY_TB=3`，**不经过 `mem_subsystem`/AXI**）跑：

```
$ ./sim/bench/bench +PROG=oj_tak +PERF=2000000 +DUMP=0
PERF: oj_tak cycles=2000000 commit=307 ipc=0.000 flush=27 branch=19
```

`commit` 从第 ~500 拍起**冻结在 307**；官方 `multiarray` 同形（冻结在 **922**）。
⇒ 死锁在**核里**，`mem_subsystem`/AXI 无罪。`+TRACE` 抓到的现场：

```
STALL: oj_tak cyc=20000000 issue=334 nobatch=67 flushcyc=54 misp=27 | block rob=0 rs=0 fl=19999545 lsq=0
T 650 pc=00000074 ... iss=0 hb=1 misp=0 flsh=0 halt=0 robh=19 robl=19 rdy=1 raw_h=fc4080e7
```

- **`fl=19999545`**（2e7 拍里 19,999,545 拍）⇒ 卡在**空闲物理寄存器不够**（`fl_count < n_wr`）；
  ROB / RS / LSQ 都不是瓶颈（`rob=0 rs=0 lsq=0`）。
- **`robh == robl == 19`** ⇒ **ROB 是空的**（`last` 是空槽位语义）；`rdy=1` / `raw_h=` 只是陈旧槽位内容。
- `cpu_top.v:542` 的提交使能含 `!rob_empty` ⇒ **ROB 空 ⇒ 无人提交 ⇒ 无人回收 preg**。
  成环：**池空 → rename 挡住 → ROB 空 → 提交停 → 池更空**，且 `flushing_r=0`（walker 也不会回补），永不自解。

#### 15.4 实测：这是**泄漏**，不是容量不够

用 §11.2 记录的 `iverilog -P` 消融口径，只改 `PRF_SIZE_TB`：

| 配置 | 2e5 拍时 commit | 1e6 / 2e6 拍时 commit | 判词 |
|---|---|---|---|
| `PRF_SIZE_TB=64`（默认） | **307**（已冻结） | 307 | 死锁 |
| `PRF_SIZE_TB=128` | 1854 | **仍是 1854**（`flush=177`） | **同样死锁，只是晚一点** |

⇒ 加大 PRF 只把死锁推迟，不能避免 ⇒ **是误预测在逐条抽干池子，不是容量不够**（具体漏点见 15.5）。

#### 15.5 根因（**已逐拍证实并修复**）：`set_last` 少加了 1，把误预测那条指令自己丢掉了

> ⚠️ **本节原稿（"漏点 = walker 回滚区间漏掉了 `fs`"）是错的，已按实测改写。**
> 原稿只看到"漏了一个 preg"，就认定 walker 少回滚了一条；把 walker 改成回滚 `[fs, walk_ptr]`
> 之后实测**仍然是死循环** —— 因为真正的错在**截断**那一侧。留此记录以免重蹈。

**真正的错点：`cpu_top.v:505` 的 `set_last_val = misp_fs_w`（正确写法须 `+1`）。**

rob.v 的 `last` 是**空槽位**语义（`cpu_top.v:600` 注释："last 是空槽位, 不可回滚"），
存活窗口是**左闭右开**的 `[head, last)`（rob.v:71 注释："窗口 [head, last)"）：
`free` 的算法 `d_f = last_after_last - head_after_last` 也印证了这点（初值 head=last=0 ⇒ 窗口 0 条）。
而 `execute_slot.v:162` 给出的是 `misp_fs = rob_tag`，**误预测指令自己的 tag**，不是"它后面那条"。
于是：

```
set_last = fs   ⇒  存活窗口 [head, fs)  ⇒  误预测的那条指令自己被丢掉
```

这在架构上是错的：**误预测只说明"它之后取的那串是错路"，它本身是一条必须提交的有效指令。**
丢掉它有两个后果，恰好就是 §15.3/15.4 观测到的两件事：

| 后果 | 机理 | 与实测的对应 |
|---|---|---|
| **功能性：`jalr` 的 rd 写丢失** | 指令不提交 ⇒ 它的 `ra`（返回地址）从未落进架构状态 | 官方题集用 `jalr ra,off(ra)` 做调用（`tak` 的 `0xb0`），这个目标取指期**不可能预测**（取决于本条的 rs1=ra）⇒ **每次调用必误预测 ⇒ 返回地址必丢** ⇒ 被调方 `sw ra,28(sp)` 存的是调用方 `auipc` 的值 ⇒ `ret` 回到 `auipc` 重来 ⇒ **死循环** |
| **资源：preg 泄漏** | 不提交 ⇒ `cmt_push_v`（`cpu_top.v:550`）永不触发 ⇒ 它占的 preg 没人回收 | free list 被逐次抽干 ⇒ §15.4 的冻结 |

> 为什么旧测试集（`tb/top/prog/*.data`）没暴露：那套用 `jal` 做调用（`tak` 实测 `jal=80755`）。
> `jal` 是 PC 相对直接跳转，取指期就能预测对 ⇒ 基本不误预测 ⇒ 不触发本条路径。

**逐拍证据**（官方 `tak` 镜像喂进 `tb_cpu_prog`，取到误预测当拍）：

```
T 1000502 pc=00000148 exp=00000144 ... rasops=10     # 在 0x144(ret) 处打拍: RAS 弹栈, 预测目标 0
T 1000503 pc=00000000 exp=00000000 f2v=1 raw=00008067 # 取指被预测带到 0x0 (RAS 空)
T 1000505 pc=00000008 ... misp=1                      # ret 在 0x144 执行, 真目标算出来
T 1000506 pc=000000ac ... flsh=1                      # 重定向到 0xac —— 不是 0xb4!
```

`0xac` 是调用方的 `auipc ra,0`。也就是说被调方存进 `28(sp)` 的 `ra` 是 **0xac 而不是 0xb4** ——
正是"`jalr` 的 rd 写丢失、`ra` 保持在 `auipc` 的值"的直接观测。
（对照：把 walker 改成回滚 `fs` 时，取到的仍是 `0xac`；这说明 walker 那侧加减 1 是在**加剧**同一个病，
不是病根 —— 它把误预测跳转的 rename 也一并撤了，而这条指令**不会重新执行**（重定向去的是它的目标，
不是它自己，见上面 `flsh=1` 那拍 pc 直接落到 0xac）。）

**修复（1 行，`cpu_top.v:510`）**：

```verilog
assign set_last_val = misp_fs_w + 1'b1;   // 保留误预测那条自身, 只截掉它后面取错的
```

改完两边自洽：存活窗口 `[head, fs+1)` 含 `fs`；walker 原式 `rem_w = walk_ptr_r - fs_eff_w`
覆盖 `fs+1 .. walk_ptr`，**恰好就是被截掉的错路集合**，原式本来就是对的，不必改。
这也与第 4 节 RS/LSQ 失效掩码的口径一致 —— 那里一直是严格大于（`> fs_sel`，只废"比它新的"），
即**设计意图本来就是保留误预测指令本身**，只有 `set_last` 这一处漏了 +1。

#### 15.5b 修复后的实测（同一套判据，全部可重跑）

| 判据 | 改前 | 改后 |
|---|---|---|
| `oj_tak`（官方镜像, TB 路径, `PRF=64`） | 冻结在 `commit=307`，`block fl=19999545/2e7` | `fl=0`，commit 线性增长（1.2e6@2e6 → 1.2e7@2e7），**1,722,145 拍跑完，返回 186** |
| `./build/sim correctness_tak`（官方通路） | 1e6/5e6 拍均 timeout | **PASS cycles=5626424 result=186**（= `expected.txt`） |
| 其余 5 条原死锁程序（官方通路, 2e7 拍） | 全部 timeout | 全部跑完，且 `result % 253 == expected.txt`（multiarray 8211%253=115 / hanoi 1196%253=184 / magic 12613%253=216 / qsort 1759696%253=81 / queens 127656%253=144）—— 即 §15.1 的"hash 全对、只差末尾 `remu`"签名 |
| `make test MAX_CYCLES=20000000` | （2 PASS / 17 FAIL，含 6 条死锁） | **3 PASS / 16 FAIL**，16 条**全部**可归因到缺 DIV/REM：2 条 timeout（`gcd`/`bulgarian`，main 里真有除法循环）、3 条非模数 mismatch（`basicopt1`/`pi`/`statement_test`，main 自身用 div）、11 条 `result % 253 == expected` |
| `make -f Makefile.tb run` | 14/14 TB 绿 | 14/14 TB 绿，0 FAIL |
| `tb_cpu_prog` 旧程序集（Verilator） | 18/18 PASS | **18/18 PASS**（另 `loopjal`/`loopld` 是 TB 声明的**无终止**微负载，本就不该 PASS，见 `tb_cpu_prog.v:8`） |

> 复跑旧程序集**不要用 Icarus**：`pi` 要 1.547e8 拍，按 §11 实测 ≈0.845 ms/拍 ⇒ 单程序 ≈36 小时。
> 用 `make -f Makefile.tb bench`（Verilator，≈716×）。

> ⚠️ `make test` 的默认 `MAX_CYCLES=1e6` 对这 5 条偏小（magic 1.97M / queens 1.30M / qsort 3.39M /
> tak 5.63M 拍）—— 1e6 预算下它们仍报 timeout，**那是预算不是死锁**（同 §15.2）。
> 本表用的是 2e7。
>
> ⚠️ **`make test` 的剩余 16 条现在才真正等于"缺 DIV/REM"** —— 这正是 §14.4 当初声称、而当时
> 并不成立的那句话。也就是说 **§14.4 的结论在本条修复之后才成立**。

#### 15.6 实测：`tb/top/prog/*.data` 与官方镜像是**两套不同的程序**

`tb_cpu_prog` 跑的那 18 个程序与 `testcases/correctness_*` **不是同一份镜像** ——
地址区间与体积都不同（`gcd` 440 B / 到 `0x119f` vs 官方 244 B / 到 `0xf3`；`tak` 484 B vs 380 B；
共同地址里逐字节相同的只有 4~6 个）。TB 那套是参考模拟器（RV32I）的旧测试集，
用 `0x0FF00513` 停机标记；官方这套用 MMIO 停机。

⇒ **§11.3 的"Verilator ≡ Icarus 16/16 逐字段相同"只对旧测试集成立，不能给官方 19 条背书。**
（`tb_cpu_prog` 的 MMIO 停机通路本身是好的：官方镜像放进 TB、`sw_ready` 恒 1 时，
`cpu_top.v:614` 的 `mmio_exit` 正常抬起 —— 本节 15.3 的数据就是靠它拿到的。）

#### 15.7 待办（C1 的前置）

1. ✅ **修 15.5 的 `set_last` 截断** —— 已落地（`cpu_top.v:510` 一行），验收全过（见 15.5b）。
2. ✅ **重取 `make perf` 基线** —— 曾经 `perf` 目标直接 `SystemExit`，**6 个 IPC 一个都取不到**
   （§14.2 的"不把 IPC 当判据"掩盖了这一点）。归档时先发现 `perf_qsort` 是**另一个独立缺陷**
   （§15.8），修完才真正可测：**6 点基线已取到（15.9 末表，geomean 0.3484）**，
   G4 从此有基线可比。
3. 之后 C1（DIV/REM）的 G2 才有意义：修完上面两条后，失败的**才真正**全部等于"缺 DIV/REM"，
   即 **19/19 = 15.5 修复 + 15.9 修复 + C1**，单靠 C1 达不到。
   （数目随 `MAX_CYCLES` 变：默认 1e6 拍下 **2 PASS/17 FAIL**，2e7 拍下 **3 PASS/16 FAIL**
   —— 多出来的是 `gcd`/`bulgarian` 这类**真除法循环**超时，不是别的错。）

#### 15.8 `make perf` 基线：从"取不到"变成"6 取 5"，剩一个**独立**的存储通路缺陷

§15.5 修完后 `perf` 不再 `SystemExit` 在前两个点上，可以真跑了：

```
$ make CONFIG=config.local.mk perf        # MAX_CYCLES=1e6, LATENCY=10 (官方默认口径)
benchmark                  instructions       cycles        IPC
perf_median                        6961        28141     0.2474
perf_multiply                     21722        37979     0.5719
perf_qsort: exit result mismatch: expected 0, actual 541     ← SystemExit, geomean 仍打不出来
```

`perf_qsort` 是**真错**（6 个 perf 程序 **div/rem 全为 0**，与缺 C1 无关）。定位如下：

| 观测 | 结果 |
|---|---|
| 同一镜像走 **TB 路径**（`core/memory.v`，不经 `mem_subsystem`/AXI） | `PASS: oj_pqsort ret=0 cycles=228073` ✅ |
| 官方路径 **latency 扫描** `./build/sim ... <LAT>` | L=1 `PASS 0` / L=2 `FAIL 667` / L=3 `FAIL 541` / L=5 `FAIL 541` / L=10 `FAIL 541` |
| 6 个 perf 程序 **L=1** | 全 PASS |
| 6 个 perf 程序 **L=10**（官方口径） | **5 PASS**（median / multiply / rsort / towers / vvadd），只 `qsort` FAIL |

**判词**：这是**官方存储通路（`mem_subsystem` + AXI）里一个与延迟相关的缺陷**，被 qsort 的访存模式触发：

- **不是** §15.5 的冲刷逻辑 —— L=1 与 L=10 跑的是**同一条指令流**（误预测/冲刷次数相同），
  只有访存时序不同；L=1 全绿而 L≥2 出错 ⇒ 变量在存储侧。
- **不是**缺 DIV/REM —— 这 6 个程序 div/rem 计数为 0。
- **不是** fetch 侧 —— 出错的是 `main` 比对的**数据**（返回 541 = 第 540 个 word 不匹配，
  见 `perf_qsort/program.S:214-234` 的比对循环），不是控制流。

⇒ **`make perf` 的 6 点基线目前只能取到 5 个**；`testcase.py` 在第一个失败点 `SystemExit`，
所以**几何平均仍然打不出来**。G4（"6 个 IPC 逐位相同"）在这个缺陷修掉之前**依然不可测**。

> 待办（独立于 C1）：修 `mem_subsystem`/AXI 的延迟相关访存缺陷。 **→ 已修，见 15.9。**

#### 15.9 修复：store 队列合并**按槽号遍历**（应为按年龄）——§15.8 的缺陷（2026-09-27）

**根因**（`mem_subsystem.v` 的 `sq_merge_byte_f`）：函数头注释写的是"扫队列 (**由老到新**, 后者覆盖
前者 ⇒ 最年轻胜)"，但循环用的是**绝对槽号** `m = 0 .. SQ_DEPTH-1`，胜者 = 匹配槽中**槽号最大**者。
而三指针 `sq_wr_p/sq_snd_p/sq_ret_p` 是**自由跑的回绕计数器**：队列一旦绕过一圈，
**低槽号反而是更年轻的条目** ⇒ 胜者变成**最老**的 store，载入结果被改写成一个过期值。

- 两个条件同时成立才触发：①队列已回绕（`ret_p > wr_p`）；②≥2 条存活条目覆盖同一字节。
  穷举 `ret_p × occ × 年龄对`：**126 种指针状态可触发**（脚本一次跑完，非抽样）。
- 对照 `lsq.v` 的 `merge_byte_f`：它显式算年龄 `(j - hd) & (LSQ_SIZE-1)` 取最大 —— 同一个道理，
  那边写对了，这边漏了。**"由老到新"的注释是对的，是代码没做到**。

**修复**：把遍历改成按年龄 —— 函数新增 `q_ret` 入参（`sq_ret_p`；必须走参数是因为
iverilog 对连续赋值里的函数只按参数建事件依赖，见该处注释），循环体 `s = q_ret + m[SQ_IW-1:0]`
（截断即取模），四个调用点各加一个实参。**改动 = 1 个函数 + 4 个调用点，不碰任何时序逻辑。**

**为什么 L=1 掩盖了它**：L=1 时 B 很快回来，队列长期驻留 0~1 条 ⇒ 条件①②都难成立
（实测加不加修复都 PASS）。这是**解释**，不是独立测量；测得的是下面这张 A/B 表。

**A/B 证据**（同一份 RTL，只回退那一行索引）：

| 官方路径 `./build/sim testcases/perf_qsort/program.data` | 按槽号（旧） | 按年龄（修复） |
|---|---|---|
| L=1 | PASS result=0 | PASS result=0 |
| L=2 | **FAIL result=667** | PASS result=0 |
| L=3 | **FAIL result=541** | PASS result=0 |
| L=5 | **FAIL result=541** | PASS result=0 |
| L=10 | **FAIL result=541** | PASS result=0 |

旧行的五个结果与 §15.8 记录的**逐位相同**（667/541/541/541）⇒ 因果闭合，不是别处的偶然。

**新增回归测试** `tb/core/tb_mem_axi.v` 的 **T7**：先让 5 条 store 走完全程（`wr=snd=ret=5`），
再压住写通道推 6 条**同址** store ⇒ `wr=(5+6)%8=3 < ret=5`，**构造成回绕态**并把 6 条压在同一字节上，
要求合并取最后那条。**加了断言钉住前置条件**（`ret_p===5 && wr_p===3`），
避免哪天指针初值一变、测试悄悄退化成"没在测回绕"。
验证：带修复 PASS；**回退修复后报 `FAIL: T7 wrapped queue must yield the youngest store`**（
反过来验过，不是只在新代码上绿）。

**验收（全部实测）**：

| 判据 | 结果 |
|---|---|
| `make -f Makefile.tb run` | **14/14 ALL TESTS PASSED**（含新 T7） |
| `make test`（默认 1e6 拍） | 仍 **2 PASS / 17 FAIL**，通过的两条仍是 `add_to_100`/`lvalue2` ⇒ **无回归**；17 条仍是缺 DIV/REM（C1 的范围） |
| `make build` | 干净，**无 UNOPTFLAT** |
| `make perf` | **不再 SystemExit，6 点全出、geomean 打得出** |

**G4 基线（本条修完后才第一次真正可测，LATENCY=10 / MAX_CYCLES=1e6）**：

```
benchmark                  instructions       cycles        IPC
perf_median                        6961        28141     0.2474
perf_multiply                     21722        37979     0.5719
perf_qsort                       139900       551402     0.2537
perf_rsort                       195719       655666     0.2985
perf_towers                        5278        18785     0.2810
perf_vvadd                         4524         7616     0.5940
GEOMEAN                                                  0.3484
```

`perf_median`（6961/28141）与 `perf_multiply`（21722/37979）与 §15.8 **逐位相同**（指令数与周期数
两项都相同）⇒ 修复只动了 qsort（唯一把队列压到回绕且同字节重叠的程序），其余 5 个点未被扰动。
**这 6 个数就是 C1 的 G4 基线。**

### 15.10 C1 实施记录：DIV/DIVU/REM/REMU（2026-09-27）

范围按 §12.3(乙) 的结论收窄：**LB/LBU/LH/LHU 本来就已实现**（证据见文首"收口"表的注），
C1 的真实代码工作量只有 DIV/DIVU/REM/REMU 四条。分 4 步提交（除法器 → 译码发射接线 →
自造角例程序 → 本节文档）。

#### 15.10.1 为什么只能是多周期

§12.3(乙) 的预判在 §13.5 拿到实测支持：`mul` **自身**的 F2F = **2.0879 ns**，500 MHz
（2.0 ns）已超预算、400 MHz（2.5 ns）也吃掉 83.5%。单周期组合除法器的 32 级借位链会**叠在**
这棵华莱士树**后面** ⇒ 几乎必然跌破 300 MHz 硬性前提。故取 **radix-2 迭代，33 拍**
（32 次迭代 + 1 拍输出）：每拍只有"33 位比较 + 33 位加减 + 移位 + 2:1 mux"，**不进关键路径**。

#### 15.10.2 在飞协议（照抄访存飞行槽那一套）

| 环节 | 机制 |
|---|---|
| 发起 | `execute_slot` 导出 `div_start_req/op/a/b/prd/rob_tag`；`cpu_top` 门控后由 `div.v` 锁存 |
| 释放 RS | `rs_clear_valid = sel_valid & ~pipe_stall` —— **没被收下就不清条目**（清了这条指令再也不会被选中 ⇒ 死锁）。§15.10.13 把原来这个由 `div_hold_w` 单独承担的"扣住"职责**收敛成一条统一的 Q 级冻结信号**（`pipe_stall = flush_win \|\| (sel_valid_q && is_div && !div_accept) \|\| flush_hit`），div 只是它的一个来源 |
| 不广播 | `exec_valid = sel_valid_q && !is_load && !is_div`（否则当拍广播一个占位结果并把 ROB 置就绪） |
| 写回 | CDB 新增**槽 W+1**（槽 W 是 load 完成），`prf` 写口 +1，`rt_set_req`/`rob_ready_req` 各加一路 |
| 旁路 | 槽 W/W+1 **不参与同拍旁路**：`ready_table` 是寄存器，被唤醒的依赖者最早下拍才被选中，那时 PRF 已写入 ⇒ `rs`/`execute_slot` 的 `cdb_tag`/`cdb_slot_valid` 宽度**不变** |
| 作废 | `div_kill`（见 15.10.3） |

`rs.v` **完全不用改**：条目在发起当拍就被清（与 load 相同），身份改由 `div.v` 内部锁存。

#### 15.10.3 kill 判据

与本文 §4 的 rs/lsq 失效掩码**严格同口径**（"年龄 > 生效冲刷点 ⇒ 错路"），但**每拍评估**：

```verilog
assign div_kill = (misp_valid || flushing_r)
               && ((div_fly_rob_tag - rob_head_w) > (fs_eff_w - rob_head_w));
```

`div_fly_rob_tag` 是 `div.v` **内部锁存**的 tag（为此新增输出 `busy_rob_tag`）——发起当拍
RS 条目就已释放，`cpu_top` 侧没有别的副本。误预测当拍该 div 可能**就已经在飞**（乱序：更老的
误预测分支后执行），拖到 walker 拍才杀既多浪费一拍，又可能赶上"walker 当拍就走完"⇒ 掩码对
"已不在 rs 里"的在飞 div 无从下手。

#### 15.10.4 与批准计划的 5 处偏差

| # | 计划 | 实际 | 为什么 |
|---|---|---|---|
| 1 | radix-2 **非恢复**余数 | radix-2 **恢复**余数 | 恢复式 R ∈ [0,\|b\|) ⇒ `Rs = {R, A[31]}` 33 位**无符号**即可，不需要 34 位有符号中间量、也不需要末尾修正步。可观测契约（33 拍 / 面积量级 / 不进关键路径）两者相同 |
| 2 | `rob.v` 新增输出 `set_last_clear_all` | **不加**（`rob.v` 零改动） | 按计划的 `set_last_val = misp_fs + 1` 推，`keep_head` 恒真 ⇒ 该输出是常量 0 的死逻辑；而 `set_last_val` 在 ROB 满时有回绕边界 |
| 3 | kill 在 `set_last_valid` 当拍评估一次 | 每拍评估的年龄比较 | 见 15.10.3 |
| 4 | 未提 | **冲刷中禁止发起**（`div_go_w` 含 `!flushing_r`） | 反例：walker 首拍被选中的错路 div 若当拍启动，而 walker 可能**同拍就走完** ⇒ 下拍不再有 kill 拍，该 div 33 拍后写一个**已被 free_list 回收**的 preg ⇒ 写坏架构状态 |
| 5 | W>1 靠 `~(is_div & div_busy)` 覆盖 | **只有槽 0 能启动** | 计划的机制**不成立**：`div_busy` 是寄存器，发起当拍仍为 0 ⇒ 两个槽会同拍启动、后一发覆盖前一发。改为 `div_go_w = div_req_w[0] && !div_busy && !flushing_r`。W>1 的正确性靠 `rs.v` 的 W 级年龄仲裁是**稠密前缀**（第 k 级能选出候选 ⇒ 第 k-1 级必然也选出）⇒ 槽 0 每拍都在推进（启动或扣住后重选）⇒ 高槽的 div 必然在有限拍内移到槽 0。代价仅 W>1 的吞吐 |

#### 15.10.5 验收（G1–G5）

| 判据 | 实测 |
|---|---|
| G1 `make -f Makefile.tb run` | **15/15 `ALL TESTS PASSED`，0 `TESTS FAILED`**（原 14 + 新增 `tb_div`） |
| G2 `make test` | **19/19 PASS** —— 须把上限抬到 1e8。§15.2 已经指出 1e6 默认上限本身会制造"超时"（光是 `tak` 就有 122 万条动态指令 ⇒ 命令行下报 7 条**假失败**），而 `config.mk:47` 的官方值就是 1e8。框架 `MAX_CYCLES ?= 1000000`（`Makefile:28`）是唯一来源 ⇒ 已在**本机 `config.local.mk`**（已 gitignore）里写死 `MAX_CYCLES = 100000000`，**官方 `config.mk` 一字未动**（实测：不带 `CONFIG=` 时仍为 1000000） |
| G3 自造角例程序 | 见 15.10.6 |
| G4 `make perf` | **6 个 IPC 与 §15.9 基线逐位相同**（0.2474 / 0.5719 / 0.2537 / 0.2985 / 0.2810 / 0.5940，几何平均 **0.3484**）⇒ 除法器接进来**没有扰动核心路径**。这 6 个程序的 div/rem 计数均为 0，所以这是干净的 A/B |
| G5 `make build` | 无 `UNOPTFLAT`（`grep -c` = 0） |

> `make build` 里有一条 `SYNCASYNCNET`，指名 `u_div.rst_n`，但**不是本次引入的**：把 `u_div`
> 从设计里摘掉后，同一条警告移到 `u_front.u_bht.rst_n`。本设计的 `rst_n` 是**单网**同时喂异步
> 复位（rob/rs/rat/ready_table/div）与同步复位（prf/lsq/free_list/ras/bht）的模块，Verilator
> 只是挑一个实例报。判据只要求无 `UNOPTFLAT`。

#### 15.10.6 自造角例程序（G3）

**为什么必须自造**：官方 19 条 correctness 里 div/rem 只出现在 `gcd`/`bulgarian`/`pi` 的算法除法与
`course_put_result` 的 `remu % 253` —— 商次遍布正常路径，但**除零与 `INT_MIN/-1` 溢出一次都不出现**，
而这两类恰恰是 `div.v` 里唯二需要**显式 mux**（不能靠迭代自然得出）的地方。
即"官方全过"并不能证明它们对。本程序专补这两类 + 四象限符号 + 边界。

| 文件 | 作用 |
|---|---|
| `tb/top/div_corner.s` | 25 对操作数 × {div, divu, rem, remu} = **100 个结果**，累加进 `a0`，末尾 `sw a0, 0(0x80000000)` |
| `tb/top/div_corner_expect.py` | 从 `.s` 的 `pairs` 表**按 RISC-V 语义独立算**期望值（不取自仿真输出——否则是自证）。脚本断言每一条 `.word` 都被解析到，防漏读 |
| `tb/top/bin2data.py` | 裸二进制 → 官方 `program.data` 文本格式（`objcopy -O binary` 的产物） |
| `tb/top/div_corner.data` | 生成物，312 字节 `@00000000` |

覆盖：`100/7`、`7/100`、`±7/±2` 四象限、`-1/1`、`1/-1`、`-1/-1`、
**除零**（`100/0`、`0/0`、`-1/0`）、**`INT_MIN/-1`**、`INT_MIN/±1/±2/INT_MAX/INT_MIN`、
`INT_MAX/-1`、`INT_MAX/INT_MIN`、`0/5`、`0/-1`、`1/INT_MIN`、`0x12345678/0x9ABCDEF0`（双向）、
`15/16`、`16/16`。

**走 `make run`，即真实 `student_top` + AXI + MMIO 通路**（与判分口径一致），不用 `tb_cpu_prog` 的旧 8 位通路：

```
EXPECTED=3557883290 (0xd410fd9a)
PASS cycles=3378 result=3557883290 expected=3557883290
```

##### 累加器为什么是 `a0 = a0*31 + r` 而不是异或

**异或累加在这个程序上不可判伪**：同一个错值出现偶数次会自己抵消。这不是推测——把 `div.v` 的
除零商从 `32'hFFFF_FFFF` 改成 `32'h0000_0000`（程序里 6 处除零）后，**异或终值一字不变**，
而 `a0*31+r` 立刻报错。31 是奇数 ⇒ `31^k` 在 mod 2^32 下可逆 ⇒ **任何一个结果错，终值必不同**。

##### 判伪能力由 RTL 变异实测（不是靠推理）

| 版本 | 结果 |
|---|---|
| 正常 | `PASS cycles=3378 result=3557883290 expected=3557883290` |
| `div.v` 除零商 `32'hFFFF_FFFF` → `32'h0000_0000` | `FAIL cycles=3378 result=3572143610 expected=3557883290` |
| 还原（`git diff` 空）后复跑 | 再次 PASS |

> 期望值来自 `.s` 的 `pairs` 表 + 独立语义模型，**不取自仿真**；变异实验证明程序能分辨。
> 两者合起来才构成 G3 的证据，单有"跑过了 PASS"只是自证。

#### 15.10.7 T4：整机综合（首次拿到真核数字）—— **假设被证伪**

计划里 T4 的预判是"`div.v` 理论上不进关键路径，复核一下"。**实测证伪**：它确实在关键路径上。

**怎么跑通的**：C8b 一直阻塞在"必须先清掉 `core/memory.v`（C7）"。实际上 `student_top`/`cpu_top`
**都没有例化它**（只有 TB 用），`hierarchy -top student_top` 会剪掉 —— 只是 Verilog frontend 仍要
花几分钟把 64 KB 阵列展开成 RTLIL。故本次用一个**临时 filelist**（仅少 `core/memory.v` 一行，
`grep -v '^core/memory\.v$' verilog/filelist.f > verilog/filelist_t4tmp.f`）绕开，**官方
`verilog/filelist.f` 一字未动**；网表等价性已验：`mapped.v` 里 `memory`/`mem_r` 出现 **0** 次。

```sh
docker run --rm -v "$PWD":/work -w /work cpu2026:local \
  make synth MODE=opt FILELIST=verilog/filelist_t4tmp.f SYNTH_OUT=build/synth_t4
```

**A/B（唯一改动：`cpu_top.v` 的 `assign div_go_w = 1'b0;`）** —— 常量 0 使 `busy_r` 恒 0
⇒ `done_valid` 恒 0 ⇒ ABC 把整个除法子系统（含 CDB 的 div 槽与输出侧）一并折叠掉：

| 运行 | 总面积 µm² | 组合 | 时序 | **最小周期** | **F_max** | 关键路径门数 |
|---|---:|---:|---:|---:|---:|---:|
| **有 div**（当前 RTL） | 11,475.947 | 7,505.259 | 3,970.688 | **30.7861 ns** | **32.48 MHz** | 246 |
| **无 div**（A/B） | 10,992.678 | 7,099.702 | 3,892.977 | **18.2822 ns** | **54.70 MHz** | 244 |
| 差 | 483.269 | 405.557 | 77.711 | **−12.5039 ns** | +22.22 MHz | — |

⇒ **除法子系统在关键路径上值 12.50 ns**。这是 C1 引入的真实代价，T4 的"不进关键路径"预判不成立。

**但更重要的发现是"没有 div 也才 18.28 ns"**：关键路径 244 级、F_max 54.7 MHz，
离 **≥300 MHz 硬性前提**差 5–9 倍。这条**不是 C1 造成的**，是整机（RS 年龄仲裁 + 操作数 mux +
执行 + CDB + PRF 写口，以及穿到 `mem_subsystem` 的组合通路）本来就有的长链，
属于 **C8b 的范围**。

**测量口径的保留意见（重要，别当真值用）**：

1. 该流程**不做扇出修复**：`mapped.v` 里 `BUF*` 单元 **0 个**（只有 9,106 个 `INVx1`），
   而关键路径起点是一个 **扇出 482** 的触发器（其后再经一个扇出 262 的 `INVx1`），
   **仅头两级就吃掉 2.76 ns**（`_214779_/QN` 1.0670 + `_173285_/Y` 1.6911）——纯粹是
   未加缓冲树的慢沿退化。另有 4,935 个 `TIEHIx1`。
   "扇出 482 的 x1 触发器"很像 `synth -flatten` 期间 `opt_merge` 把等价触发器合并的产物
   （483 个负载几乎全在 `A2`/`B` 数据脚上），**未证实**，列为 C8b 的待查项。
2. 因此**绝对值偏悲观**，"有 div / 无 div"的**相对差 12.50 ns 才是可信的部分**
   （同流程、同 ABC 参数、确定性流程，差异远超启发式噪声）。
3. 容器只有 3.9 GiB 内存，`BUILD_JOBS=2`，与官方机器不同。

**结论与后续（超出 C1 范围，待定）**：`div.v` 的组合深度来自三处 32 位加减
（输入侧 `a_abs_w`/`b_abs_w` 各一个取负，输出侧 `q_fix_w`/`r_fix_w` 取负）
外加迭代拍内的 33 位比较 + 33 位减法。可选方向（**未实施，未验证**）：
把取负挪到锁存**之后**（省掉输入侧两级 32 位加法器）、输出侧改成"商的符号位与
迭代结果分开算"、或把 33 位比较与减法合成一条链共享进位。**均为猜想，没有实测支撑。**

#### 15.10.8 频率归因：**官方流程不做扇出修复** + 真逻辑深度本身就超预算

§15.10.7 留的待查项是「扇出 482 的 x1 触发器很像 `opt_merge` 的产物，**未证实**」。
本节把它查完了，结论比预想的严重：**32.48 MHz 的 84% 是"高扇出 × 无缓冲"，
但把高扇出完全清零后，剩下的真逻辑本身仍要 5.01 ns ≥ 3.33 ns（300 MHz 预算）。**

**方法**（全部只读，未改任何 RTL 与官方脚本）：① `MODE=diagnose`（`-hieropt`，保留层次，
扇出可归到模块）；② 逐级解析 `timing.rpt` 的 `Fanout`/`Delay` 两列；③ 在**宿主 yosys**
上重跑到 **ABC 之前**的网表（`synth -top student_top -noabc -flatten`，见 `/tmp/fanout.ys`）
—— 此时 RTL 信号名还在，可反查每条高扇出网的真实来源。

##### 发现 1（根因，已证实）：官方 `abc` 调用缺 `-constr`，`buffer`/`upsize` 根本不在脚本里

`scripts/synth.py:109` 拼出的命令行是：

    abc [-exe <abc>] -liberty <5 个库> -D <clock_period*1000>

**全文件没有 `-constr`**（`grep -n constr scripts/synth.py` 无命中）。而 Yosys 的 `abc`
pass 按此二选一（`yosys -Q -p "help abc"` 原文）：

| 条件 | ABC 脚本 |
|---|---|
| `-liberty` **无** `-constr` | `strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf {D}; &put` |
| `-liberty` **有** `-constr` | 同上 **`; buffer; upsize {D}; dnsize {D}; stime -p`** |

⇒ 官方流程跑的是**第一行**：不做扇出修复、不做驱动强度优化、不做尺寸调整。
**这就是 `mapped.v` 里 `BUF*` = 0 的真正原因** —— 不是 `opt_merge`、也不是 ABC 的 bug，
而是脚本选择规则（另注：ASAP7 库有 12 个 `BUFx*` 单元，且只声明了 `default_fanout_load : 1`、
**没有** `default_max_fanout`）。
`scripts/` 属官方（勿改），判分跑的就是这一个 ⇒ **此路不可绕，只能从 RTL 侧降扇出。**

##### 发现 2：延时就是扇出 —— 84% 的延时压在 13% 的级数上

`build/synth_t4/opt/timing.rpt` 的 5 条路径共 610 级 / 153.66 ns：

| 每级扇出 | 级数 | 总延时 | 占比 | 平均 ps/级 |
|---|---:|---:|---:|---:|
| 1–15 | 530 | 25.05 ns | 16.3% | **33–58** |
| 16–31 | 25 | 26.38 ns | 17.2% | **1055** |
| 32–63 | 20 | 4.16 ns | 2.7% | 208 |
| 128–255 | 15 | 22.14 ns | 14.4% | **1476** |
| 256–511 | 10 | 13.79 ns | 9.0% | **1379** |
| ≥512 | 10 | 62.15 ns | 40.4% | **6215** |

**扇出 ≥16 的 80 级（13% 的级数）吃掉 128.61 ns = 83.7%。** 同一个门：扇出 1–15 时 47 ps，
扇出 ≥512 时 6215 ps —— **130 倍**。纯负载/慢沿退化，与逻辑深度无关。

只看关键路径（路径 1，30.7861 ns）：**共 122 级**，其中扇出 ≥16 的 **16 级 = 25.72 ns（83.6%）**，
扇出 <16 的 **106 级 = 5.01 ns（平均 47.3 ps/级）**。最热 10 级：

| 单元 | 类型 | 扇出 | 延时 |
|---|---|---:|---:|
| `_122420_/Y` | `O2A1O1Ixp33` | 1029 | **6552 ps** |
| `_193915_/Y` | `NAND2xp33` | 1017 | **5877 ps** |
| `_146053_/Y` | `OAI21xp33` | 25 | 4601 ps |
| `_148246_/Y` | `NOR2xp33` | 210 | 2293 ps |
| `_173285_/Y` | **`INVx1`** | 262 | 1691 ps |
| `_193900_/Y` | `AOI22xp33` | 138 | 1342 ps |
| `_214779_/QN` | `DFFASRHQNx1` | 482 | 1067 ps |
| `_177983_/Y` | `NAND2xp33` | 145 | 792 ps |

注意 `_173285_` 是**最小号的 `INVx1` 驱动 262 个负载** —— 这正是"没有 `upsize`"的直接指纹。

##### 发现 3（关键）：高扇出是**真实 RTL 结构**，不是 ABC 的产物

**事前**网表（ABC 之前）已经有扇出 1172 / 1156 / 1059 / 1041 / 1026 / 900 的网，
而且**信号名还在**。逐条查它们驱动什么 —— **全部是 `$_MUX_` 的选择脚**：

| 网（事前网表原名） | 扇出 | 其中 `$_MUX_.S` | RTL 来源 |
|---|---:|---:|---|
| `u_cpu.slt[0].u_slot.sel_idx[0]` | 1156 | 1152 | RS 仲裁胜者索引广播 |
| `u_cpu.slt[0].u_slot.prs2[0]` | 1059 | 1056 | RS 槽操作数标签广播 |
| `u_cpu.u_prf.rd1_preg[0]` | 1026 | **1024** | `prf.v:18` `regs[rd1_preg]` |
| `u_cpu.u_rob.head_r[0]` | 900 | 896 | ROB 头指针 → 每项年龄比较 |
| `u_cpu.cmt[0].cmt_lsq_tag[0]` | 532 | — | 提交端口 LSQ 标签 |
| `u_mem.imem_addr_q[2]` | 531 | — | 取指预取窗口比较 |

**1024 是精确吻合**：`PRF_SIZE = 64` ⇒ 每个输出位一条 64:1 mux 链，位 0 落在 32 个一级
mux 上，× 32 位 = **1024**。⇒ 这不是流程缺陷，是**"组合数组读"的必然结果**。

**第一大户也查到了名字**：`mapped.v` 里扇出 1029、值 6552 ps 的 `_122420_`，在**事前网表
里同名 cell 是 `$_MUX_`，A 脚接 `\u_mem.sq_data_r [47]`** —— 即 `mem_subsystem.v:271` 的
**已提交 store 队列数据寄存器的读出 mux**（`SQ_DEPTH=8`，但读出逻辑按 load 端口**复制了
多份**，见 `mem_subsystem.v:333-337` 的 `ld_raw_w[7:0] / [15:8] / [23:16]` 多实例）。

##### 发现 4：按模块归属，扇出**遍布全设计**（没有单点可修）

事前网表里扇出 ≥16 的网按层次归属（"总负载" = 这些网驱动的全部负载）：

| 归属 | 高扇出网数 | 总负载 | 峰值扇出 |
|---|---:|---:|---:|
| 匿名 `_NNNNN_`（`synth` 产生） | 859 | 59,063 | 1172 |
| `u_mem`（mem_subsystem + axi） | 328 | 15,276 | 531 |
| `u_cpu.slt[0]`（execute_slot） | 141 | 9,717 | 1156 |
| `u_cpu`（cpu_top 本体） | 95 | 5,962 | 277 |
| `u_cpu.u_lsq` | 34 | 2,764 | 391 |
| `u_cpu.u_rt`（ready_table） | 63 | 2,142 | 34 |
| `u_cpu.u_prf` | 6 | 2,028 | **1026** |
| `u_cpu.u_rs` | 65 | 1,801 | 73 |
| `u_cpu.u_rob` | 7 | 1,793 | **900** |
| `u_cpu.u_fetch` | 14 | 1,028 | 271 |
| `u_cpu.cmt[0]` | 4 | 1,025 | 532 |

##### 结论：两层都要治，且**只治扇出到不了 300 MHz**

- **流程层（83.6% 的延时）**：峰值扇出 1000+ 的广播网 × 官方流程无缓冲无 upsizing。
- **RTL 层（剩下的 16.4%）**：关键路径 **122 级真逻辑**，其中 106 级"健康"级
  （扇出 ≤15、平均 47.3 ps）合计 **5.01 ns**。

**关键推论（可证伪）**：就算高扇出的 16 级**完全不要钱**，106 级健康逻辑本身也是
**5.01 ns ≥ 3.33 ns**，即**已超 300 MHz 预算 1.5 倍**。⇒
① 单靠"降扇出"（one-hot + AND-OR 读端口、广播网本地重译码、store 队列读出不再按端口复制）
   **到不了 300 MHz**；② 单靠"减深度"也得先解决扇出，否则优化根本落不到关键路径上。
**两个方向必须同时做，且都要动 `prf`/`rob`/`rs`/`lsq`/`rat`/`mem_subsystem` 的核心数据结构。**

> **口径提醒**：本节所有数字都出自**同一个官方流程**（含"缺 `-constr`"这一事实），
> 与 §15.10.7 的 32.48 MHz 同源、可直接对比。**没有做"补上 buffer 再测一次"的对照实验**
> —— 那个数只对诊断有意义，判分永远跑官方脚本，报出去只会误导（见记忆：不为文档数字新跑实验）。

##### 副产品：FakeRAM 通路是通的，只是没东西可映射

`build/synth_t4/opt/ram/manifest.json` 里 `"configurations": []`、`"macros": {}`
⇒ 全设计**没有推断出任何存储器**，`SRAM: 0.000 um^2` 属实。原因是本设计的"存储"
（PRF/ROB/RS/LSQ/RAT）全是**多端口组合读的触发器阵列**，既没写成 SRAM 宏、
也不可能映射成单/双口 SRAM。FakeRAM 估算参数已就位
（`area_per_bit_um2 = 0.0419904`、`clock_to_q = 0.071262 + 1.67e-5*depth + 1.24e-3*width` ns），
若日后要做 SRAM 化的 PRF/ROB，这条通路可直接复用。

##### 顺带修掉的缺陷：`branch.v` 的空 `.cout()` 弄崩 `opt_hier`（`6f4203c`）

`MODE=diagnose` 首次运行即失败：`ERROR: Port cout connected on instance ujal not found
in module adder32 or width is not matching`（pass `OPT_HIER`）。根因是 `opt_hier` 会按实例
特化 `adder32`，特化变体没有 `cout`，而 `branch.v` 的 `.cout()` **空连接仍引用它**。
已在宿主 yosys 上最小复现并确认：只有显式 `.cout()` 触发、**省略端口不触发**（语义等价）。
修后 `MODE=diagnose` 可跑通 —— 即官方推荐的诊断路径（`description.md:347`）恢复可用。

#### 15.10.9 频率优化方案：**一个写法（`array[idx]`）同时造成了扇出与深度**

§15.10.8 把 84% 的延时归到了扇出，但留了个必须回答的问题：**剩下那 5.01 ns 是什么？**
本节查明：**扇出之外没有"第二个大户"，而扇出与深度其实是同一个写法的两种症状。**

##### 一、扇出之外的 5.01 ns：没有坏结构，就是级数多

opt 关键路径上扇出 <16 的 106 级，**全部**是 ASAP7 标准复合门，平均 **47.3 ps/级**
（≈2×FO4，ASAP7 7.5T 的正常水平）：

| 单元 | 级数 | 平均 ps/级 |
|---|---:|---:|
| `OAI21xp33` / `A2O1A1Ixp33` / `O2A1O1Ixp33` | 35 | 33–41 |
| `AOI21xp33` / `OA21x2` / `AO21x1` | 23 | 38–49 |
| `NOR2xp33` / `NAND5xp2` / `NOR4xp25` / 其余 | 48 | 27–81 |

**不是门慢，是级数多。**

级数按模块分布（`build/synth_diag/diagnose/timing.rpt`，`-hieropt` 保留层次，
路径 167 级 / 49.671 ns）：

| 模块（含子模块） | 级数 | 延时 | 占比 |
|---|---:|---:|---:|
| `u_cpu/slt[0].u_slot`（execute_slot + alu + branch） | 40 | 25.394 ns | 51.1% |
| **`u_cpu/u_rs`** | **71** | 12.289 ns | 24.7% |
| `u_cpu/u_prf` | 6 | 4.722 ns | 9.5% |
| `u_cpu`（cpu_top 胶合逻辑） | 12 | 3.610 ns | 7.3% |
| `u_cpu/u_lsq` | 32 | 2.447 ns | 4.9% |
| `u_mem` | 6 | 1.208 ns | 2.4% |

**深度集中在 `u_rs` 的 71 级**（`u_slot` 那 40 级里有一半是它接在 rs 后面的
操作数旁路 + ALU + 分支判定）。

##### 二、统一根因：组合数组索引读 `array[idx]`

§15.10.8 列的四个高扇出大户**不是四件事，是同一个写法的四次出现**：

| 位置 | 索引读 | 数组规模 | 实测峰值扇出 |
|---|---|---|---:|
| `execute_slot.v:67-79` | `rs_entry_xxx[sel_idx * W +: W]`（13 条字段） | 16 项 × ≈149 位 | **1152** |
| `prf.v:18` | `regs[rd1_preg]` | 64 项 × 32 位 | **1024** |
| `rob.v` | 32 个并行 `rob_r[i] - head_r` 的年龄减法 | 32 项 × 5 位 | 896 |
| `mem_subsystem.v:209-210` | `pf_tag_r[dem_idx * 32 +: 32]` | 16 项 × 32 位 | 531 |
| `lsq.v:294-296` | `is_unsigned_r[mem_done_idx]` | 16 项 | — |

**为什么必然高扇出**：N 选 1 的 mux 树里，索引**最低位**出现在最宽的一级 ——
每个输出位 8 个 mux（N=16）、32 个 mux（N=64）。故最低位的扇出 = `(N/2) × 位宽`。
`execute_slot` 那处：`8 × 149 ≈ 1192`，**与实测 1152 吻合**。
⇒ 这不是写法差错，是**索引读的固有代价**，只是官方流程不做缓冲（§15.10.8 发现 1）
把它从"多花几个缓冲器"放大成了"每级 6.2 ns"。

##### 三、深度那一半：`rs.v` 的**串行**年龄仲裁

`rs.v:112-138` 的 W 级年龄仲裁是逐级递推的**线性扫描**：

    st_prev = (ge == 0) ? 0 : ast[ge-1];
    better  = !st_prev[valid] || (age < st_prev.age) || (age == st_prev.age && ge < st_prev.idx);
    ast[ge] = (cand && better) ? {1'b1, age, ge} : st_prev;

**16 级**（`RS_SIZE=16`）串行比较-选择，每级含 RW 位年龄比较 + 相等判定 + `(1+RW+SRW)`
位 mux。**这就是 `u_rs` 71 级的来源**，也是 `sel_idx`（1152 扇出）的下游源头。

##### 四、优化方案（三条，都直接对准根因）

**手法 1 —— `array[idx]` → one-hot + AND-OR（治扇出）**
索引先译码成 N 条 one-hot，每条只驱动**一个条目**的位宽个门：
峰值扇出 `(N/2) × W → W`，即 **1200 → 150（8 倍）**。面积大致持平
（`$_MUX_` ≈ 2 门，AND2+OR2 ≈ 2 门）。
想再降，就把数据切成若干段、**每段配一份本地译码器**（译码器很便宜，16 项 ≈ 64 门），
峰值可压到 30 上下 —— 这本质上是**在 RTL 里手工补官方流程缺的那一步缓冲**。

**手法 2 —— 串行扫描 → 锦标赛树（治深度，纯赚）**
年龄仲裁是求 `(age, idx)` 的**全序最小值** ⇒ 满足结合律 ⇒ 可以做树。
**比较器个数不变（都是 n−1 个）、面积不变，深度从 O(n) 降到 O(log n)**：
`RS_SIZE=16` 时 **16 级 → 4 级**。整个方案里性价比最高的一步，且不动面积。
（`W>1` 时槽间排除仍是 W 级串行，但那是 W 不是 RS_SIZE，量级不同。）

**手法 3 —— one-hot 广播替代二进制索引（手法 1 的副产品）**
树形仲裁输出 winner 后译码成 one-hot（16 条线，每条只驱动一个条目的输出 mux），
`sel_idx` 的扇出 **1152 → ~16**。

**手法 4（保底，不治本）—— RTL 里手工复制驱动器**
若个别广播网实在无法消除，可在 RTL 里显式复制（需 `(* keep *)` 防 `opt_merge` 合回去）。
这是绕过流程缺陷的做法，只作兜底。

##### 五、现实预期（**估算，未实测**）

- 手法 1 + 3 治掉那 84% ⇒ 关键路径约 30.79 → **7–8 ns（~130–150 MHz）**；
- 叠加手法 2 再砍深度，才可能逼近 **3.33 ns**；
- **两者都做完仍是紧的，不保证到 300 MHz。** 手法 1 会让面积上升（AND-OR 阵列比 mux 树略贵），
  需在面积/IPC 三档要求下复核。

##### 六、被放弃的对照实验（记下来免得重复踩）

曾想跑一次"给 ABC 补上 `buffer/upsize/dnsize`（即 `-constr` 那条脚本）再测"的对照，
把"扇出可恢复多少"从估算变成实测。**放弃**，两个理由：
① 用户判断非官方脚本的数字参考意义有限（判分永远跑官方脚本）；
② 宿主上的快速验证卡在与本题无关的网表往返上 —— `read_verilog /tmp/pre_abc.v` 后
`abc` 报 `Don't call ABC as there is nothing to map`（`dfflibmap` 之后 abc 认为无待映射单元），
要在容器里做就得完整复刻 yosys 脚本 + STA，约 20 分钟。
**结论：不做。** 上面的根因分析比那个数字有用。

#### 15.10.10 手法落地与**实测**（2026-09-27，容器 `cpu2026:local` + 官方 `scripts/synth.py`）

##### 一、实测数据（全部为官方脚本口径，可复现）

| 版本 | commit | 最小周期 | F_max | 面积 µm² | 组合 µm² |
|---|---|---|---|---|---|
| T4 基线 | — | 30.7861 ns | 32.48 MHz | 11,475.947 | 7,505.259 |
| +手法 2（rs 锦标赛树） | `cf35970` | 20.0410 ns | 49.90 MHz | 11,533.815 | 7,563.127 |
| +手法 1 ×2（execute_slot / prf） | `49fb4bc` `31ba35f` | **13.3096 ns** | **75.13 MHz** | **11,314.969** | 7,344.281 |
| +提交级（cpu_top / LSQ 三读口） | `bdfe0bb` | 23.1621 ns | 43.17 MHz | 11,363.317 | 7,392.629 |
| +取指预取窗口（§15.10.13 之前的 HEAD） | `1158a98` | 17.8975 ns | 55.87 MHz | 11,317.229 | 7,346.541 |
| **+手法 3（D/Q 两级流水，§15.10.13）** | `9802543`+dirty | **11.7275 ns** | **85.27 MHz** | **11,354.962** | 7,329.308 |

**⚠ 本表在 2026-09-27 补了两行，结论随之改写。** 原文写的"累计周期 −56.8%、频率 2.31×"
**只对到 `31ba35f` 为止**；后续两次手法 1 各自让回去了：`bdfe0bb` +74%、`1158a98` 相对 f3 仍 +34%。
**手法 3（插流水）之后实测最好是 11.7275 ns / 85.27 MHz（§15.10.13）**，
f3 的 13.3096 ns / 75.13 MHz 退为第二，HEAD 是 17.8975 ns。
详见 §15.10.11（含四次结构改动全部变差的根因）与 §15.10.13（唯一有效的那一类手段）。

手法 1 的**面积**结论仍然成立且与 §六 的估算**相反**：AND-OR 阵列实测比 mux 树**便宜**
（mux 树的每一级都要为全部位宽付一份选择逻辑，AND-OR 只在最前面付一次译码）——
四次手法 1 全部降面积（11,475.947 → 11,317.229）。

##### 二、关键路径构成的位移（这是本轮最有价值的观测）

| | 手法 2 前（T4） | 手法 2 后 | +手法 1 ×2 |
|---|---|---|---|
| 路径 1 级数 | 122 | 95 | **95** |
| 路径 1 延时 | 30.7324 ns | 19.9763 ns | **13.2373 ns** |
| 扇出 ≥256 的级 | 13 级 | 6 级 | **1 级** |

手法 1 ×2 之后路径 1 的**扇出直方图**：

| 每级扇出 | 级数 | 总延时 | 占比 | ps/级 |
|---|---|---|---|---|
| 0–15 | 78 | 3.681 ns | 27.8% | **47** |
| 16–31 | 3 | 0.678 ns | 5.1% | 226 |
| 32–63 | 3 | 1.141 ns | 8.6% | 380 |
| 64–127 | 7 | 3.864 ns | 29.2% | 552 |
| 128–255 | 3 | 2.966 ns | 22.4% | 989 |
| ≥256 | 1 | 0.907 ns | 6.9% | 907 |

**17 级（占级数 18%）吃掉 9.556 ns（72%）。** 78 级健康逻辑跑在 47 ps/级，
本该只值 3.68 ns ⇒ **逻辑深度已不再是瓶颈，剩下的 8.8 ns 全是扇出**。
这回答了 §15.10.8 结尾留的问题：删掉扇出后不是 5.01 ns，而是**接近 4.5 ns**。

##### 三、扇出源的**解析反推**（把"哪一级对应哪句 RTL"从猜变成算）

手法 2 后路径 1 上最大的一级是 `_148978_`（AND2x2，797 扇出，907 ps）。把它的负载按
单元+管脚分类：

```
612 × AO21x1.A1    68 × AO21x1.A2    89 × AND3x1.B
```

`AO21(A1,A2,B) = A1&A2 | B`，而 `MUX2(S,D1,D0) = S&D1 | !S&D0` ⇒ **`.A1` 就是 2:1 mux 的选择端**。
即"一条控制线扇到 612 个 mux 的选择脚" —— 手法 1 的典型形状。再按 RTL 解析该信号的扇出：

`imem_addr_q[2 +: PF_IW]`（= `dem_idx`）同时喂 4 处读口，PF_DEPTH = 16：
`pf_tag_r`(8×32) + `pf_data_r`(8×32) + `pf_valid_r`/`pf_pend_r` 共 4 处(8×4) = **792**，**实测 797**。
定位闭环，不必依赖工具报的名字。

##### 四、扇出分**两类**，代价完全不同（决定了后面怎么做）

| 类 | 例子（事前网表扇出） | 能否在 RTL 里治 |
|---|---|---|
| **读索引类** `array[idx]` | `dem_idx` 797、`cmt[0].eidx` 900、`rd1_preg` 1025、`sel_idx` 1156 | **能**。手法 1：one-hot + AND-OR，扇出 (N/2)×W → W |
| **寄存器堆写使能类** | `set_addr_req` 528、`sq_push` 532、`ld_accept` 363、`lsq_push_valid` 322 | **不能**。见下 |

写使能类的扇出 = **条目数 × 位宽**，是结构性的：LSQ 写一条地址 = 16 条目 × 32 位 = 512 个
触发器的选择/D 脚，无论写成"使能进 mux 选择端"还是"使能进触发器 EN"，
**总有一个信号要驱动 512 个负载** —— 换了写法只是把扇出从使能搬到数据。
正常流程靠 ABC 插缓冲树解决（512 → 每级 ~6 个负载），**官方流程不做缓冲**：

##### 五、官方 ABC 到底跑了什么（**从容器日志逐行抄下来，不是推断**）

`scripts/synth.py:109` 是 `abc <5 个 liberty> -D 2000`，**没有 `-constr`**。
`grep` 容器 `synth.log` 得到实际执行的 ABC 脚本（`&` 系列 = ABC 的 deep/时序映射命令集）：

```
strash ; &get -n ; &fraig -x ; &put ; scorr ; dc2 ; dretime ;
retime -o -D 2000 ; strash ; &get -n ; &dch -f ; &nf -D 2000 ; &put
```

**没有 `buffer` / `upsize` / `dnsize`。** `&nf -D 2000` 只做延迟导向的映射，不做扇出修复。
另注 `retime -o -D 2000` 是**跨寄存器重定时** —— 这也解释了为什么关键路径的起点
（`_214363_/QN`、`_206376_/QN`）在 RTL 里对不上任何一条直觉上的起止寄存器对。

`scripts/synth.py` 的参数表（`--filelist/--out/--mode/--clock-period/--clock-port/--blackboxes/
--yosys/--abc/--sta/--asap7-lib`）里**没有任何 constr 旋钮** ⇒ 官方口径下无法让 ABC 插缓冲。

##### 六、现实预期（**修正 §五 的估算**）

- 手法 1 的实测收益：`rd1_preg` 1025 → 32、`eidx` 900 → 56、`dem_idx` 797 → 66（事前网表口径）；
  容器口径三轮下来周期 30.79 → 13.31 ns，**效果比估算好**。
- 但**读索引类是有限的**：扫完之后路径上仍会有写使能类的 300–580 扇出的级，
  它们每一级约 600–900 ps，且**无法用 RTL 消除**。
- ⇒ **在"ABC 不缓冲"这个前提下，300 MHz（3.33 ns）不是靠改 RTL 能达到的**；
  量级上的估计是 **100–160 MHz**。要越过这条线，必须先解决流程侧的缓冲问题
  （或改动架构让寄存器堆的"条目数 × 位宽"显著变小）。

##### 七、已落地的四次手法 1（都过了同一套门禁）

门禁：`make build` 无 UNOPTFLAT / `make -f Makefile.tb run` 15/15 /
`make test` 19/19 / `make perf` 6 个 IPC **逐位相同**（纯重构，行为不变的强证据）。

| commit | 位置 | 峰值扇出 |
|---|---|---|
| `49fb4bc` | `execute_slot.v` 13 个字段取 | 1156 → 144 |
| `31ba35f` | `prf.v` 两个读口 | 1025 → 32 |
| `bdfe0bb` | `cpu_top.v` 提交级 ROB 6 字段 + LSQ 三读口 | 900 → 56（LSQ 侧 528 → 66）|
| `1158a98` | `mem_subsystem.v` 取指预取窗口 4 字段 × 4 处读口 | 797 → 66 |

**踩到的两个坑（记下来）**：① one-hot 化一个 mux 后，它选出的值若又当下一级数组的索引，
扇出只是搬家（`eidx` → `cmt_lsq` → LSQ 读口 528），**必须连着下一级一起治**；
② `lsq_width_w[a +: 2][b]` 这种"位选套位选"不是合法 Verilog-2005，要先赋给中间 wire。

#### 15.10.11 阶段 0/1/2 的实测与**四个负结果**（2026-09-27）

本轮的目标是回答 §15.10.10 结尾留下的问题："手法 1 的收益还多吗？3.7 ns 的不变量能不能再削？"
结论是**否**：又测了四次结构改动，**四次全部让频率变差**（两次已 revert）。
下面每个数字都出自 `scripts/synth.py` `MODE=opt` 的容器产物，路径见各条。

##### 一、判据 A 成立：容器测量对同一输入是**确定的**

同一份 `f3` 快照跑两遍（`/tmp/snap_f3/build/synth_f3` 原测 vs `synth_f3ctl` 12:41–13:00 复跑）：

| | 最小周期 | F_max | 面积 µm² |
|---|---:|---:|---:|
| 原测 | 13.3096 ns | 75.13 MHz | 11,314.969 |
| 复跑 | **13.3096 ns** | **75.13 MHz** | **11,314.969** |

**逐位相同。** ⇒ 工具链对同一输入确定，`bdfe0bb`/`1158a98` 的变慢是**真实的全局重分配**，
不是测量噪声。⇒ **批次协议**：整批改完再测，不做单点 A/B。

##### 二、后续四次结构改动的完整数字（§15.10.10 §一 的表在此补全）

扇出列为 post-ABC 口径（`mapped.v`，`/tmp/census.py`；**含 `clock`/`reset`**）：

| 版本 | commit | 最小周期 | F_max | 面积 µm² | 组合 µm² | 网数 | ≥128 网 | 最大非时钟扇出 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `31ba35f`（f3，**最好**） | `31ba35f` | **13.3096 ns** | **75.13 MHz** | 11,314.969 | 7,344.281 | 107,391 | 106 | 797 `AND2x2` |
| `bdfe0bb`（f4） | `bdfe0bb` | 23.1621 ns | 43.17 MHz | 11,363.317 | 7,392.629 | — | — | — |
| HEAD（`1158a98`） | `1158a98` | 17.8975 ns | 55.87 MHz | 11,317.229 | 7,346.541 | 107,259 | 81 | 693 DFF |
| lsq merge 树化（**已 revert**） | — | 37.4258 ns | 26.72 MHz | 11,265.908 | 7,295.220 | 107,838 | 94 | **2631** DFF |
| rs 推分配器树化（**已 revert**） | — | 22.1338 ns | 45.18 MHz | 11,257.451 | 7,286.763 | 106,360 | 83 | **1027** `NOR2xp33` |

**四次后续改动全部降面积、全部降 pre-ABC 级数、全部让频率变差。**

##### 三、负结果 1：pre-ABC 的 `ltp` 级数**不是** post-ABC 频率的有效预测（可反相关）

`lsq.v` 的 merge 树化（把 `merge_byte_f` 的 16 级扫描换成 4 级优先树）：pre-ABC `ltp` 最长路径
**397 → 233 级（−41%）**，面积 −51.3 µm² —— 事前看是纯赚。实测**频率 13.3096 → 37.4258 ns，
反而慢 2.8×**。逐路径对照（`timing.rpt`，取第一条路径）：

| 版本 | 门数 | 路径延时 | 单门最大延时 |
|---|---:|---:|---:|
| f3 | 95 | 13.2373 ns | 1.4029 ns |
| HEAD | 94 | 17.8224 ns | 4.0994 ns |
| lsq1 | **79** | **37.3483 ns** | **14.2949 ns** |

**门数更少、路径更长。** ⇒ **级数不是杠杆，灾难性扇出的门才是。**

##### 四、负结果 2：lsq1 的根因是一个 **2631 扇出**的网（ABC 的因子分解选择，不是 RTL 结构）

路径上第一级是 `_004965_`，由触发器 `_203234_`（`DFFHQNx1`）的 `QN` 驱动，**扇出 2631**。负载构成：

```
NOR2xp33.A ×618   AOI21xp33.A1 ×522   NAND2xp33.A ×502
OAI21xp33.A1 ×405  A2O1A1Ixp33.A1 ×231  OAI211xp5.A1 ×156
```

次名 `_116389_`（`XOR2xp5`）扇出 740、**单门延时 14.2949 ns**（303 pF 负载）。两者合计 18.4 / 37.4 ns。
**`_203234_` 的 D 锥很小**（只有一个 `AOI21`，且读回 `_004965_` —— 普通的带使能寄存器），
⇒ **2631 扇出纯粹是 ABC 选了这个触发器输出当全局共享文字**，RTL 侧无对应结构。
设计规模没变（107,838 vs 107,259 网）。

##### 五、负结果 3：rs 推分配器树化 = **+23.7%**（已 revert）

把 `rs.v` 的 `prec`/`ecst`/`pvc`/`fcnt` 四条 16 级串行链换成 Hillis-Steele 前缀和 + 槽候选 one-hot
编码（写法见 `/tmp/rs_prefix_alloc_backup.v`）。门禁全过：`make build` 干净、
`make -f Makefile.tb run` **ALL TESTS PASSED**、`make test` **19 passed / 0 failed**。

| | HEAD | +rs 改造 |
|---|---:|---:|
| 最小周期 | 17.8975 ns | **22.1338 ns**（+23.7%）|
| 面积 | 11,317.229 µm² | 11,257.451 µm²（**−59.8**）|
| ≥128 扇出网 | 81 | **83**（反而多了 2 条）|

根因同类：新造出一条 HEAD 上不存在的 **1027 扇出** `NOR2xp33`（`_081137_`），
HEAD 的最大非时钟扇出只有 693。**这是"改了 A、关键路径跳去 B"的第三次实例。**

##### 六、负结果 4：高扇出网的**数量**也不是判据

把上表按"最快"排序看扇出基数：**f3 最快（13.3096 ns），它的 ≥128 网最多（106）；
HEAD 慢 34%，≥128 网只有 81。** ⇒ 判据不是"有多少条高扇出网"，而是
**"关键路径上有没有那一条"** —— 而它由 ABC 的全局因子分解决定，RTL 侧不可控。
这三条（级数、扇出基数、面积）合起来否定了"按统计量做局部优化"的整条路线。

##### 七、新方法：用 `alumacc` 的日志把 `$alu` 映射回 **RTL file:line**

yosys `alumacc` 会打印 `creating $alu cell for <ops>: <cellname>`，把每个 `$alu` 映射回 RTL 出处。
这是**唯一**能在 pre-ABC 阶段做算术归因的手段（`mapped.v` 里没有 RTL 名，见 §八）。
对 HEAD 的 197 级路径拆出 **74 级（38%）来自 `$alu`**，逐项如下：

| `$alu` 单元 | 级数 | RTL 出处 | 结构 |
|---|---:|---|---|
| `94740/94720/94710/94705` | **36** | `core/rs.v:149` | 年龄仲裁 4 级锦标赛，每级一个 **5 位** `<` |
| `94944` | 18 | `exec/adder32.v`（`branch.v` 的 `ucmp`）| 32 位 lcu 进位链 |
| `95377` | 5 | `top/cpu_top.v:357` | 5 位 `$sub` |
| `94018` | 5 | `top/cpu_top.v:412` | 5 位 `$ge`（`ISSUE_WIDTH == 1` ⇒ **本质是 `\|rs_free_w`**）|
| `93974` / `93633` | 5 / 3 | `top/cpu_top.v:579` / `:583` | 5 位 `$gt` |
| `94868` / `94856` | 1 / 1 | `core/rob.v:75` / `:84` | 5 位 `$sub` |

**两条结论**：① **`adder32` 只占 18 级，5 位比较器占 36 级** —— 一个 5 位比较被 `alumacc`+`lcu`
展成 **9 级**进位链（5 位本该 3–4 级），4 级树串起来就是 36 级；
② `alu.v`(×2) 与 `mul.v`(64 位) 的 `adder32` **根本不在这条路径上**（表里没有它们）。
⇒ 若要继续削，靶子是**窄比较器**而不是加法器。

##### 八、post-ABC 的归因路径：`mapped.v` 里 **0 个 RTL 名**

ABC 之后全部单元名都是 `_NNNNN_`，与 RTL 无任何字符串关联。post-ABC 归因只能走：
**扇出普查**（`/tmp/census.py`，按驱动器类型 + 负载管脚分类）+ **反向锥走查**
（`/tmp/cellwalk.py`，按实例名展开）。§四 的 2631 就是这么定位的。

##### 九、Debug 记录：`~` 一个**非打包数组**会触发 Verilator 内部错误

```
%Error: Internal Error: verilog/core/rs.v:66:22: ../V3Dfg.h:195: Non packed vertex has no 'width'
```

最小复现：`reg valid_r [0:15]; wire [15:0] emp = ~valid_r;` —— **对 unpacked array 做按位取反**。
与负 genvar 索引无关（这条已排除）。**解法**：先声明 `wire [RS_SIZE-1:0] emp;`，
再用 `generate for (...) assign emp[i] = !valid_r[i];` 逐位赋值。

##### 十、已证伪的旧估计：`cdb.v` 换成 `1 << prd` **不能**降扇出

§15.10.9 §三 里估的"把 `load_prd == gr`（64 个 6 位比较器）换成 `1 << prd` 移位器，
可砍掉约 90% 比较器"**不成立**：一个 6→64 译码器的**每比特扇出与 64 个比较器阵列完全一样**，
都是"一位索引驱动 64 个负载"。**该条不再作为目标。**

##### 十一、选型结论：`adder32` 用 CLA，**不用** Kogge-Stone

`~/program/PPCA/homework/adder32/answer.v` 是**两级超前进位（CLA）**，不是前缀树：
位级 8 × `cla4`（块内平铺二级 AND-OR 出进位 + 组 `pg`/`gg`），组间 `carry[1..8]` 写成
只含 `pg`/`gg`/`cin` 的平铺积之和。**已过该作业下发的 8 个测试点**。

| | 进位深度（32 位） | 单元数 | 已验证 |
|---|---|---|---|
| 现状 `a + b + cin`（lcu 链） | 18 级（实测，见 §七） | O(N)，最小 | 在用 |
| `homework` CLA | ~8 级 | **O(N)** | **是** |
| Kogge-Stone（本轮写过，**已 revert**，备份 `/tmp/adder32_kogge_stone_backup.v`） | ~7 级 | O(N log N)，约 2–3× | 否 |

两者深度基本持平，**CLA 面积减半且已验证** ⇒ 用 CLA。落地时组间网络要改：`answer.v` 的平铺 SOP
在 `WIDTH=64` 下会变成 17 项积之和、且给 ABC 送共享积项（正是 §四 那类灾难的成因），
改用 generate 展开的前缀扫描（8 组 3 级 / 16 组 4 级，每节点扇出 ≤2），以便参数化到 `mul.v` 的
`WIDTH=64`。端口 `(a, b, cin, sum, cout)` 不变 ⇒ `branch.v:25-27` 三个**故意省略 `.cout`** 的实例
照旧（写成 `.cout()` 会崩 `opt_hier`，见 `branch.v:21-24`）。

##### 十二、下一步（**未执行**，本次到此收尾）

阶段 2b「去 `$alu` 化」：按 §七 的表排序 —— `rs.v:149` 的 5 位 `<` 换成显式幅度比较器
（算子与加法器相同 `(g,p)◦(g',p') = (g | p & g', p & p')`，方向改 MSB-first；36 级 → ~16 级）、
`adder32.v` 换 CLA（18 → ~9 级）、`cpu_top.v`/`rob.v` 的窄比较。

**风险边界（必须遵守）**：§三/§五/§六 已证明 **pre-ABC 级数、扇出基数、面积三项都不能预测
post-ABC 频率** ⇒ **不得**用 `ltp` 级数当完成判据，收益只能由容器实测判定；
且按 §一 的判据 A，采用**整批改完再测**的批次协议。

#### 15.10.12 第五个负结果：`lsq.v` merge 树化（**行为保持**，−22% 频率）—— 同型第 3 次（2026-09-27）

本轮执行 §十二 之外的另一条线（本轮计划 §5a）：把 `lsq.v:234-302` 的 `merge_byte_f` 从
**4 份复制的 16 次串行扫描**改成 **1 份条目级宽比较 + 每字节道一棵 4 级锦标赛树**。

##### 一、改法与动机

原结构被 ABC 抽成 **扇出 637** 的共享节点（`AOI21xp33`，单级 4.07 ns），是 HEAD 关键路径上
两级吃掉 46% 的其中一级。改写四条（完整 patch 见 `docs/timing/lsq-tree2/lsq_tree.patch`）：

1. **4 份复制 → 1 份**：状态数组只读一遍，完成 load 的地址也只选一次；
2. **宽比较提到条目级**（16 份），不许落进 (字节道 × 条目) 的叶子里（64 份）—— §四 的教训；
3. **串行优先链 → 锦标赛树**（堆式布局，照 `rs.v:117-155`）：深度 16 级 → 4 级；
4. 树的载荷直接带**字节**而非条目号，省掉原实现那个 512 位、偏移可变的字节选择器。

##### 二、门禁全过 —— 这是**行为保持**的改写（走了强判据）

| 门 | 结果 |
|---|---|
| `make build` | 干净，无 UNOPTFLAT |
| `make -f Makefile.tb run` | **ALL TESTS PASSED**（15/15）|
| `make test MAX_CYCLES=100000000` | **19 passed / 0 failed** |
| `make perf` 6 条 IPC | **`0.2474, 0.5719, 0.2537, 0.2985, 0.2810, 0.5940` —— 与 HEAD 逐位相同** |

逐位相同意味着这次连"改了行为"的借口都没有：**是纯结构改写，且正确**。

##### 三、实测：频率反而慢 22%

| | HEAD | lsq-tree2 | 变化 |
|---|---:|---:|---|
| 最小周期 | 17.8975 ns | **21.8428 ns** | **+22.0%** |
| F_max | 55.87 MHz | 45.78 MHz | −18% |
| 面积 | 11,317.229 µm² | 10,726.535 µm² | **−590.7（好）** |
| 关键路径**级数** | 94 | **58** | **−36 级（好）** |
| 健康级 | 79 @ 47.7 ps = 3.7706 ns | 49 @ 52.2 ps = 2.5591 ns | **上限A 265 → 391 MHz（好）** |
| 高扇出税 | 14.0518 ns（79%）| **19.2085 ns（88%）** | **+5.16 ns（坏）** |

**深度削减按设计生效了（94 → 58 级），面积也降了，上限 A 从 265 抬到 391 MHz —— 四项
"事前指标"全部变好，实测频率却慢了 22%。**

##### 四、根因：ABC 把新结构抽成扇出 **1129** 的节点

| 级 | 驱动单元 | 扇出 | 电容 fF | 摆率 ns | 增量延时 |
|---:|---|---:|---:|---:|---:|
| 55 | `AOI21xp33` `_142111_/Y` | **1129** | 622,850.5 | 15.5711 | **7.2209 ns** |
| 56 | `NAND2xp33` `_144948_/Y` | 150 | 57,855.2 | 0.9674 | 6.9317 ns（被上级摆率主导）|
| 0 | `DFFASRHQNx1` `_193436_/QN` | 702 | 287,705.4 | 2.5025 | 1.2083 ns |
| 6 | `NOR2xp33` `_116681_/Y` | 289 | 111,227.5 | 2.7832 | 1.3147 ns |

两级（55+56）合计 **14.15 ns = 21.84 ns 的 65%**。

##### 五、规律：串行链**扇出友好**，树/并行结构**扇出敌对**

三个负结果的形状完全一致（`lsq1` / `rs-prefix` / 本次）：

| 版本 | 改动方向 | post-ABC 新造的灾难节点 | 最小周期 |
|---|---|---|---:|
| `lsq1` | 16 级串行扫描 → 4 级树 | **2631** 扇出 `DFFHQNx1` | 37.4258 ns（+181%）|
| `rs-prefix` | 串行分配器 → 前缀和 | **1027** 扇出 `NOR2xp33` | 22.1338 ns（+23.7%）|
| `lsq-tree2` | 16 级串行扫描 → 4 级树 | **1129** 扇出 `AOI21xp33` | 21.8428 ns（+22.0%）|

机制：串行链的中间值**每个只用一次**；树/前缀结构的中间值是**结构同构**的（每个节点都是
同一个几比特比较/加法），ABC 的 `strash`/`fraig`/`dch` 会把这些同构子表达式**合并成一个共享
文字**，扇出 = 节点数 × 位宽。**RTL 层越是"消除串行、换成平衡并行"，越是在给 ABC 递共享节点。**

⇒ **在本流程（官方 `abc` 不带 `-constr`，不插缓冲、不做 upsizing）下，"降深度"这条路线是
负期望的**：5 次结构改写，5 次变差，且每一次的级数/面积/上限A 都指向"变好"。§十二 那份
"去 `$alu` 化"清单（`rs.v:149` 的 5 位 `<`、`adder32` 换 CLA）**同属这一类，不应再按原样执行**。

##### 六、min-all 参数点的热点性质与 HEAD **不是同一种病**

对 `runs/min-all` 做 RTL 级扇出普查（`tools/preabc.py --stage rtl` + `tools/census.py`），
top 扇出**全部是 one-hot 选择位**：

| 信号 | 字级引用数 | 折算每比特 |
|---|---:|---:|
| `prf \rd[0].oh1` / `oh2` | 1280 | **32**（= 40 条目 × 32 位）|
| `mem_subsystem \idat[0].oh_g` | 520 | 65 |
| `cpu_top \cmt[0].cmt_oh` | 432 | 54 |
| `execute_slot sel_oh[0..3]` | 139 | 139 |

`prf.v:36` 的注释写着这个 one-hot 是**已经**从峰值扇出 1024 压到 32 的结果
（`oh1[p]` 只驱动寄存器 p 的那 32 位）⇒ **32/比特 是 one-hot + AND-OR 的结构性地板**：
再往下压只能靠复制 one-hot 生成器，而那正是被 ABC 的 CSE 合并回去的路线（本节 §五）。
min-all 的 top 网 `_00107_` 是**反向锥只有 1 个单元、逻辑深度 0 的裸状态位**，广播给 99 个负载
—— 与 HEAD 的"ABC-CSE 深锥共享节点"是**两种不同的病**。

##### 七、比扇出更根本的一层：**摆率退化**，且它由流程决定，RTL 无从下手

§三/§五 只解释了"为什么改写会变差"，没解释"为什么最优版也只有 75 MHz"。把 f3 关键路径上
**健康级（扇出 ≤15）**的逐级数据摊开看（`tools/path.py docs/timing/f3 --top 95`）：

| 级 | 扇出 | 电容 fF | 输入摆率 ns | 增量延时 ns | 驱动 |
|---:|---:|---:|---:|---:|---|
| 94 | **1** | 561.7 | 0.1174 | **0.0886** | `OAI21xp33` |
| 48 | **1** | 418.4 | 0.0140 | 0.0501 | `OA211x2` |
| 70 | **1** | 401.1 | 0.0970 | 0.0803 | `NOR2xp33` |
| 5 | **1** | 446.5 | 0.1748 | 0.1577 | `OAI221xp5` |

**扇出 1、负载只有 400~600 fF 的单元也要 50~160 ps**（ASAP7 7.5T RVT TT 下一级本征延时
应在 20 ps 量级），且**延时 ≈ 0.7 × 输入摆率** —— 即延时被**输入摆率**主导，而摆率沿路径
**单调恶化**：没有任何一级把信号重新驱动成陡沿。

根因在官方流程脚本本身（已核实，`build/synth_*/opt/synth.ys` 第 13 行）：

```
abc -liberty <AO> -liberty <INVBUF> -liberty <OA> -liberty <SEQ> -liberty <SIMPLE> -D 2000
```

**没有 `-constr`**（不给约束文件，就不执行 `buffer` / `upsize` / `dft` 等脚本命令），
⇒ 全部单元停在**最小尺寸**（后缀 `xp33`），**网表里 BUF 单元数为 0**
（`grep -c BUFx mapped.v` = 0；`INVBUF` 库虽然被 `read_liberty` 读进来了，ABC 从不调用）。
一个不插缓冲、不做 upsizing 的映射流程，其**每一级延时都被上一级的摆率污染**，
于是 95 级要 13.2 ns（139 ps/级），而不是 95 × 20 ps ≈ 1.9 ns。

**这解释了前五节的全部现象**：既然单元尺寸恒定在最小档、摆率只增不减，那么
"哪个逻辑被映射成几级、每级扇出多少" 就完全由 ABC 的全局因子分解决定，而它
**对 RTL 结构是混沌的**（§五 的 3 次同型实例）。RTL 侧能改的只剩"少造扇出"，
而扇出的下限由功能决定（§六：one-hot 的 32/比特、状态位的广播）。

##### 八、本题的可达上限（算术，不是估计）

| 版本 | 级数 | 健康级地板 | **上限A**（热点全免费）| **上限B**（只修扇出，级数不变）| 实测 |
|---|---:|---:|---:|---:|---:|
| f3（本节时点的最优） | 95 | 78 @ 47.2 ps = 3.6808 ns | **272 MHz** | **223 MHz** | 75.13 MHz |
| HEAD | 94 | 79 @ 47.7 ps = 3.7706 ns | 265 MHz | — | 55.87 MHz |
| min-all（参数全最小）| 74 | 63 @ 47.5 ps = 2.9921 ns | **334 MHz** | **285 MHz** | 151.23 MHz（综合记录，`make perf` 挂死见 §15.10.13 §九）|
| **pipe1（§15.10.13，插流水）** | 99 | 82 @ 49.0 ps = **4.0173 ns** | 249 MHz | 206 MHz | **85.27 MHz** |

> 最后一行是本节结论的**反例**：它的级数与健康级地板**都变差**（94→99、3.7706→4.0173），
> 按本表的两个上限**应该更慢**，实测却最快。原因见 §15.10.13 §七 —— **上限A/B 都建立在
> "寄存器边界不动"的隐含前提上**，而插流水正是动了这个前提。本表此后只用于**同边界内**比较。

⇒ **在已测出的全部参数点上，"把扇出税全部消掉"的最好结果是 285 MHz（min-all）**，
而 §五 已证明扇出税**无法**由 RTL 改写消掉。300 MHz 需要 **级数 ≤70 且每级扇出 ≤15
同时成立**（3.333 ns / 47.5 ps = 70 级），min-all 是 74 级 —— 差 4 级，而砍级数的手段
（树化/前缀化）正是 §五 证伪的那一类。

**结论：在本流程 + "只从 RTL 降扇出、不手插缓冲、不插流水" 的约束下，300 MHz 不可达。**
可达区间是 **75~150 MHz**（参数全最小 + 扇出状况不变时约 151 MHz）。要再往上，
必须松掉三者之一：① 允许 RTL 手插缓冲/`keep_hierarchy`；② 允许插流水级；
③ 换流程（判分永远跑官方脚本 ⇒ 此路不通）。

> **后续（§15.10.13）**：用户裁定选 **②**。`execute_slot` 内部分 D/Q 两级流水后实测
> **11.7275 ns / 85.27 MHz**（HEAD 17.8975 ns 的 −34.5%，f3 的 −11.9%），
> 面积 +0.33%，IPC 几何平均 −4.36%，**净吞吐 +45.95%**。本节 §八 那张"上限表"的两个
> 事前指标（级数、健康级地板）在这一版上**同时变差**（94→99 级、3.7706→4.0173 ns）
> 而实测反而最快 —— 见 §15.10.13 §六/§七。

#### 15.10.13 手法 3：`execute_slot` 内部分 D/Q 两级流水 —— **新最优 11.7275 ns / 85.27 MHz**（2026-09-27）

§15.10.12 §八 的结论是：在本流程下 300 MHz 不可达，除非松掉三条约束之一。用户裁定选
**② 允许插流水级**。这是本项目第一次动流水结构（此前 5 次结构改写全部是"行为保持"类的
扇出/深度重构，5 次变差）。

##### 一、为什么流水级是**另一类**手段，而不是"第 6 次结构改写"

§15.10.12 §七 已经证明：官方 `abc` 不带 `-constr` ⇒ 不插缓冲、不做 upsizing ⇒ 每级延时被
**上一级的输出摆率**污染（`delay ≈ 0.7 × input_slew`），而摆率沿组合路径**单调恶化**，
RTL 侧无从下手。**寄存器是这个流程里唯一能把摆率归零的东西。** 所以本手法的收益模型不是
"级数减半"，而是"在路径中间强行插一个陡沿"——这正好绕开了"ABC 把 RTL 结构重新因子分解"
那条混沌路径（§五 的 3 次同型实例）。

##### 二、改法：切在 `sel_all_w` 之后

| | D 级（原有） | Q 级（新增，晚一拍） |
|---|---|---|
| B3 字段取 | `sel_idx` → one-hot → 144 位 AND-OR | — |
| B1 操作数获取 | — | PRF 读口索引 → CDB 旁路 → `op` |
| B3 执行 | — | 槽内 alu / branch |
| B4 误预测检测 | — | `misp_det` + 级 payload |

切点寄存器 **144+1 位**（144 位打包条目 + 1 位 valid）。`rs` 仲裁仍在 D 级当拍出 `sel_idx`，
只是它下游的字段取与执行晚一拍。

端口变化（`execute_slot` 新增 5 个）：`flush_win`（= `flushing_r`）、`flush_hit`（= `misp_valid`）、
`div_accept`（= `div_go_w`）、`sel_valid_q`（= cpu_top 的 `ret_sample` 读口判据）、
`pipe_stall`（Q 级冻结 ⇒ cpu_top 必须同时放过 `rs_clear`）。`cpu_top` 侧三处：
`rs_clear_valid = sel_valid & ~pipe_stall_w`、`rd1_preg` 的 ret_sample mux 判据改 `sel_valid_q[0]`、
**`div_hold_w` 机制退役**（它的"扣住"职责被 `pipe_stall` 统一吸收，见 §15.10.2 表的更新）。

##### 三、四条不变量（写在 `execute_slot.v` 文件头，因为每条都能静默丢指令）

1. **RS 条目在入选那拍就被清**（`cpu_top` 的 `rs_clear_valid`）⇒ D→Q 必须同拍完成移交；
   凡是要"扣住"的情形都只能扣**流水寄存器**，扣 RS 条目已经晚了。
2. 因此"扣寄存器"（`q_freeze`）与"放过条目"（`pipe_stall` 门控 `rs_clear`）**必须同条件**，
   否则"条目被清但没进寄存器"（丢指令）或"没清却进了寄存器"（重复执行）二者必居其一。
3. `flush_hit` 当拍 **清空**寄存器而不是冻结（唯一的例外，见下节）。
4. 冲刷窗口（`flush_win`）内冻结 D→Q 移交：若让 D 级继续移交，进来的 div 会因条目已被清
   而逃过 rs 失效掩码，等冲刷结束再启动 ⇒ 错路 div 完成时按 `rob_tag` 置 ready，
   而那个 tag 早已被新指令复用 ⇒ **真错**。

##### 四、实测踩到的活锁：不变量 3 是"踩出来的"，不是推出来的

初版把 `flush_hit` 也实现成"冻结"。`make -f Makefile.tb run` **3/15 失败**，现象是
`flushing=1 misp=1` 活锁。根因：`misp_det` 是本模块**寄存器里那条指令**的组合函数 ⇒
冻住寄存器 = 冻住误预测源 ⇒ `misp_det` 常 1 ⇒ `misp_valid` 常 1 ⇒ `flushing_r` 反复置位。
改法：`flush_hit` 当拍**清空**（寄存器里那条正是检出误预测的分支本人，它本拍已执行完，
正对应原设计里"它的 rs 条目当拍被清"），并把 `flush_hit` 并进 `pipe_stall` 以保证"清空"
与"不放它条目"成对。改后 15/15。

##### 五、门禁全过

| 门 | 结果 |
|---|---|
| `make build` | 干净，无 UNOPTFLAT |
| `make -f Makefile.tb run` | **ALL TESTS PASSED**（15/15）|
| `make test MAX_CYCLES=100000000` | **19 passed / 0 failed** |
| `make perf` 6 条 IPC | 见下表（**IPC 变了**，流水改了时序语义，§15.10.12 的"逐位相同"强判据**不适用**）|

##### 六、实测：周期 −34.5%，**新最优**

| | T4 基线 | f3（前最优） | HEAD | **pipe1** | pipe1 vs HEAD |
|---|---:|---:|---:|---:|---:|
| 最小周期 | 30.7861 ns | 13.3096 ns | 17.8975 ns | **11.7275 ns** | **−34.47%** |
| F_max | 32.48 MHz | 75.13 MHz | 55.87 MHz | **85.27 MHz** | **+52.61%** |
| 面积 µm² | 11475.947 | 11314.969 | 11317.229 | **11354.962** | +37.733（**+0.33%**）|
| 关键路径级数 | 122 | 95 | 94 | **99** | **+5（反而变多）** |
| 健康级 | 106 @47.3 = 5.0106 | 78 @47.2 = 3.6808 | 79 @47.7 = 3.7706 | 82 @49.0 = **4.0173** | +6.5% |
| 高扇出税 | 25.7218（84%）| 9.5565（72%）| 14.0518（79%）| **7.6533（66%）** | **−45.54%** |
| 上限A（热点免费）| 200 MHz | 272 MHz | 265 MHz | **249 MHz** | — |
| 上限B（只修扇出）| — | 223 MHz | — | 206 MHz | — |
| IPC 几何平均 | — | 0.3484 | 0.3484 | **0.3332** | **−4.36%** |
| **净吞吐**（IPC/周期）| — | 0.02618 | 0.01947 | **0.02841** | **+45.95%** |

口径：容器 `cpu2026:local` + 官方 `scripts/synth.py`，`CLOCK_PERIOD_NS=2.0`，
`FILELIST=verilog/filelist_t4tmp.f`（与 f3/head 同输入集，可比）；证据归档 `docs/timing/pipe1/`。

**注意倒数第二行与第三行**：级数**变多了 5 级**、健康级那部分**变差了 6.5%**，
按 §15.10.12 §八 那张表的两个"事前指标"看，这一版**应该更慢**。实测快了 34.5%。
这是本项目第 4 次出现"事前指标与实际相反"，也是第 1 次出现**反方向**的相反。

##### 七、归因：关键路径**换了身份**（可证，不是推测）

`timing.rpt` 每次报**最差 5 条**路径。把两个版本的最差 5 条摆在一起：

| | 起点 → 终点（触发器类型）| 级数 | arrival |
|---|---|---|---|
| HEAD | `DFFASRHQNx1` → `DFFASRHQNx1` ×5 | 94 | 17.8200 ns（5 条完全相同）|
| pipe1 | `DFFASRHQNx1` → **`DFFHQNx1`** ×5 | 98~99 | 11.65 ~ 11.67 ns（5 条互不相同）|

⇒ **HEAD 那条 17.82 ns 的路径在 pipe1 的最差 5 条里彻底消失了。** 既然报的是全局最差 5 条，
它就只能**已经快于 11.65 ns** —— 所以"切分确实生效了"，而不是"ABC 恰好重新分解、这条路径
原样还在"。终点触发器类型从 `DFFASRHQNx1` 换成 `DFFHQNx1`（前者是 rob/rs/rat/ready_table
的异步复位型，后者是 prf/lsq/free_list/ras/bht 的同步复位型）也印证了这是**另一条**路径。

**寄存器确实在网表里（145 位，一位不差）**，两条独立自校验：

- `sequential_area_um2` 增量 = 4025.65464 − 3970.688 = **54.96664 = 145 × 0.37908**（DFF 单价）；
- `stat.json` 单元直方图增量：`DFFASRHQNx1` **+145**、`TIEHIx1` **+145**（异步置位端拉高），
  其余 60 余种单元没有任何一种同型 ±145。

##### 八、净收益与结论

- **净吞吐 +45.95%**（HEAD → pipe1），相对 f3 **+8.54%**。这是本项目目前最快的一版。
- 面积只涨 0.33%，**远低于 2% 的不劣化预算**。
- **插流水是本项目验证过的唯一有效的频率手段** —— 与 §15.10.11/§15.10.12 的 5 个负结果
  形成对照：那 5 次是"在组合逻辑内部重排"，ABC 会把它重新因子分解回同构共享节点；
  这次是**在组合逻辑中间放一个寄存器**，ABC 无法跨寄存器做 CSE。
- **但仍差 300 MHz 三倍**（11.7275 vs 3.333 ns），且**卡点已经换了位置**：
  现在健康级 82 级 × 49.0 ps = **4.0173 ns 本身就是地板**（上限A = 249 MHz）。
  ⇒ 下一步不是再降扇出（上限B 只有 206 MHz，比现状还低），而是**继续插流水**
  （把 Q 级再劈开：操作数获取/执行 | CDB 写回），把 82 级健康级也切短。
  §15.10.12 §八 的"级数 ≤70 且每级扇出 ≤15"仍是判据，但**级数由流水边界决定**，
  不再是 ABC 的脸色。

##### 九、副产物：参数二分发现两个**功能挂死点**（与本轮频率工作无关，但是真 bug）

`min-all`（全部参数最小）在 `make perf` 上挂死，二分（`tools/sweep.sh`，11 个点）：

| 变体 | 结果 | perf_median IPC |
|---|---|---|
| 基线（默认参数）| PASS | 0.2474 |
| **全部最小（= min-all）** | **FAIL**（timeout）| — |
| 只 RS_SIZE=4 | PASS | 0.2352 |
| 只 LSQ_SIZE=4 | PASS | 0.2141 |
| **只 ROB_SIZE=8,PRF_SIZE=40** | **FAIL**（timeout）| — |
| 只 BHT_SIZE=8 | PASS | 0.2486 |
| 只 RAS_SIZE=4 | PASS | 0.2474 |
| 只 PF_DEPTH=8,PF_WIN=4 | PASS | 0.1565 |
| **只 LD_INFLIGHT=2** | **FAIL**（timeout）| — |
| 只 SQ_DEPTH=4 | PASS | 0.2474 |
| 只 RD_DEPTH=4 | PASS | 0.2386 |
| 只 WR_DEPTH=4 | PASS | 0.2474 |

⇒ `min-all` 有**两个互相独立**的挂死触发条件（`ROB_SIZE=8 & PRF_SIZE=40` 与 `LD_INFLIGHT=2`），
其余单轴缩减全部 PASS。这是**先于本轮频率工作就存在**的功能缺陷（min-all 的 6.61 ns
那条综合记录因此不可用），**待单独定位**，不计入频率结论。

> **2026-09-27 补**：两条都已定位。`LD_INFLIGHT=2` 是**真 bug**（指针差值按 mod LD_INFLIGHT
> 编码 ⇒ 满判据永不成立 ⇒ 在飞槽位被覆盖），已修，见 §15.10.15 §二/§六。
> 而 `ROB_SIZE=8 & PRF_SIZE=40` 这一条**不是缺陷**：ROB_SIZE=8 完全无辜，全部责任在
> `PRF_SIZE=40` —— 它是**结构性不可行点**，见 §15.10.15 §六。本表该行的"只 ROB_SIZE=8"
> 应读作"只 PRF_SIZE=40"。

#### 15.10.14 手法 4：`execute_slot` 加 W 级写回寄存器 —— **一半成功**，以及热点的完整归因（2026-09-27）

**是什么**：在 Q 级之后再插一级写回寄存器 W（114 位 = valid/addr_req/data_req 三个 strobe +
prd 6 + rob_tag 5 + lsq_tag 4 + result 32 + addr 32 + data 32），只登记**消费者侧产物**（推 CDB、
推 LSQ 的地址/数据），不动 `q_freeze` / `rs_clear` 的握手。三个 strobe 位是 `q_freeze ? 0 : in`
的普通 mux，其余 111 位的使能恰好是 `!q_freeze`。

**实测**（`docs/timing/wb1/`，容器 `cpu2026:local` + 官方 `scripts/synth.py`）：

| 版本 | min_period ns | Fmax MHz | 面积 µm² | 级数 | healthy_ns | hot_ns | 上限 A | IPC geomean |
|---|---|---|---|---|---|---|---|---|
| pipe1（手法 3）| 11.7275 | 85.27 | 11354.962 | 99 | 4.0173 (82 级) | 7.6533 | 249 | 0.3332 |
| **wb1（手法 4）** | **25.0176** | **39.97** | 11385.595 | **76** | **3.2339 (63 级)** | **21.7048** | **309** | 0.2287…0.5492 |

**成功的那一半正是目标**：级数 99→76，**healthy_ns 4.0173 → 3.2339 ns < 3.333 ns**
（300 MHz 的周期预算）——健康逻辑**第一次进预算**，上限 A = 309 MHz。
**失败的那一半**：hot_ns 7.6533 → **21.7048 ns**（占比 66% → 87%），总长翻倍，净吞吐 −57%。

**两条必须先说清的更正**（先前口头给过错误结论，此处为准）：

1. **不是**"某个网 `_077026_` 单独吃掉了全部超支"。`timing.rpt` 的最坏路径是一条**级联**：
   `_205605_/QN`(fo 165) → … → `_144092_/Y`（**fo 1022**，cap 556.30，slew 10.87，**+5.4020**）→
   `_155748_/Y`（**NAND3**，fo 201，cap 82.35，**+8.5571**）→ … → `_202691_/D`，累计 24.94 ns；
   后两级 13.96 ns = **56%**。
2. wb1 的热网**不是** pipe1 那个 510 扇出网的"同病放大"。pipe1 的热网是 **XNOR 驱动、`AO21` 负载 0 个**，
   wb1 是 884 个 —— 两者是**不同的网**。884 个目的触发器 ID 在 pipe1 里**全部已存在**（884/884 匹配）
   ⇒ **寄存器阵列没变，是 ABC 把它们的写使能重新因子分解成了一个共享节点**。

**完整归因：那 884（实为 1088）个触发器 = `rs.v` 的 RS 条目负载**

只读解析 `runs/wb1/build/synth_wb1/opt/mapped.v` + `docs/timing/wb1/timing.rpt` + RTL，证据链：

1. `_077026_` = `NOR2 _144092_ = ~( NAND4 _076132_ | NOR4 _077025_ )`，扇出 **1023**。
   负载直方图：**884 × `AO21x1.A1`** + 68 × `AO21x1.A2` + 34 × `AND3x1.B` + 15 × `NAND2xp33.A` + …
2. 884 = **13 组 × 68**；每组的 ID 形状都是 `[32, 1, 32, 3]`，起点按 **32 位槽距**排列
   （槽号 k = 0,2,3,4,6,7,8,9,10,11,12,14,15）。
3. 窗口 203669–205348 共 1680 = **16 × 105**，而
   **105 = pc_r 32 + imm_r 32 + rob_r 5 + ptaken_r 1 + ptarget_r 32 + ras_r 3**；
   窗口内非本组的 592 位 = **imm_r(512) + rob_r(80)** —— 逐位吻合。
4. 剩余字段 opcode 7 + func3 3 + func7 7 + prs1 6 + prs2 6 + prd 6 + lsq 4 = **39**
   ⇒ 105 + 39 = **144 = TOTW** ✓（另加 `valid_r` 1 位）。
5. 选择网的锥**恰好 16 个异步根触发器**，且末级直接暴露索引位：
   `_088591_ = AND4(pidx[0..3])`、`_088508_ = !pidx[0]` —— 正是 `rs.v:164-197` 的**首个空槽指针**
   （`prec` 前缀和 + 编码器链）。
6. `rs.v:237` 把 14 个字段 + `valid_r` **写在同一个条件** `push_valid[k2] && pvalid_w[k2]` 下
   ⇒ CSE 抽成单个共享字面量。
7. 看似"缺"的 3 个槽**并没缺**：`_203701_`(k=1) 的 D 是 `OAI21(.A1=_007408_, .A2=sel)` ——
   同一个使能的另一种门极性 ⇒ 真实规模是 **16 × 68 = 1088 位**。

**结论**：W 级本身没做错（healthy 已达标），错的是**顺序** —— 它改变了 D 侧锥形，使 ABC 把 RS 的
写使能 CSE 成一个扇出 1088 的**深锥节点**（该节点自身到达时刻已累计 16.22 ns，再叠加 5.4 ns
的负载延时）。**在上游拆掉这个共享使能之前，继续插流水是净负的。**

**下一步**：`pvalid_w` 是**冗余保护** —— `cpu_top.v:418` 的 `resources_ok` 已含
`rs_free_w >= ISSUE_WIDTH`，而 `rs_free_w` 是按 `!valid_r` 数的**真空闲槽数**
（`rs.v:201-212`；`cpu_top.v:414-417` 的注释明确记录了这条设计意图），rs 的 `push_valid` = `issue_en`
⇒ `push_valid ⇒ pvalid_w`。故删掉 `rs.v:237` 的 `&& pvalid_w[k2]` 可**证行为保持**，
并把共享字面量从深锥输出换成早到达的端口网。
判据：容器综合后 **`hot_ns` 显著下降且 `healthy_ns` 不退化**（总长 < 25.0176 ns）；
**不得**用"某个网扇出下降"当成功判据 —— 该代理量已在 `tools/README.md` §0 被证伪。

#### 15.10.15 修 W≥2 的四条正确性缺陷（报告 W{1,2,4} 消融矩阵的前置条件）（2026-09-27）

**为什么必须先修**：报告要求 W{1,2,4} 消融矩阵，而 W≥2 全线挂死。**W=1 全部 20 个程序一直是过的**
—— 下面四条**全部只在 W≥2 可见**，因为 W=1 时"批"只有 1 槽：没有批内下标、没有批内多写、
`f2i_valid` 只有 1 位。四条都已修，且**互为独立**（修完前两条 naive 才过，修完第四条 gcd 才过）。

##### 一、`core/memory.v`（仅 TB 用存储）复位时多槽地址全 0

`imem_addr_r` 复位成全 0 ⇒ W≥2 的**所有槽**初始都请求 word(0)，第一批的解码内容与 pc 不符。
改为 `32'd4 * bb`（每槽复位到自己那一拍）。**只影响 TB**（`student_top` 已不例化 `memory.v`）。

##### 二、`rob_push_valid` 漏了 `f2i_valid[s]` —— 幽灵条目堵死 ROB 头

`issue_en` 是**整批**决定，而 `f2i_valid` 是**稠密前缀**（批内首个预测跳转之后的槽是错误路径，
`fetch.v:225`）。漏掉这一项后，那些槽用 `d_*`（decode 按 `d_valid` 门控 ⇒ 全 0）压进 ROB+RS：
幽灵条目 `opcode=0` 无功能单元认领 ⇒ `ready` 永不为 1（`rob.v` 唯一置位源是 CDB）⇒ ROB 头堵死。
**实测指纹**：无分支的 `naive` 过、凡有预测跳转的程序全挂。修：
`rob_push_valid[s] = issue_en && f2i_valid[s]`（该线同时喂 rob push 与 rs push）。

##### 三、提交链缺**占用窗口**检查 —— head 越过 last，`empty` 永不成立

`ce_w[c]`（c≥1）原来只要求前槽提交且资源就绪，没查"槽 c 是否在 ROB 占用窗口内"。
占用窗口 = `ROB_SIZE - free_count`（`rob.v` 的 `empty/full` 用的就是它，满/空**不靠 `head==last`**）。
越窗提交会把 `head` 推过 `last` ⇒ 占用量算成负 ⇒ `empty (free==ROB_SIZE)` 永不成立 ⇒
提交逻辑空转（**实测 W=2**：head 0→2→3→5→6→8 而 `robl` 恒 7，逐拍重复同一批陈旧槽，
`ret_latched_r` 永不置位；`naive` 停不下）。修：`cmt_in_win = (c < rob_occ)` 串进 `ce_w` 链。

##### 四、`old_map_chain` 的批内前递**回落到前一槽的 old** —— preg 重复分配（本轮根因）

```verilog
// 旧 (W>=2 才执行):
old_map_chain[s+1] = (d_writes_rd[s] && (d_rd[s] == d_rd[s+1])) ? alloc_val[s] : old_map_chain[s];
```
两个 rd **不同**时回落到 `old_map_chain[s]` —— 那是**另一个 rd 的映射**。正确值是
`map_arch[d_rd[s+1]]`（本槽自己的 RAT 映射）。后果两条，都实测到了：

1. **提交回收别人的 preg**（提前回收）⇒ `free_list` 池内出现重复项 ⇒ 同一 preg 发给两条在飞指令
   ⇒ 后者的生产者标签对不上 ⇒ 依赖者永不就绪 ⇒ **死锁**；
2. **walker 回滚把两个 rd 写成同一 preg** ⇒ RAT 失去单射性（`map[x12] == map[x13]`）。

**取证链**（`tb/top/tb_cpu_prog.v` 新增三条不变量检查，`+FLCHK=1` 开；全部不复制 RTL 索引表达式，
直接扫真实数组，免得镜像错误掩盖真相）：

| 检查 | 首报 | 说明 |
|---|---|---|
| `free_list` 池内重复项（O(n²) 扫 `u_fl.pool`）| `cyc=55` preg=43 @ `pool[12],[15]` sp=16 | 以及"本拍 push 的 preg 已在活动区"= `cyc=54 slot=1 preg=43 flushing=1`（**walker** 推的）|
| PREG 被两条在飞指令同时持有 | `cyc=59` preg=49 slot=0 | 证实重复项**真被发出去了** |
| RAT 单射性（32 选 2 两两比）| `cyc=25` x12,x13 → 37 | 最早可见的异常 |

trace 定位到源头：`T=20` 同一批 `rd=13 old=37` 与 `rd=12 old=37`（两条不同 rd 的**老映射相同**，
即 RAT 当时已经不单射）；`T=24` walker 两槽 `widx=0 rd=12 old=37` / `widx=31 rd=13 old=37`
把不单射性又写回去 —— 而这两个 old 正是 `T=20` 那批的**错误记录值**。

**修法**：按 `rat.v` 读口的同一规则（"读口 i 看 rename j<i，**最后匹配者赢**"）逐槽展平：
`s` 的 old = 本批**早于 s 的最大 j**（`d_writes_rd[j] && d_rd[j]==d_rd[s]`）的 `alloc_val[j]`，
无则 `map_arch[d_rd[s]]`。**W=1 时内层循环不执行**，表达式与旧代码逐字等价 ⇒ 频率/面积不受影响；
W≥2 才有 W² 项 mux 链（代价换正确性，见"待办"）。

**验证**：`gcd` 在 W=2 由挂死变为 `PASS ret=178 cycles=660`，且 `+FLCHK=1` **零违反**。
W{1,2,4} × 20 程序的矩阵见下节。

##### 五、`docs/plan.md` §15.10.13 表 5 的 div 结论已作废（RTL 已改）

该表写"W>1 靠槽 0 单点启动（`div_go_w = div_req_w[0] && …`）"。现行 RTL 是**任一槽都可发起**：
`div_gnt_w = div_req_w & (~div_req_w + 1)`（最低置位槽）、`div_go_w = (|div_gnt_w) && !div_busy && !flushing_r`、
`div_accept_w[s] = div_gnt_w[s] && div_go_w`，载荷走 one-hot AND-OR。W≥2 的死锁正是"只有槽 0 能启动"
这条设计引起的（高槽的 div 移不到槽 0 时 `q_freeze` 永不释放），故已按"任一槽发起"重做。

##### 六、`min-all` 的第二个挂死 = **参数不可行点**，不是缺陷：`PRF_SIZE ≥ 64` 的结构性下限

§15.10.13 §九 把这条记成"`ROB_SIZE=8 & PRF_SIZE=40` 挂死"。本轮把它拆开做**单变量对照**
（Icarus 全 RTL，`gcd`，`+PROG=gcd +DUMP=0`）：

| 配置 | 结果 | 冻结时状态（TB 新增 `FREELIST:` 行） |
|---|---|---|
| ROB=8, PRF=**40** | FAIL（timeout，commit 冻在 24）| `sp=0 FREE_NUM=8 mapped_ge32=8 rob_empty=1` |
| ROB=8, PRF=**64** | **PASS** `ret=178 cycles=810` | — |
| ROB=**64**, PRF=**40** | FAIL（同一状态、同一 pc） | `sp=0 FREE_NUM=8 mapped_ge32=8 rob_empty=1` |

⇒ **ROB_SIZE=8 无辜**（配 PRF=64 直接过），挂死完全由 `PRF_SIZE=40` 决定，且与 ROB 大小无关。

**机制（为什么这不是 bug）**：preg 0..31 是 RAT 复位恒等映射占用的身份区，**永不入池**；
池容量 `FREE_NUM = PRF_SIZE - 32`。某条指令写 x 时分配的 preg，**只有等 x 被再次写**（后一个写者的
`old_pnum`）才会回池 —— 所以"被架构映射占住的 preg"数**单调不减**，涨到"程序写过的不同寄存器数"为止。
于是稳态恒有

    sp = FREE_NUM - #{x : map_arch[x] >= 32}          (静默时刻, ROB 已排空)

**永久死锁 ⇔ 池空且再没有任何东西能 push** ⇔ `#{x : map_arch[x] >= 32} == FREE_NUM`（实测冻结态正是
`rob_empty=1, sp=0`，与判据逐项吻合）。又因 x0 只读不写，该计数**上界 31** ⇒

> **`FREE_NUM ≥ 32`（即 `PRF_SIZE ≥ 64`）时该永久死锁态不可达。** `PRF_SIZE=40`（FREE_NUM=8）
> 则在程序写到第 8 个不同目的寄存器时必然撞上 —— `gcd`/`expr` 会，`naive`（只写 6 个）不会。

**两次独立验证**（不是拟合出来的规则，是先有规则再验中段）：

| 程序 | 写过的不同目的寄存器数 | 结果 | 静默态 `sp` |
|---|---|---|---|
| `naive` @PRF=40 | 6 | PASS | `sp=2 = 8-6` ✓ |
| `expr` @PRF=40 | 8 | FAIL | `mapped_ge32=8 = FREE_NUM` ✓ |
| `gcd` @PRF=64 | 10 | PASS | `sp=22 = 32-10` ✓ |

注：**在飞指令把 sp 压到 0 不是致命态**（提交会还 preg，且提交通路不依赖改名）；致命的是"排空后仍为 0"。
故 `PRF_SIZE=40` 只是把"程序能写的寄存器数"限死在 7 个，属**参数选择错误**，RTL 无需改动。

**顺带建立的两条不变量检查（`+FLCHK=1`，已进 TB，长期保留）**：
1. **池/持有收支**：`u_fl.sp == FREE_NUM - popcount(preg_held)`（每拍查；破了就是漏回收/重复回收，
   首次违反时打印整个池与持有集）。本轮它**一次都没报** ⇒ 排除了"free_list 自己算错"这条路，
   才把矛头转到"架构映射合法占住 preg"上。
2. **分配必须入 ROB**：`rename_valid[i] && !rob_push_valid[i]` 即报（分配了却没进 ROB ⇒ 该 preg 永久泄漏）。
   同样零违反。
3. 测试结束打印 `FREELIST: <prog> sp=… FREE_NUM=… mapped_ge32=… rob_empty=…`，一眼可判档位是否够用。

## 消融 + 综合（报告素材）

- 矩阵：W{1,2,4} × ROB{16,32,64} × RS{8,16,24} × **PRF{64,96,128}** × LSQ{8,16,32} × BHT{16,32,128} ×
  **RAS{4,8,32}** × **Cache 容量{0,1K,2K,4K} × 相联度{1,2,4}**，跑**官方 `testcases/perf_*`**
  （6 个点取几何平均），记录 IPC / 提交 / 冲刷统计
  - **不再扫 MEM_LATENCY**：最终版 description.md 只有 **10 拍**一个延迟（框架 `LATENCY` 默认）。
    旧矩阵里的 `{3,20}` 两档已作废；延迟由框架侧给出，**不是本设计的参数**
  - **Cache 是新增的必扫维度**（官方明列的参数化项），且 `{0}` 档（旁路）是功能回退的安全网
  - **档位合法性已实测（iverilog 展开）**，两处必须避开：
    - **`RAS_SIZE = 0` 无法展开** —— `cpu_top.v:417` 报 "Indexed part select width must be an integral constants greater than zero"（`RA = $clog2(0) = 0` → 零宽位选）。最小可用档是 4。
    - **`PRF_SIZE = 32` 能展开但是退化配置** —— `free_list.v` 的 `BASE = 32` ⇒ 池容量 `FREE_NUM = PRF_SIZE - 32 = 0`，
      没有任何可分配的 preg，重命名失效。PRF 档位须 > 32。
  - 其余已验可展开：`RS_SIZE=4`、`ROB_SIZE=8`、`LSQ_SIZE=4`、`BHT_SIZE=16`、`RAS_SIZE=4/32`、`PRF_SIZE=96/128`。
    注意 `ROB_SIZE < 32` 时 `tb_cpu_prog.v:38` 的 `wire [$clog2(32)-1:0] rob_head` 宽度写死会触发 padding 警告（仅 TB 侧，不影响 DUT）。
- **官方口径实测：链路已通，真核仍无数据**（综合走容器，§13.5 已有冒烟：`mul` 包层 460.436 µm² / 478.95 MHz；
  真核基线是 **C8b**，阻塞在 `student_top` 与 `core/memory.v`）。
  旧流程的数字：全核 **7768.5 µm²**（memory 黑盒、**不计 SRAM 估算面积**、**无时序约束**），mul 554.6；
  详见 `docs/area_budget.md`（已标注口径与待办）
  - 达标口径（description.md §评分标准与时间安排 · 2）：**面积上限与最低 IPC 同时满足** ——
    **(9000, 0.6000) / (18000, 0.8450) / (36000, 1.0985)**；另有频率加分（400 MHz +2 / 500 MHz +4）
  - 旧数字相对新档 1 上限是 **86.3%（余量 1231.5 µm²）**，且**未计 SRAM** ⇒
    "面积不是瓶颈"这个旧结论**在新口径下未经验证**
  - IPC 评测口径是 **Verilator 跑 `testcases/perf_*` 的几何平均**（分子取 `metrics.json`），
    本仓库的 `+PERF=N` 只是内部对照，报告中须说明两者口径差异
- 可选消融点（报告素材）：RAT 快照恢复 vs walker、值捕获 RS vs 状态式、
  I/D 分离 vs 统一 L1、写直达+不写分配 vs 写回、MSHR 数 vs 行大小

---

#### 15.10.16 官方口径校验（W=1）与 W{1,2,4} 矩阵的现状 —— **W≥2 仍有未修缺陷**（2026-09-27）

##### 一、`pi` 的身份澄清：官方 pi 与本仓旧记录里的 pi **不是同一个程序**

| | 动态指令 | expected | HEAD × W=1 实测（官方流程，LATENCY=10）|
|---|---:|---:|---|
| 官方 `testcases/correctness_pi` | **3,117,658**（`metrics.json`）| 112 | **PASS `cycles=20,873,662`**（占 1e8 上限 **21%**）|
| 本仓 §15.9 表 / §11 记的 pi | 93,403,298 | 137 | 154,707,280 拍（`MEM_LATENCY=3` 口径）|

后者来自**旧本地测试集**（`tb/top/prog/` 体系；`naive` 同理：本地 94 / 官方 97）⇒ 两套周期数**不可比**，
旧表的"拍数"不能当官方用例的基线。**用户裁定（2026-09-27）：判据以官方为准 —— "只要过官方的 pi 就行了"。**
⇒ 官方 pi 在 HEAD × W=1 下**通过**，且余量充足（2.09e7 / 1e8）。旧记录保留作历史，不再作为门禁。

##### 二、W=1 官方口径正确性门禁：**19/19 PASS**（本轮实测；HEAD、LATENCY=10、上限 1e8）

| 用例 | cycles | 用例 | cycles |
|---|---:|---|---:|
| `correctness_add_to_100` | 654 | `correctness_multiarray` | 6,259 |
| `correctness_array_test1` | 777 | `correctness_naive` | 269 |
| `correctness_array_test2` | 819 | `correctness_pi` | **20,873,662** |
| `correctness_basicopt1` | 495,800 | `correctness_qsort` | 3,594,918 |
| `correctness_bulgarian` | 1,034,439 | `correctness_queens` | 1,340,657 |
| `correctness_expr` | 984 | `correctness_statement_test` | 2,635 |
| `correctness_gcd` | 675 | `correctness_superloop` | 1,994,608 |
| `correctness_hanoi` | 17,093 | `correctness_tak` | 5,751,104 |
| `correctness_lvalue2` | 291 | | |
| `correctness_magic` | 2,012,044 | | |
| `correctness_manyarguments` | 266 | | |

（前 18 条由 `runs/wdbg/build/sim` 逐条单跑取得，`expected` 取自各用例 `expected.txt`；pi 单跑。）
**注意**：上表周期数与 §15.9 旧表**不可比**（不是同一批程序，见 §一）。

##### 三、W=1 的 IPC 口径链（`perf_*` 六条 IPC 的几何平均）

| 点 | 六条 IPC（median / multiply / qsort / rsort / towers / vvadd）| geomean | 出处 |
|---|---|---|---|
| `head`（`1158a98`，预取窗口读口落地）| 0.2474 / 0.5719 / 0.2537 / 0.2985 / 0.2810 / 0.5940 | **0.3484** | 记录（§15.10.12；`results.csv` 行 `head`）|
| `pipe1`（手法 3）| 0.2317 / 0.5581 / 0.2397 / 0.2907 / 0.2760 / 0.5499 | **0.3332**（−4.4%）| 记录（`results.csv` 行 `pipe1`）|
| `wb1`（手法 4）| 0.2287 / 0.5492 / 0.2306 / 0.2531 / 0.2745 / 0.5124 | **0.3178**（−4.6%）| `results.csv` 行 `wb1`（geomean 本轮现算）|
| **HEAD × W=1**（默认参数）| 0.2402 / 0.5506 / 0.2361 / 0.2531 / 0.2748 / 0.5125 | **0.3219**（+1.3%）| **本轮实测**（官方 `make perf`）|

两条结论：

- **更正**：本轮 W=1 相对 0.3484 的 **−7.6%** **不属于预取窗口** —— 预取窗口 09-24（`07b42dd`）就落地了，
  已含在 0.3484 基线内。这 −7.6% 应归给**手法 3 + 手法 4**（两轮频率改造）；而这两手法的频率收益
  随后也被证伪（§15.10.13 净吞吐 +31.5%、§15.10.14 净 −57%）⇒ 频率线的总账见 §15.10.14 的表。
- `wb1` → 本轮 **+1.3%**（逐程序 +0.0% … +5.0%，主要来自 `perf_median`）⇒ `f983bfe` 的四条 W≥2
  修复对 W=1 **基本中性**，是"行为保持"的旁证。

##### 四、两条口径陷阱（工具已修，`206d869`）

- **正确性阶段不能用 1e7 上限**：官方 pi 需 **2.09e7** 拍 ⇒ 1e7 会把它变成一条**必然的假失败**
  （实测 W=1 `18 passed / 1 failed`）。`tools/sweep.sh` 已加 `SWEEP_TEST_MAX_CYCLES=1e8`（perf 仍 1e7）。
- **stdout/stderr 交错**：FAIL 行走 stderr（无缓冲）、用例头走 stdout（缓冲）⇒ 重定向日志里 FAIL 行
  **总排在所有用例头之前**，不能按邻近行归属；只能找"后面没有 PASS 的那个用例头"（脚本已内置该解析）。

##### 五、W{1,2,4} 矩阵现状：**W≥2 未通过**（矩阵缺第 2/4 行）

> ⚠️ **本节是 2026-09-27 当时的状态记录，已被 `docs/plan.md` §15.10.19 取代**（W≥2 已于 2026-09-28
> 转全绿：W=1 / W=2 两套 19 条全量 19/19 PASS，W 轴 IPC 见 §15.10.19 §四）。保留原文仅为留档。

| 证据 | W=1 | W=2 |
|---|---|---|
| 官方 `make test`（1e7 上限）| 18 passed / 1 failed（唯一失败 = pi，见 §四）| **≥8 条 `cycles=10000000` 超时**（测试阶段仍在跑，计数还在涨）|
| 官方单跑 `correctness_add_to_100`（1e8）| PASS 654 拍 | **5.5 分钟 CPU 未返回**（被打断，未取到判词）⇒ 与 W=1 差 ≥5 个数量级 |
| Icarus TB 小程序（`tb/top/prog/`，HEAD 重建的 `ISSUE_WIDTH_TB=2` 二进制）| 全过 | **`expr` 超时**（`halt=0 pc=00001150 commit=270`；W=1 时 984 拍跑完）；**`array_test1` 报池不变量违反**；其余 6 条（naive / gcd / array_test2 / statement_test / lvalue2 / manyarguments）通过 |

`array_test1` 的完整现场（`vvp -N /tmp/w2h.vvp +PROG=array_test1 +DUMP=0 +FLCHK=1`）：

```
FAIL: push dup preg=37 slot=1 (pool[5]) flushing=1 cyc=151     ← 回收把已在池里的 preg=37 又推进池
FAIL: pool/held mismatch sp=10 held=23 expect_sp=9 cyc=152     ← 收支差 1（池里多出 1 项）
FAIL: PRF reused-while-held preg=52 slot=1 cyc=172             ← 后果: 仍在飞的 preg 被重新分配
（池内容打印: 37 同时出现在 pool[5] 与 pool[9] ⇒ 确实是重复项）
```

- **定性**：**回收路径在 W≥2 会把同一个 preg 推入两次**（现象带 `flushing=1`，即误预测回滚期），
  池中的重复项随后被重新分配 ⇒ 依赖者判就绪出错 / 生产者标签对不上 ⇒ **挂死**（`expr` 的形态）。
  **机制未定位** —— 候选（待验证，勿当结论）：① walker 的回滚范围/指针在 W≥2 重复回滚同一条目；
  ② 提交路径与 walker 同拍回收同一个 preg。
  > **后续（§15.10.17 §一，2026-09-28）**：机制已定位 —— 根因**不在**这两条回收路径本身，而在
  > **ROB 的占用计数**：`free_r` 未按本批 push 数预留 ⇒ `1-2` 下溢回绕 63 ⇒ 提交越窗 + walker 回滚到
  > 从未 push 的残留槽，两条路径**共同**推出重复 preg。已修（`3b71fd7`）；`array_test1` 在 W=2 转 PASS。
- **结论**：`f983bfe` 修的四条**不是 W≥2 缺陷的全部**；报告 W{1,2,4} 消融矩阵的 **2/4 两行仍缺**，
  现阶段只能以 W=1 单点 + "W≥2 待修"呈现。

##### 六、未完成项（下一轮起点）

1. **W≥2 池重复 / 挂死定性**：起点 `verilog/core/free_list.v` 的 push 路径 + `cpu_top.v` 的 flush 回收接线
   （walker `push new_pnum` / 提交 `push old_pnum` 两条路径，见 `docs/architecture.md` B5/B6）。
   重建 W≥2 的 TB 二进制（`MAX_CYCLE` 压到 30000 ⇒ 卡死用例 40 秒内就报超时）：

   ```sh
   iverilog -g2005 -s tb_cpu_prog -Ptb_cpu_prog.ISSUE_WIDTH_TB=2 -Ptb_cpu_prog.MAX_CYCLE=30000 \
       -o /tmp/w2h.vvp $(ls verilog/*/*.v) tb/top/tb_cpu_prog.v
   vvp -N /tmp/w2h.vvp +PROG=array_test1 +DUMP=0 +FLCHK=1     # 池重复现场
   vvp -N /tmp/w2h.vvp +PROG=expr +DUMP=0                    # 挂死现场
   ```

   修好后 W=2/W=4 的 `make test` 须用 `SWEEP_TEST_MAX_CYCLES=1e8` 重跑。
2. **W=2/W=4 的 perf IPC**：`tools/sweep.sh w14` 仍在跑（W=1 已出，见 §三）。
3. **频率线**：拆 `rs.v:237` 的 `pvalid_w`（ABC CSE 共享使能热点，归因见 §15.10.14）。

#### 15.10.17 W≥2 第三轮：缺陷 5/6 定位修复（两条），取指流控的两处改写**回归并退回**（2026-09-28）

**本轮目标**（用户裁定）：只做**正确性门禁**（不碰 IPC / 面积 / 频率消融）；根因需要时允许结构性改动。

##### 一、缺陷 5（已提交 `3b71fd7`）：ROB 未按本批 push 数预留 —— `free_r` 下溢回绕

根因与后果见该提交信息，要点：`resources_ok` 只查 `!rob_full`（空闲 ≥ 1）是 **W=1 口径**，W≥2 一批 2 条
可以塞进只剩 1 个空位的 ROB；`free_r` 是 RCW 位计数器，`1-2` 下溢回绕成 63 ⇒ 占用量
`rob_occ = ROB_SIZE - free_r` 越界（33 > ROB_SIZE）⇒ (a) `cmt_in_win = (c < rob_occ)` 这条**越窗提交补丁**
（§15.10.15 §三）被回绕整条绕过、(b) `last_r` 越过真实占用 ⇒ walker 从 `last_r-1` 起回滚会走到
**从未 push 过的残留槽** ⇒ 其 `new_pnum` 被重复回收。两条路径都产生池内重复项，且 `empty`
（`free_r == ROB_SIZE`）长期不成立 ⇒ 停机锁存永不置位。修法：按住本批实际有效指令数预留
`rob_free_w >= n_valid`（W=1 时与 `!rob_full` 逐值等价）。

**本轮结案**：§15.10.16 §五 的"池内重复 preg"现场（`array_test1`）**不是** walker / 提交两条回收路径
各自的缺陷（当时的候选①/②都不对），而是 **ROB 占用计数被回绕打穿后的共同后果**。

**验证**：缺陷 5+6 都生效的构建里，官方 W=2 `array_test1` **PASS 819 拍**（该用例正是缺陷 5 的现场；
缺陷 5 单独生效的旁证是 Icarus TB 由 `push dup preg=37` 转 PASS ret=123 cycles=245，见该提交信息）。

##### 二、缺陷 6（本轮提交）：`mem_subsystem.imem_addr_q` 未按 `ISSUE_WIDTH` 声明

```verilog
- reg [31 : 0]                   imem_addr_q;      // ≡ fetch.v 的 imem_addr_d
+ reg [ISSUE_WIDTH * 32 - 1 : 0] imem_addr_q;      // 复位那行本来就写 slot_init_f 的全宽值 (逐槽 4*g)
```

交付逻辑（读口 A'）按槽取 `imem_addr_q[g * 32 +: 32]`，只声明 32 位时 **g≥1 越界** —— Verilator 报
`SELRANGE` 并退化成槽 0 的值（**W=1 只有槽 0，表达式逐位等价 ⇒ 不可见**）。后果：槽 1 用槽 0 的窗口项
判命中 / 取数据，而 `slot_hit` 仍为全 1 ⇒ `imem_valid` 说"这批对"，实际交付的是别的字。

**验证**（`runs/w2f2` = HEAD + 上面这一行；官方判据，LATENCY=10）：

| 用例 | W=1（§15.10.16 §二）| W=2（本轮）|
|---|---:|---:|
| `correctness_add_to_100` | PASS 654 | **PASS 462**（result=5050）|
| `correctness_array_test1` | PASS 777 | **PASS 819**（result=123）|
| `correctness_array_test2` | PASS 819 | FAIL（1500 拍内不终止，见 §四）|

构建日志：`SELRANGE` 只剩 `exec/execute_slot.v:236` 一条（`resv` 的 `(j < ISSUE_WIDTH) ? … : load_cdb_result`
mux）—— 那是**设计使然**的越界选择告警，非缺陷；`mem_subsystem` 的 SELRANGE **归零**。

##### 三、取指流控的两处改写：都**回归**，已从工作树退回（留档，勿直接重做）

**（真）死带**：`pf_issue` 的上界是 `pf_ahead_w < PF_WIN*4`（=32），而"拉回流"的门限是
`pf_stale_w = pf_ahead_w >= PF_DEPTH*4`（=64）⇒ 超前量落在 **[32, 64)** 时**既不取新的、也不拉回**。
本轮在**缺陷 6 修复版构建**上实测（W=2、官方 `array_test2`、LATENCY=10，t=1493 采样）：

```
pc_r = 0xC4 / exp_pc_r = 0xBC (自 t=457 冻结) / cap_w = 0
demand_a = 0xBC (imem_addr_q 槽 0)，pf_next_r = 0xE4 ⇒ pf_ahead_w = 0x28 = 40 ∈ [32, 64)
⇒ pf_issue 恒 0、流冻结 ⇒ 期望批 {0xBC, 0xC0} 永不凑齐 ⇒ pc_r 在 0xBC/0xC4 每拍翻转 (1396 次 / 1500 拍)
```

**为什么"按槽 0"与"按批"会互相打架**：`demand_a` 只锚 `imem_addr_q` 的**槽 0**（`mem_subsystem.v:240`），
而 `imem_valid = &slot_hit`、`cap_w` 要求**整批**到齐 —— W≥2 时两套口径不一致：流只要把槽 0 那一行弄进
窗口，`imem_hit=1` 就允许 `pc_lead` 把请求推到下一批，而下一批的**槽 1** 可能还没进窗口 ⇒ 下一拍 `cap_w`
落空 ⇒ `pc_next` 退回 `exp_pc_r` ⇒ 请求地址每拍翻转 ⇒ 流控被反复触发（这正是 W=1 看不到的形态）。

**尝试 A：流地址改写**（把"拉回指针 + 本拍不发"拆成"本拍就地取 demand"）：

```verilog
wire pf_out_w  = (pf_ahead_w >= (PF_WIN * 4)) || !dem_hit;
wire [31 : 0] pf_addr_w = pf_out_w ? demand_a : pf_next_r;
wire pf_issue = !pf_dup_w && !pf_pend_w;            // 上界改由 pf_addr_w 的选择隐含
// 时序侧: pf_next_r <= pf_addr_w + 4；pf_tag_r[pf_idx_w * 32 +: 32] <= pf_addr_w
```

动机是消掉上面的死带（原写法隐含假设"流不可用期间 demand 静止"—— W=1 成立：未命中 ⇒ `imem_valid=0`
⇒ fetch 冻结 PC；W≥2 下 demand 会被 `pc_lead` 推着每拍变）。**实测：W=2 三用例全红** ——
`add_to_100`/`array_test1` 由 PASS 变成 200000 拍不终止。

**尝试 B：`imem_hit` 逐槽全中**（`assign imem_hit = &hit_cur;`，逐槽按 `imem_addr[g*32 +: 32]` 查 V/T 两位）：

```verilog
generate for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : ihit
    wire [PF_DEPTH - 1 : 0] mv, mt;                 // oh_g[gp] = (imem_addr[g*32+2 +: PF_IW] == gp)
    assign mv[gp] = pf_ent[gp * PFW + PO_V] & oh_g[gp];
    assign mt[gp] = (pf_ent[gp * PFW + PO_T +: 32] == imem_addr[g * 32 +: 32]) & oh_g[gp];
    assign hit_cur[g] = (|mv) & (|mt);
end endgenerate
```

**实测**：`array_test2` 的 PC 振荡**消失**（推进到 0x3C 的停机自环、逐拍提交 1 条），但 `add_to_100`
由 PASS(462 拍) 变成 1e8 拍不终止（波形 `pc_r` 在 0x34/0x3C 每拍翻转）⇒ 单独收紧会把流指针挡在
批内第二字之外：流只按槽 0 的 demand 走，收紧后没有任何一拍能满足"整批都在窗口里"。

> **更正（§15.10.18，2026-09-28）**：上面这段"尝试 B 回归"是**误判**。当时工作树里同时躺着 A
> （`pf_addr_w` 改写），实测到的"B 回归"其实是 **A+B** 与 **A 单独**两个构建；把 A 彻底退回后
> **B 单独**重测，W=2 三用例全过（`add_to_100` 460 / `array_test1` 811 / `array_test2` 846）。
> 真正回归的是 A。本段的机制解释（"收紧后没有任何一拍能满足整批都在窗口里"）作废。

**共同结论（下一轮起点）**：W≥2 的取指必须**以批为单位**流控。两条候选：
① `demand_a` 取**批内最后一槽**（锚点搬到批尾，让批内所有字都落在流的后方 —— 需同时允许流回退到批首）；
② 命中判定改"整批 W 个地址都在窗口" **且**前瞻窗口以批尾为锚（**A 与 B 必须同拍落地**，单独做任一条都回归）。

> **更正（§15.10.18）**：候选 ② 的**前半条**（`imem_hit` 改整批口径）就是解，**单独落地即可**；
> `demand_a` 锚点**无需改动**（A 已完全退回），"必须同拍落地"的结论不成立。

##### 四、W=2 门禁现状（`runs/w2f2` = HEAD + 缺陷 6；官方判据 LATENCY=10）

| 用例 | W=1 | W=2 | 备注 |
|---|---:|---:|---|
| `correctness_add_to_100` | PASS 654 | **PASS 462** | |
| `correctness_array_test1` | PASS 777 | **PASS 819** | 缺陷 5 的现场用例 |
| `correctness_array_test2` | PASS 819 | **FAIL** | `pc_r` 0xBC/0xC4 每拍翻转（§三 死带）|

其余 16 条未重跑（W≥2 全绿前不做 W{1,2,4} 矩阵，见 §15.10.16 §六）。

##### 五、未决线索（**证据不足，勿当结论**）

1. **停机 store 的操作数疑似出错**：在**尝试 B 的构建**（该构建取指本身在振荡）下观测到 W=2 `array_test2`
   的 `sw x10, 0(x5)`（PC=0x38）提交时 `sw_addr_c = 0x34`（= x1/ra 的值；而 0x34 处的 `lui x5, 0x80000`
   本该先写 x5）、`sw_data_c = 0`（整轮未变）⇒ AXI 上 `wr_req_addr = 0x34`、`wr_req_data = 0`，
   官方停机判据（对 0x80000000 做 WSTRB=0xf 的 store）永不触发。**但**：错乱可能只是取指回归的后果；
   且 `set_addr_idx=10` / `set_data_req` 都对准了停机 store 的 LSQ 条目 ⇒ **尚未**定位到操作数路径本身。
   **待取指干净后复核**，再决定是否另开缺陷条目。
2. **`lsq_push_valid[s] = issue_en && memop` 漏 `f2i_valid[s]`**（`cpu_top.v:522`）—— 与 `rob_push_valid`
   （`:502`）、`mem_cnt_chain`（`:625`）、`mem_acc`（`:530`）的口径不一致。本轮 `array_test2` 里每个 memop
   压入时 `f2i_valid` 都是 `11` ⇒ **没有**触发幽灵压入（不是当前挂死的原因）；但批内有预测跳转时，
   高槽 memop 会以全 0 的宽/地址/数据幽灵压入 LSQ ⇒ 应修，**本轮未动**（避免与在改的取指问题混淆）。

   > **撤回（§15.10.18 §五，2026-09-28）**：**不是缺陷，不需修改**。`memop = d_is_load[s] || d_is_store[s]`
   > 来自 decode，而 decode 的 `is_load/is_store` 已被 `valid = d_valid[i] && …` 门控，`d_valid` 就是
   > `f2i_valid`（`cpu_top.v:135` 组合直连、同拍同源）⇒ `memop` **已含** `f2i_valid[s]`，与
   > `rob_push_valid` 本就同口径。上轮记为"漏项"是只比对了字面表达式、没追 decode 的门控来源。

##### 六、下一步

1. 按 §三 的共同结论做**以批为单位**的取指流控（`demand_a` 锚点 + 命中判据**同拍**落地）。
   验证顺序：W=2 三用例 → W=2 全 19 条（`SWEEP_TEST_MAX_CYCLES=1e8`）→ W=4 → W=1 回归。
2. 修 §五.2 的 `lsq_push_valid`。
3. 复核 §五.1 的操作数线索。

#### 15.10.18 W≥2 第四轮：取指流控**根因落地修复**（单点改 `imem_hit`）—— W=2 转绿（2026-09-28）

##### 一、根因：`imem_hit` 是"槽 0 口径"，而交付/接收是"批口径"

fetch.v 的三个口径（`docs/architecture.md` 取指一节同款）：

| 量 | 含义 |
|---|---|
| `pc_r` | **本拍**发给存储的批地址（`imem_addr[g*32 +: 32] = pc_r + 4g`）|
| `exp_pc_r` | **下一拍**要交付/接收的批地址 |
| `imem_addr_d` | 本拍 `inst_data` 对应的批地址（= 上一拍的 `pc_r`）|

- 接收: `cap_w = arr_ok_w && cap_ok_w && !halt && imem_valid`；其中 `arr_ok_w = (imem_addr_d[0*32 +: 32] == exp_pc_r)`
  只比**批首**，而 `imem_valid = &slot_hit`（W 个槽逐槽 V+tag 全中）要**整批**。
- 超前: `pc_lead_w = pc_behind_w && imem_hit && !stall` —— 原 `imem_hit` 只比**槽 0**
  （`imem_addr[0*32 +: 32]` 在窗口里有 V 且 tag 相等），**与 `imem_valid` 不同口径**。

⇒ "槽 0 已回、槽 1 未回"时: `pc_lead=1` 把本拍请求推到 `pc_r + 4W`；下一拍 `arr_ok=1`（批首对得上）
但 `imem_valid=0`（整批没凑齐）⇒ `cap_w = rewind_w = pc_jmp_w = 0` ⇒ `pc_next` 落到末支 `exp_pc_r`
⇒ `pc_r` **退回** N；再下一拍槽 0 仍在窗口里 ⇒ `pc_lead` 又把它推走 ⇒ **请求地址每拍在 N / N+4W
之间翻转**，而存储每拍重复交付 `exp_pc_r` 那一批（永远凑不齐）。

实测（修复前的构建，W=2，`correctness_array_test2`，LATENCY=10）:
`exp_pc_r` 自 t=457 冻结在 `0xBC`；`pc_r` 在 `0xBC`/`0xC4` 每拍翻转（1500 拍里变了 1396 次）。
预取流锚点 `demand_a = imem_addr_q[槽 0]` 随之每拍翻转 ⇒ 流控的两个判据（`pf_ahead_w < PF_WIN*4`
放行、`>= PF_DEPTH*4` 拉回）都在**相对量**上被绕开 ⇒ 流稳定停在 `pf_next_r = 0xE4` / `demand_a = 0xBC`
（ahead = 40 ∈ [32, 64)）⇒ 期望批 {0xBC, 0xC0} 的缺字**永远取不回** ⇒ 取指永久停摆。

**更正 §15.10.17 §三**: 那个"死带"不是流自己跑出去的**绝对**位置，而是被 `pc_r` 抖动撕扯出来的
**相对**位置 ⇒ `imem_hit` 改批口径（= 该节的"尝试 B"）**单独就是解**。§三里把 B 判为回归是**误判** ——
当时工作树里同时躺着 A（`pf_addr_w` 改写），实测到的"B 回归"其实是 **A+B** 与 **A 单独**；本轮把 A
彻底退回后重测 B 单独，三用例全过（§四）。§三 "单独收紧会把流指针挡在批内第二字之外" 的解释作废，
"以批为单位流控需要锚点与判据同拍落地" 的结论也**不成立**（锚点仍只锚槽 0，无需改动）。

##### 二、修复（`mem_subsystem.v`，单点）

```verilog
wire [ISSUE_WIDTH - 1 : 0] hit_cur;
generate
    for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : ihit
        wire [31 : 0]           ac_g = imem_addr[g * 32 +: 32];
        wire [PF_IW - 1 : 0]    ic_g = ac_g[2 +: PF_IW];
        wire [PF_DEPTH - 1 : 0] oh_g;                       // 索引 one-hot (原读口 C 同构)
        wire [PF_DEPTH - 1 : 0] mv, mt;
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : ohc
            assign oh_g[gp] = (ic_g == gp[PF_IW - 1 : 0]);
        end
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : e
            assign mv[gp] = pf_ent[gp * PFW + PO_V] & oh_g[gp];
            assign mt[gp] = (pf_ent[gp * PFW + PO_T +: 32] == ac_g) & oh_g[gp];
        end
        assign hit_cur[g] = (|mv) & (|mt);
    end
endgenerate
assign imem_hit = &hit_cur;              // 整批 W 个字都在窗口里才为 1
```

- **语义**: `pc_lead` 是"把请求预先推到下一批"，前提必须是**下一拍交付的正是整批**；批没凑齐时请求停在
  `exp_pc_r` 上重复请求（`pc_next` 末支），存储每拍重复交付它 ⇒ 一旦补齐即可立即接收。
- **性能不损**: 批补齐的那一拍 `pc_behind_w=1` 且 `imem_hit=1` ⇒ `pc_lead` 与 `cap_w` **同拍**成立
  （cap 优先级更高，但两个分支算出的下一 PC 都是 `pc_r + 4W`）⇒ 超前请求照发，流水线仍是一批/拍。
- **W=1 逐位等价**: `&hit_cur` 退化成槽 0 的 V/tag 比对（与原表达式同构）⇒ W=1 行为不变（§四回归佐证）。
- **面积**: 读口 C 从 1 槽变 W 槽（逐槽 one-hot 16 + AND-OR 34 位），W=4 时 4 份 ⇒ 进 W{1,2,4} 面积消融看增量。

##### 三、A 为什么回归（留档，勿重做）

A（`pf_addr_w = pf_out_w ? demand_a : pf_next_r`，把 demand 就地取而不拉回指针）的回归**未定位到根因**
（A+B 同拍落地也实测不通过）⇒ 本轮**完全退回**，不再保留任何 A 的痕迹。B 单独即修复 ⇒ 无需 A。

##### 四、门禁（官方 `make test`，LATENCY=10，`MAX_CYCLES=1e8`）

三用例（官方单跑，判词与拍数）：

| 用例 | W=1 | W=2（缺陷 6 版，B 前）| W=2（B 后）|
|---|---:|---:|---:|
| `correctness_add_to_100` | PASS 654 | PASS 462 | **PASS 460** |
| `correctness_array_test1` | PASS 777 | PASS 819 | **PASS 811** |
| `correctness_array_test2` | PASS 819 | FAIL（`pc_r` 翻转 / 流停摆）| **PASS 846** |

W=2 全量 19 条（`runs/w2b`，`make test`，1e8 上限）：**跑到第 4 条 `correctness_basicopt1` 挂死**
（前 3 条 PASS 460/811/846；`basicopt1` 在 5e6 拍上限下单跑判 `FAIL cycles=5000000`）⇒ **全量门禁未过**。

归因：**不是 B 引入的** —— B 之前的构建 `runs/w2f2`（HEAD + 缺陷 6）在同一用例上同样 5e6 拍不终止，
而 W=1 只要 49.6 万拍（§15.10.16 表）⇒ **W≥2 还有第二条独立缺陷**（记作缺陷 7，下一轮定位）。

W=4 全量 19 条 / W=1 全量 19 条（回归对照）：**本轮已挂起后台门禁（`/tmp/gateB2.sh`），结果见下一次提交**。

##### 五、撤回一条"未决线索"（原 §15.10.17 §五.2）

`lsq_push_valid[s] = issue_en && memop`（`cpu_top.v:522`）**不是缺陷**：`memop = d_is_load[s] || d_is_store[s]`
来自 decode，而 decode 的 `is_load/is_store` 已被 `valid = d_valid[i] && ...` 门控，`d_valid` 就是
`f2i_valid`（`cpu_top.v:135` 组合直连，两信号同拍同源）⇒ `memop` 里**已经含** `f2i_valid[s]`，
与 `rob_push_valid`（`:502`）本就同口径。上轮把它记为"漏项"是**误判**（只比对了字面表达式，没追
decode 的门控来源）。**不需修改**。

##### 六、下一步

1. 复核 §15.10.17 §五.1 的停机 store 操作数线索（取指已干净）——若仍复现则另开缺陷条目。
2. 恢复 W{1,2,4} 消融矩阵：先 perf IPC（`tools/sweep.sh`，1e7 口径），再面积/频率（容器 `make synth`）。

---

#### 15.10.19 W≥2 第五轮：缺陷 7 拆成两条并双双修复 —— `correctness_basicopt1` 转绿（2026-09-28）

§15.10.18 收尾时 W=2 全量卡在第 4 条 `correctness_basicopt1`。本轮把它拆成**两条互不相干**的
缺陷（一条取指、一条后端），分别定位并落地修复，三用例 + `basicopt1` 四条定向用例齐绿。

##### 一、7a 预取流"死带"：拉回触发只看槽 0 ⇒ 批内缺字永久取不回（`mem_subsystem.v`）

W=2 官方 `basicopt1` 跑到 70 万拍时取指完全静止（VCD 末态，`T=2e6` 与 `T=3e6` **逐位相同**）：

| 量 | 值 | 含义 |
| --- | --- | --- |
| `pc_r` / `exp_pc_r` / `imem_addr_d` | 0xE8 / 0xE8 / {0xEC, 0xE8} | 请求批恒为 {0xE8,0xEC} |
| `arr_ok_w` / `imem_valid` / `imem_hit` | 1 / 0 / 0 | 槽 0 在、槽 1 缺 ⇒ `cap` 落空 |
| `pf_next_r` / `demand_a` | 0x108 / 0xE8 ⇒ **`pf_ahead_w = 32`** | 恰在发起上界（`< 32`）之外 |
| `dem_hit` / `pf_issue` / `pf_restart` | 1 / 0 / 0 | 不发（上界）也不拉回（旧触发只看 `dem_hit`）|
| `pf_pend_r` / `pf_valid_r` | 0 / 0xffff | 无在飞、无泄漏 |
| 窗口 idx 11 的 tag | **0xAC**（应为 0xEC）| 0xAC 与 0xEC 差 0x40 = 一整跨度，索引同为 11 |

机制：流的指针**不只靠发起推进** —— `pf_dup_w`（前方已有数据）跳过时也推进，且**不受 `PF_WIN*4` 上界约束**
⇒ 指针停在 `ahead ∈ [32, 64)` 是**可达**状态。该区间里"不发（上界）也不拉回（旧触发只比槽 0 的 `dem_hit`）"
⇒ 批内缺的那个字（0xEC，被一次向后分支重走 0xA8 段时同格覆盖）**永远取不回**。后端随之空转：
`rob_empty` 曾为 1、LSQ 空、AXI 读队列全空、`rd_req_valid` 恒 0 —— 全机只等取指。

修正（`mem_subsystem.v:284`）：

```verilog
wire pf_beyond_w = (pf_ahead_w > ((ISSUE_WIDTH - 1) * 4));
wire pf_restart = !dem_pend && (pf_next_r != demand_a)
                  && (pf_stale_w || (!imem_valid && pf_beyond_w));
```

触发口径由"槽 0 未命中"改为"**期望批整批**未在窗口"（`imem_valid ≡ &slot_hit`，与接收侧同口径），
并用 `pf_beyond_w` 限定"指针**已走过整批**才拉回" —— 少了这个限定词就是**活锁**：指针在批内朝缺字
走时会被反复拉回，那一笔永远发不出。W=1 时 `(ISSUE_WIDTH-1)*4 = 0` 且 `imem_valid ≡ dem_hit`
⇒ 与原表达式**逐位等价**。

顺带清掉被这次改写**孤立**的两条 wire：`dem_valid = sel_dem[PO_V]` 与 `dem_hit = dem_valid &&
(dem_tag == demand_a)` —— 改口径后全仓再无读者（Verilator `UNUSEDSIGNAL: dem_hit` 也是这么报的），
`dem_tag` / `dem_pend` 保留。删除后定向用例周期数与删除前**逐位相同**（W=2 四条 477 / 768 / 966 /
546121，W=1 三条 654 / 777 / 819）⇒ 纯死码清理，无行为影响；`UNUSEDSIGNAL: dem_hit` 随之消失。

##### 二、7b 误预测当拍**全局**清 Q 级 ⇒ 冻结槽里的正确路指令被销毁（`execute_slot.v` + `cpu_top.v`）

7a 修好后 `basicopt1` 越过取指挂点，又停在**另一个**现场（`T=2e6` 起逐位静止）：

| 量 | 值 |
| --- | --- |
| `pc_r` / `imem_valid` | 0x14C / 1（**取指正常**，不是饿死）|
| ROB 头 tag 17 = `0x02AE6E33` | `rem x6,x28,x10`，`ready_r[17]` 恒 0 |
| `commit_count` / `halt` | 30481（冻结后不变）/ 0 |
| RS 有效条目 | 只剩 tag 20/21/22/23（17 不在其中）|
| 除法器 | 最后一次发起是 tag 29，**发起序列 1,5,13,25,29 跳过 17**，t=84135 后再没启动 |
| `resources_ok` | 0（free_list/LSQ 闸）⇒ 谁也发不出去 ⇒ 死锁 |

追踪（RS 逐条目逐拍 + Q 级逐槽）：

1. cycle 41950：tag 17 被压入 RS 条目 6；**同拍入选** ⇒ `rs_clear_valid = sel_valid & ~pipe_stall`
   把它清了（RS 条目在入选那拍就清，这是设计不变量 1）；同拍进入**槽 1 的 Q** ⇒ Q 是唯一副本。
2. cycle 41951–41973：除法器忙（tag 13 在飞），`div_go_w=0` ⇒ `div_accept=0` ⇒ `q_freeze=1`，
   槽 1 的 Q 一直**冻着**（`is_div[1]=1` 全程），同时槽 0 的 Q 前进了好几条。
3. cycle 41972：**槽 0** 的 Q（tag 24 的一个分支）误预测 —— `misp_fs_w=24`、`rob_head_w=8`、
   `fs_eff_w=24`；cycle 41973 `flushing_r` 起 ⇒ `flush_hit = misp_valid`（**全局广播**）把**两槽**
   的 Q 都清了 ⇒ 槽 1 里 tag 17 的 Q 副本被销毁。

关键点：**冻结让两槽 Q 失去年龄序**。槽 1 冻住期间槽 0 前进，于是槽 1 的 Q（tag 17）**比误预测分支
（tag 24）更老** ⇒ 它是**正确路**（ROB 截断只丢 fs 之后的条目 ⇒ 17 留在 ROB 且成为卡住的头）。
它的 RS 条目早已清掉、Q 副本又被销毁 ⇒ **指令凭空消失** ⇒ 它的 ROB 条目永不就绪 ⇒ 提交停摆 ⇒
free_list 漏干 ⇒ `resources_ok=0` ⇒ 全机死锁。

`execute_slot.v` 头部的**不变量 3**（"寄存器里那条就是检出误预测的分支本人"）**只在 W=1 成立**：
W≥2 下另一槽可以冻着一条更老的。而 `pipe_stall` 的注释其实已经写明了同类推理（"它可能比误预测分支
更老…清了就是指令丢失 ⇒ 死锁"），只是那条保护只加在 **D 级 `rs_clear`** 上，没加到 **Q 级 `flush_hit`**。

修正：`flush_hit` 改由 cpu_top **逐槽**给出，口径与 `rs`/`lsq` 失效掩码、`div_kill` 完全一致
（年龄 ≥ 冲刷点 ⇒ 分支本人/错路 ⇒ 清；更老 ⇒ 正确路 ⇒ 保住）：

```verilog
wire flush_hit_s = misp_valid
    && (!q_freeze_s || ((q_rob_tag_s - rob_head_w) >= (fs_eff_w - rob_head_w)));
```

`!q_freeze` 那一支：本拍 W 级会收下它（结果/重定向照发，与旧行为一致），清掉只等于"不放新指令进来"。
为此 `execute_slot` 新增两个输出 `q_freeze` / `q_rob_tag`（Q 级冻结标志与 Q 级条目的 rob_tag）。
**死循环红线**（旧注释里"若改成冻住 ⇒ `misp_valid` 常 1"）仍然守住：一条**误预测的分支**必然
要么是 fs 的来源槽（年龄相等 ⇒ `>=` ⇒ 清），要么槽号更高（更年轻 ⇒ 年龄更大 ⇒ 清）。

W=1 差异只在**嵌套误预测**那一格：`flushing_r=1` 且当拍又有更老的误预测时，Q 里那条若更老
（正确路）现在**保住**、旧写法会销毁它 ⇒ 是修好而非行为等价，故 W=1 全量必须重跑（见 §三）。

##### 三、结果（官方口径，`LATENCY=10`）

| 用例 | W=1 | W=2（B 之后，本轮前）| W=2（本轮 C′ + 逐槽 flush_hit）|
| --- | --- | --- | --- |
| `correctness_add_to_100` | PASS 654 | PASS 460 | **PASS 477** |
| `correctness_array_test1` | PASS 777 | PASS 811 | **PASS 768** |
| `correctness_array_test2` | PASS 819 | PASS 846 | **PASS 966** |
| `correctness_basicopt1` | PASS 495800 | FAIL（5e6 拍不终止）| **PASS 546121** |

两个补口都已落到工作树，且与所测变体树 `runs/w2d` **去注释后逐字节一致**（仅一处空行差）。

**全量 19 条**（`make -C runs/<id> CONFIG=config.local.mk MAX_CYCLES=100000000 test`，两套**并行**跑）：

| 用例 | W=1 周期 | W=2 周期 | W=2 / W=1 |
| --- | ---: | ---: | ---: |
| `correctness_add_to_100` | 654 | 477 | 0.729 |
| `correctness_array_test1` | 777 | 768 | 0.988 |
| `correctness_array_test2` | 819 | 966 | 1.179 |
| `correctness_basicopt1` | 495800 | 546121 | 1.101 |
| `correctness_bulgarian` | 1034439 | 948491 | 0.917 |
| `correctness_expr` | 984 | 1009 | 1.025 |
| `correctness_gcd` | 675 | 687 | 1.018 |
| `correctness_hanoi` | 17093 | 20375 | 1.192 |
| `correctness_lvalue2` | 291 | 332 | 1.141 |
| `correctness_magic` | 2012044 | 2469259 | 1.227 |
| `correctness_manyarguments` | 266 | 290 | 1.090 |
| `correctness_multiarray` | 6259 | 6430 | 1.027 |
| `correctness_naive` | 269 | 332 | 1.234 |
| `correctness_pi` | 20873662 | 20870359 | 1.000 |
| `correctness_qsort` | 3594918 | 4049850 | 1.127 |
| `correctness_queens` | 1340657 | 1736994 | 1.296 |
| `correctness_statement_test` | 2635 | 3164 | 1.201 |
| `correctness_superloop` | 1994608 | 2635246 | 1.321 |
| `correctness_tak` | 5751104 | 7248759 | 1.260 |

**两套都是 `Results: 19 passed, 0 failed`** ⇒ W=2 正确性门禁（本轮范围）**通过**；W=1 全量复跑确认
7b 那处"嵌套误预测保住更老 Q"的差异确实只在正确方向（周期数与 §三 上表 W=1 列一致）。

⚠️ **顺带暴露的、本轮未处理的反常**：`correctness_*` 上 W=2 在 **15/19** 条周期数**高于** W=1
（几何平均 **1.099×**，最差 `superloop` 1.321×、`queens` 1.296×），只有 `add_to_100`（0.729×，
短用例受判分口径影响大）、`bulgarian`（0.917×）、`pi`（1.000×）、`array_test1`（0.988×）不升。
`correctness_*` 不是评分口径，这一反常**是否迁移到评分口径见 §五**（实测答案：**基本不迁移**）。

##### 四、W 轴 IPC 口径（本轮实测，官方 `make perf`，`LATENCY=10`）

| 点 | `perf_median` | `perf_multiply` | `perf_qsort` | `perf_rsort` | `perf_towers` | `perf_vvadd` | **geomean** |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **W=1**（`runs/w1g`）| 0.2402 | 0.5506 | 0.2361 | 0.2531 | 0.2748 | 0.5125 | **0.3219** |
| **W=2**（`runs/w2d`）| 0.2893 | 0.6666 | 0.2564 | 0.2266 | 0.1877 | 0.5672 | **0.3257** |
| W=2 / W=1 | 1.204 | 1.211 | 1.086 | **0.895** | **0.683** | 1.107 | **1.012** |

- W=1 那一行与 §15.10.16 §三 记录的 `HEAD × W=1` 基线（0.2402 / 0.5506 / 0.2361 / 0.2531 /
  0.2748 / 0.5125）**逐位相同** ⇒ 本轮两处后端改写（逐槽 `flush_hit`、死码清理）对 W=1 无扰动。
- **更正 §三 的预测**：那里写"跑 `perf_*` 大概率同病"，实测**否定** —— 评分口径上 W=2 是 **+1.2%**
  （6 条里 4 条变好，`median`/`multiply` 各 +20%）。所以"W=2 更慢"是 `correctness_*` 那批**长跑程序**
  上的现象，没有整体迁移。但 **`perf_towers` −32%、`perf_rsort` −10%** 两条是真实且独立的回归，
  仍有排查价值（`towers` 是递归/调用密集，`rsort` 访存密集 —— 怀疑方向：分支密集下"批内槽 1 是
  错路"白吃取指供给、访存密集下 `PF_WIN` 的取指/load 带宽切分）。
- **要注意的量级**：当前 **IPC ≈ 0.32，距档 1 的 `0.6000` 还差 ~46%** —— 这才是挡在评分目标前的
  主要矛盾；W 轴的 ±1% 在这个缺口面前是噪声。

##### 五、下一步

1. **先把 IPC 缺口（0.32 → 0.60）当成主攻方向**：`docs/architecture.md` 已认定"cache 是面积换 IPC
   的主旋钮"，而无 cache 时取指被**单条 AXI 读口**限死在 ≤1 字/拍（[`mem_subsystem.v:516`]
   `rd_req_valid = ld_accept || pf_issue`，load 还优先）—— W=2 的平均取指带宽并不比 W=1 高，
   这与本节的 W 轴数据自洽。
2. W{1,2,4} 消融矩阵：W=1 / W=2 两档 IPC 已齐（本节），面积/频率档待跑；~~**W=4 按指示暂不跑**~~
   —— **已由 §15.10.20 完成**（W=4 门禁转绿 + 三点 IPC 齐；面积/频率档仍待容器跑）。
3. 复核 §15.10.17 §五.1 的停机 store 操作数线索（19 条全量未复现，若无新现场暂挂）。

#### 15.10.20 W=4 轮：三档门禁齐绿 + W 轴 IPC 三点 + 缺陷 8/9（2026-09-28）

§15.10.19 收尾时 W=1/W=2 两档 19/19 PASS、IPC 各一点，W 轴消融矩阵缺 W=4 这一行。
本轮把 `ISSUE_WIDTH=4` 补上：**先过正确性门禁（暴露并修掉两条缺陷），再补 IPC 点**。
⚠ 与 W=2 那轮不同，本轮有**一条修复对 W=1 同样生效**（缺陷 8）⇒ W=1 的旧数字**不能直接复用**，
三档全部用当前 RTL 重跑（见 §五 的对照实验）。

**参数（除 W 外与 W=1/W=2 完全一致，保证是干净的 W 单轴对照）**：
`ROB_SIZE=32, RS_SIZE=16, PRF_SIZE=64, LSQ_SIZE=16, BHT_SIZE=32, RAS_SIZE=8,`
`PF_DEPTH=16, PF_WIN=8, LD_INFLIGHT=8, SQ=8, RD=8, WR=8`。

##### 一、三档正确性门禁（官方口径 `make test`，`LATENCY=10`）

```sh
tools/run.sh <id> ISSUE_WIDTH=<W> --no-synth      # 变体树 (sed 改参数 + 回读校验)
cp config.local.mk runs/<id>/ && ln -sfn $PWD/testcases runs/<id>/testcases
make -C runs/<id> CONFIG=config.local.mk MAX_CYCLES=100000000 test   # 19 条 correctness
```

树 id：W=1 `runs/w1y`、W=2 `runs/w2y`、W=4 `runs/w4y`（三棵树都含本轮两处修复，
与工作树 `verilog/` 去 `student_top.v` 参数行后**逐字节一致**）。三套**并行**后台跑，
日志 `runs/<id>/test_fix.log`，末行均为 `Results: 19 passed, 0 failed`。

| 用例 | W=1 周期 | W=2 周期 | W=4 周期 | W=2/W=1 | W=4/W=1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `correctness_add_to_100` | 654 | 477 | 497 | 0.729 | 0.760 |
| `correctness_array_test1` | 777 | 768 | 816 | 0.988 | 1.050 |
| `correctness_array_test2` | 819 | 966 | 1006 | 1.179 | 1.228 |
| `correctness_basicopt1` | 495976 | 480979 | 462388 | 0.970 | 0.932 |
| `correctness_bulgarian` | 1033807 | 936784 | 967986 | 0.906 | 0.936 |
| `correctness_expr` | 984 | 1009 | 1067 | 1.025 | 1.084 |
| `correctness_gcd` | 675 | 687 | 731 | 1.018 | 1.083 |
| `correctness_hanoi` | 15584 | 19591 | 22529 | 1.257 | 1.446 |
| `correctness_lvalue2` | 291 | 332 | 367 | 1.141 | 1.261 |
| `correctness_magic` | 2016687 | 2487084 | 2666334 | 1.233 | 1.322 |
| `correctness_manyarguments` | 266 | 290 | 327 | 1.090 | 1.229 |
| `correctness_multiarray` | 6259 | 6430 | 6515 | 1.027 | 1.041 |
| `correctness_naive` | 269 | 332 | 349 | 1.234 | 1.297 |
| `correctness_pi` | 20873466 | 20870346 | 20863984 | 1.000 | 0.999 |
| `correctness_qsort` | 3597092 | 3972416 | 4268706 | 1.104 | 1.187 |
| `correctness_queens` | 1340676 | 1738900 | 1976608 | 1.297 | 1.474 |
| `correctness_statement_test` | 2635 | 3164 | 3274 | 1.201 | 1.243 |
| `correctness_superloop` | 1994608 | 2635246 | 2891318 | 1.321 | 1.449 |
| `correctness_tak` | 5751104 | 7248759 | 8145782 | 1.260 | 1.416 |

- **三档全绿**。W=4 并没有像 §15.10.19 时的陈旧树（`runs/w4f`）那样在 `basicopt1` 挂死 ——
  那是**缺陷 7 修复前**的指纹，本轮重建的树把它一并带上了。
- 红线检查：三棵树 `build.log` 均 **0 条 `UNOPTFLAT`**；`SELRANGE` 各 3 条，**全部**是
  [`execute_slot.v:252`](verilog/exec/execute_slot.v#L252) 的三目守卫 `(j < ISSUE_WIDTH) ? … : …`
  的 Verilator 误报（W=1 同样 3 条，与 W 无关，非 §15.10.18 缺陷 6 的 `mem_subsystem` 指纹）。
- `correctness_*` 上 W 越大越慢的趋势**进一步放大**（W=4/W=1 几何平均 **1.164×**，
  最差 `queens` 1.474×、`superloop` 1.449×、`hanoi` 1.446×；W=2/W=1 为 1.093×，最差
  `superloop` 1.321×）。与 §15.10.19 §三 同一现象，**同样没有迁移到评分口径**（见 §四）。

##### 二、缺陷 8：`free_list` 少回收恒等映射区 ⇒ 空机可用池随程序缩水（W=4，也命中 W=1）

**现场**（`correctness_hanoi`，W=4，官方口径）：ROB 已空、pc 冻结 ⇒ 全机死锁。冻结拍上：

| 量 | 值 | 含义 |
| --- | --- | --- |
| `u_fl.sp` | 3 | 池内只剩 3 项 |
| `map_arch` 落在池区 (>=32) 的个数 | 29 | 32 - 3 = 29，收支**自洽**（不是漏回收）|
| 冻结批的 `rd` | 4 条**全写** | `dut.rename_valid` 4 条全 1 |
| `cpu_top` 的闸 | `fl_count(3) < n_wr(4)` | **恒成立** ⇒ 永远发不出 |

**根因**：`free_list.push_ok` 写作 `push_valid[c] && (push_preg[...] >= BASE)`，
**整个恒等映射区 0..31 被排除在回收之外**。头注释给的理由是"池是 `head+i` 组合计算的环形，
表示不了 0..31"——但本实现早已改成**真实栈** `pool[]`（存真值，不靠组合计算，见文件头第 3 段），
任何 preg 都能表示 ⇒ 该排除纯属浪费。后果是一条**单调**的泄漏：架构 RAT 每把一个寄存器改写到
池 preg 上，就永久占住池里一项（只有该寄存器**被再次写**时才随下一个写者的 `old_pnum` 回池）。
空机可用池 = `32 - #{x : map_arch[x] >= 32}` ⇒ **程序写得越花，池越小**。

为什么以前没炸：死锁需要"某拍该发的批条数 > 池内可用数"，而批内**写指令**数 `n_wr <= W`。
W<=3 时 `n_wr <= 3`，而实测池最低还剩 3 ⇒ **恰好不触发**；W=4 时 `n_wr` 可达 4 > 3 ⇒ 触发。
这是**幸存者偏差不是正确性** —— W=1/W=2 通过从来不代表这条对。W=1 上它不致命（`n_wr <= 1`），
但仍然真实地压小池子 ⇒ 是 §五 里 W=1 全部性能变动的来源。

**修法**：只挡 preg 0（x0 的恒等映射，永不复用），其余 1..31 在架构映射放弃它时照常回池。
必须留 preg 0 这一挡：`cpu_top` 的 `fl_push_valid` 直接用 walker 的 `walked_valid`，
而 walker **不排除** `new_pnum == 0` 的条目（无目的寄存器）—— 放 preg 0 进池会被分配出去，
x0 就不再恒为 0。改后空机池恒为 `PRF_SIZE - 32 = 32 >= W`，结构性死锁消失。

```verilog
assign push_ok[c] = push_valid[c] && (push_preg[c * PW +: PW] != {PW{1'b0}});
```

**验证**：① `correctness_hanoi` W=4 由死锁转 PASS 22529；② W=1 上 `hanoi` 由 17093 降到
**15584**（−8.8%），是同一条泄漏在 W=1 上的同类代价；③ §五 的 W=1 perf 对照实验把这条
钉成 W=1 全部性能变动的唯一来源。

##### 三、缺陷 9：ROB 满窗截断的回绕歧义 ⇒ 满窗被截成"空窗"（W=4）

**现场**（`perf_vvadd`，W=4，官方 `make perf`）：提交冻结在 `commit=2401`，ROB 头不前进。
误预测汇出那一拍（`cyc=3296`）：

```
FLUSHSTART cyc=3296 robh=15 robl=15 occ=32 fs=14 wp=14 setlast=15 rsmask=0000 lsqmask=0000 lsqh=14 lsql=10
```

- `occ = 32` ⇒ **ROB 满**（`free_r = 0`）；`robh == robl == 15` ⇒ 满窗的两个指针相同；
- 误预测分支在 `fs = 14 = head - 1` ⇒ 它是**窗口内最年轻的条目**；
- `set_last_val = fs + 1 = 15 = head` ⇒ 截断后应**保留整窗 32 条**（没有比它更年轻的条目可杀）；
- 两条失效掩码 `rsmask = lsqmask = 0000` 是**对的**（按年龄差算，没有条目比 fs 更年轻）；
- `fs` 已提交那一支**不可能**：提交被 `!flushing_r && !misp_valid` 门控（[cpu_top.v:760]），
  head 在冲刷落地前**不可能**越过 `fs`。

**根因**：截断算保留条数用 `d_new_rw = set_last_val - head_r`（RW 位回绕）。`d_new_rw == 0`
在两种状态间**歧义**——"保留 0 条"与"保留整窗 `ROB_SIZE` 条"——因为**满窗与空窗的 (head,last)
指针完全相同**，只有 `free_r` 能区分。旧式恒取 0 ⇒ 满窗被截成"空窗"：31 条**正确路**条目
连同它们在 RS/LSQ 的有效性记录一起丢失（掩码按年龄差算，此时也恒不命中）⇒ LSQ 头再也不能前进
⇒ 占满后全机死锁。**修法**：用**截断前的占用量** `d_old` 消解歧义，且保留条数直接由 `d_new`
给出（不能再拿截断后的 head/last 相减 —— 满窗与空窗差都是 0）：

```verilog
wire [RCW - 1 : 0] d_new = (d_new_rw != {RW{1'b0}}) ? {1'b0, d_new_rw}
                         : (d_old == ROB_SIZE)      ? d_old        // 满窗 ⇒ 分支还活着 ⇒ 保留整窗
                         :                            {RCW{1'b0}};  // 否则它已提交 ⇒ 清空
wire [RCW - 1 : 0] free_after_last = ROB_SIZE - (keep_head ? d_new : {RCW{1'b0}});
```

（原 `wire [RW-1:0] d_f = last_after_last - head_after_last;` 随之成为孤儿，已删；
grep 确认全仓无其它读者。）

**验证**：`tb/core/tb_rob.v` 新增两条**只在这条修复下才过**的极端用例 ——
C10（满窗 + 截断点 == head ⇒ 整窗保留 `h/l/f = 2/2/0`，修复前得到 `2/2/32`）与
C10b（非满窗 + 截断点 == head ⇒ 清空 `2/2/32`，指针结果与 C10 **相同**、只有 free 不同 ——
这正是"只能靠占用量消解"的原因）。金标模型 `model_apply` 同步消歧。
`make -f Makefile.tb run TB=core/tb_rob`：修复前 C10 报 `FAIL … expect 2/2/0`，修复后
`ALL TESTS PASSED`（300 拍随机模型对照 + 段 1 全极端用例）。

##### 四、W 轴 IPC 口径（本轮实测，官方 `make perf`，`LATENCY=10`，`MAX_CYCLES=1e7`）

| 点 | `perf_median` | `perf_multiply` | `perf_qsort` | `perf_rsort` | `perf_towers` | `perf_vvadd` | **geomean** |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **W=1**（`runs/w1y`）| 0.2402 | 0.5506 | 0.2363 | 0.3481 | 0.2748 | 0.5128 | **0.3395** |
| **W=2**（`runs/w2y`）| 0.2913 | 0.6698 | 0.2580 | 0.2368 | 0.1877 | 0.5679 | **0.3291** |
| **W=4**（`runs/w4y`）| 0.2769 | 0.7849 | 0.3084 | 0.2133 | 0.1722 | 0.5748 | **0.3350** |
| W=2 / W=1 | 1.213 | 1.216 | 1.092 | **0.680** | **0.683** | 1.107 | **0.969** |
| W=4 / W=1 | 1.153 | 1.426 | 1.305 | **0.613** | **0.627** | 1.121 | **0.987** |
| W=4 / W=2 | 0.951 | 1.172 | 1.195 | 0.901 | 0.917 | 1.012 | 1.018 |

- **W 轴在评分口径上仍是平的**（0.3395 / 0.3291 / 0.3350，三点极差 3%）。W 从 1 加到 4，
  `multiply`（+42.6%）、`qsort`（+30.5%）、`median`（+15.3%）、`vvadd`（+12.1%）都涨，
  但 `rsort`、`towers` **反向掉**（−38.7% / −37.3%），把 geomean 拉平。
- **`perf_median` 非单调**（0.2402 → 0.2913 → 0.2769）：W=4 反而低于 W=2。
  `median` 是最短的用例（28985 / 23899 / 25143 拍），受启动瞬态权重最大，**未解释**。
- **`perf_towers` 的 W 轴回归本轮仍未解释**（W=1 0.2748 ⇒ W=2 0.1877 / W=4 0.1722，−32%）：
  §15.10.19 §四 提出的两个怀疑方向（分支密集下批内错路槽白吃取指供给、访存密集下 `PF_WIN`
  的取指/load 带宽切分）**本轮都没有验**。`perf_rsort` 的 W=2/W=4 值（0.2368 / 0.2133）
  与 W=1 对照时要小心：W=1 的 0.3481 里含缺陷 8 修复的增益（见 §五），
  **修复前**的 W=1 是 0.2531 —— 拿这个比，W=2 是 0.94×、W=4 是 0.84×，回归幅度小得多。
- **量级提醒（结论不变）**：三点 IPC 都在 **0.33 附近**（0.3395 / 0.3291 / 0.3350），
  距档 1 的 `0.6000` 分别差 **43.4% / 45.1% / 44.2%**。
  W 轴的 ±3% 在这个缺口面前是噪声 ⇒ **主攻方向仍是绝对 IPC，不是加宽发射**（§六.1）。

##### 五、对照实验：把 W=1 的性能变动钉到具体修复上

缺陷 8 改了 `push_ok`、缺陷 9 改了截断口径，两者都可能影响 W=1 ⇒ 不能只报"改完是 0.3395"。
用**单变量回退树**做对照（其余文件与工作树逐字节一致）：

| 树 | 相对工作树的差异 | 用途 |
| --- | --- | --- |
| `runs/w1z` | 只回退 `free_list.v`（缺陷 8 修复前），保留 `rob.v` 修复 | 分离缺陷 8 |
| `runs/w2z` | 只回退 `rob.v`（缺陷 9 修复前），保留 `free_list.v` 修复 | 分离缺陷 9 |

**W=1 对照（`runs/w1z`，官方 `make perf` 同一口径）**：

| 点 | `median` | `multiply` | `qsort` | `rsort` | `towers` | `vvadd` | **geomean** |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `runs/w1z`（回退缺陷 8）| 0.2402 | 0.5506 | 0.2361 | **0.2531** | 0.2748 | 0.5125 | **0.3219** |
| `runs/w1y`（两修复都在）| 0.2402 | 0.5506 | 0.2363 | **0.3481** | 0.2748 | 0.5128 | **0.3395** |
| §15.10.19 §四 基线（`runs/w1g`）| 0.2402 | 0.5506 | 0.2361 | 0.2531 | 0.2748 | 0.5125 | 0.3219 |

⇒ 两条结论都是**实测**而非推断：

1. **缺陷 9 的修复对 W=1 性能完全中性**：`runs/w1z` 带着修复后的 `rob.v`，6 条 IPC
   与 §15.10.19 的基线**逐位相同**（0.2402 / 0.5506 / 0.2361 / 0.2531 / 0.2748 / 0.5125）。
2. **W=1 的全部变动来自缺陷 8**：geomean 0.3219 → 0.3395（+5.5%），且**集中在 `perf_rsort`**
   （0.2531 → 0.3481，**+37.5%**）。机制与缺陷 8 的单调泄漏自洽（`rsort` 是 6 条里访存/寄存器
   压力最大的，跑得也最久 ⇒ 被压小的池子对它伤害最大）—— 但**"是 rsort 而非别的"这一点只有
   实测，没有逐程序计数佐证**，记为推定。

**W=2 对照（`runs/w2z`，官方 `make test`）** —— 该树与 `w2y` 只差 `rob.v` 一个文件：

| 用例 | `runs/w2z`（回退缺陷 9）| `runs/w2y`（修复）| 差 |
| --- | ---: | ---: | ---: |
| `correctness_add_to_100` | 477 | 477 | 0 |
| `correctness_array_test1` | 768 | 768 | 0 |
| `correctness_array_test2` | 966 | 966 | 0 |
| `correctness_basicopt1` | **563434** | **480979** | **−14.6%** |
| 其余 15 条 | **未跑** | — | — |

⇒ 前 4 条里**只有 `basicopt1` 命中缺陷 9**（−14.6%，W=2 上这条是长跑混合负载）。第 5 条
`bulgarian` 回退后 **6 分钟 CPU 未跑完**（修复后只要 936784 拍 ≈ 10 秒）—— 回退树的后续用例
耗时过长，**对照只跑到第 4 条就收手**，其余 15 条**未测、不推断**。

**W=1 正确性侧的同类确认（`runs/w1z` 定向复跑 §一 里变动的那几条）**：与修复前**逐位相同** ——
`hanoi` 17093、`magic` 2012044（修复后分别是 15584 / 2016687）。⇒ §一 里 W=1 相对
§15.10.19 §三 的 7 条变动，**成因是缺陷 8 而非缺陷 9**（缺陷 9 在 W=1 上性能中性已由本节的
perf 对照独立证实）。该定向复跑只跑了 2 条即提交（`pi` 跑到一半），**其余 5 条未测**。

##### 六、下一步

1. **IPC 缺口（0.33 → 0.60）仍是唯一的主攻方向**：`perf_towers`（−32%）、`perf_rsort`
   （W≥2 上是 6 条里最低）两条 W 轴回归都在**访存/分支密集**侧，与 §15.10.19 §五.1 的
   "单条 AXI 读口 + `PF_WIN` 带宽切分"判断同向 —— 优先查 cache 与取指带宽，而不是加宽 W。
2. W=4 的 IPC 三点已齐；**面积 / 频率档仍未跑**（需 OrbStack 容器 `cpu2026:local` 的
   ASAP7 r28 + FakeRAM），这是"IPC × 1.3 ↔ 面积上限 ×2"三档判定的另一半，必须补。
3. `perf_median` 的非单调（W=2 0.2913 > W=4 0.2769）未解释，用例太短（~2.5 万拍）时
   启动瞬态占比大是可疑方向，需要时用 `+TRACE` 数一下前 1000 拍的发射空洞。

#### 15.10.21 W=1 面积/频率基线补测（缺陷 8/9 修复后）—— 40.70 MHz / 11,482.960 µm²（2026-09-28）

> ⚠️ **本节记的是"删 `rs.v` 冗余合取项之前"的基线，已被 §15.10.22 取代**
> （那一处单点改动把 W=1 从 40.70 MHz 提到 **85.23 MHz / 11,402.843 µm²**）。
> 保留本节是因为 §15.10.22 的全部对照都以它为基准。**当前值看 §15.10.22。**

§15.10.20 §六.2 记的缺口：W 轴 IPC 三点已齐，但**面积/频率仍停在 `wb1`**，那是缺陷 8/9
修复**之前**的树。本节把 W=1 这一点接到当前 HEAD（**只补 W=1**，范围由用户圈定）。

**命令**（官方 `config.mk` 全默认、容器 ASAP7 **r28**；频率/面积一律以容器产物为准，
宿主的 r27 数字不混用）：

```sh
docker run --rm -v "$PWD":/work -w /work cpu2026:local \
  make synth MODE=opt FILELIST=docs/timing/filelist_t4tmp.f SYNTH_OUT=build/synth_w1cur
```

`docs/timing/filelist_t4tmp.f` 是**冻结口径**的源文件列表（已提交，`tools/run.sh` 也用它），
内容 = `filelist.f` **去掉 `core/memory.v` 一行**（`diff` 只报这一行）。**这不改变综合结果**，
实测依据：`student_top` 未例化 `memory.v`
（`verilog/top/student_top.v` 无该例化），综合后 `build/synth_w1cur/opt/stat.json` 里
**模块总数 = 1**（展平的 `student_top`）、无任何 `memory` 类模块 ⇒ 该文件被 `hierarchy -top`
剪掉，进不了网表。去掉只是省掉 Verilog 前端展开 64KB 阵列的数分钟。

##### 一、三点对照（同口径，均为容器产物）

| 运行 | RTL 档位 | 总面积 µm² | 组合 | 时序 | SRAM | 最小周期 ns | F_max | 最差裕量 ns |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pipe1` | 手法 3 | 11,354.962 | 7,329.308 | 4,025.655 | 0.000 | 11.7275 | 85.27 MHz | −9.7270 |
| `wb1` | 手法 4 | 11,385.595 | 7,316.725 | 4,068.870 | 0.000 | 25.0176 | 39.97 MHz | −23.0167 |
| **`w1cur`** | 手法 4 + 缺陷 8/9 修复 | **11,482.960** | 7,413.332 | 4,069.628 | 0.000 | **24.5703** | **40.70 MHz** | −22.5699 |

**`w1cur` 相对 `wb1`（缺陷 8/9 的修复代价）**：总面积 **+97.365 µm²（+0.86%）**、
组合 +96.607（+1.32%）、时序 +0.758（+0.02%）、最小周期 **−0.4473 ns（−1.79%）**。
⇒ **两条正确性修复在面积与频率上代价近似为零**（周期反而略快，快在净网表重因子分解，
不是修复本身的功劳）。`SRAM: 0.000` 属实（§15.10.12 已证全设计无推断存储器）。

##### 二、关键路径解剖：91 级里 2 级吃掉 59%

`tools/path.py build/synth_w1cur/opt --netlist …/mapped.v`：

```
级数 91  最长级延时 7.3481 ns
健康级 75 级 / 3.8738 ns (51.7 ps/级)   高扇出税 20.6283 ns (84%)
上限B 只修扇出(级数不变) = 4.7002 ns -> 213 MHz
上限A 假想(高扇出全免费) = 3.8738 ns -> 258 MHz
  300 MHz 预算 3.333 ns 允许总级数 <= 65 级 (现 91 级, 健康 75 级)
```

| 级 | 驱动 | 扇出 | 摆率 ns | 增量 ns | 累计 ns |
| ---: | --- | ---: | ---: | ---: | ---: |
| 87 | `_145115_/Y` `NOR2xp33` | **1149** | 15.8300 | **+7.3481** | 17.2731 |
| 88 | `_148189_/Y` `NAND2xp33` | 152 | 0.9776 | **+7.0742** | 24.3473 |
| — | 其余 89 级合计 | — | 末级 0.1853 | +10.0799 | 24.5022 |

**15.8300 ns 的摆率只由第 87 级产生，把第 88 级烧成 7.07 ns** —— 其余 89 级合计才 10.08 ns。
第 87 级的负载构成 `AO21x1.A1 × 1022` + `AO21x1.A2 × 68` + `AND3x1.B × 13` + …（共 1149），
与 §15.10.14 对 `wb1` 那条 fo=1022 网的归因**同构**：`AO21(A1,A2,B) = A1&A2 | B`，
`.A1` 是 2:1 mux 的选择端 ⇒ **ABC 把 `rs.v` 16 槽 × 68 位的写使能 CSE 成了单个共享字面量**
（§15.10.14 的 884 个目的触发器归因链：105 = pc 32 + imm 32 + rob 5 + ptaken 1 + ptarget 32
+ ras 3，105 + 39 = 144 = TOTW）。`w1cur` 的 `.A1` 计数 884 → 1022（+138），
但 `.A2` 恒 68 ⇒ **是同一结构在同一因子分解点上的放大**，不是新热点。

三点并排看，**这个设计的频率完全由"哪条写使能被 CSE 成共享字面量"决定**：

| 运行 | 级数 | healthy_ns | 高扇出税 | 最贵级 |
| --- | ---: | ---: | ---: | ---: |
| `pipe1` | 99 | 4.0173 ns (49.0 ps/级) | 7.6533 ns (**66%**) | 1.6188 ns |
| `wb1` | 76 | **3.2339 ns**（**首次 < 3.333 ns 预算**） | 21.7048 ns (**87%**) | 8.5571 ns |
| `w1cur` | 91 | 3.8738 ns | 20.6283 ns (84%) | 7.3481 ns |

`wb1` 证明**健康逻辑本身进得了 300 MHz 预算**（3.2339 < 3.333），`pipe1` 证明**级数多不是问题**
（99 级仍只有 11.67 ns）—— 卡住的只有高扇出税这一项。`w1cur` 的健康级从 63 涨到 75 级、
healthy_ns 3.2339 → 3.8738 ns（**回到预算之上**）。修复确实改动了 D 侧锥形（`free_list.v` 的
`push_ok` 与 `rob.v` 的截断判据都在 D 侧），**但"多出的 12 级健康级由这次改动造成"是推定**：
两次综合的起点/终点触发器 ID 不同（`_205605_`→`_202691_` vs `_205043_`→`_208329_`），
**没有逐网比对证明是同一条逻辑路径**。可确证的只有"总周期快了 0.4473 ns"与上面那两级的
增量延时对比（`wb1` 5.4020+8.5571 = 13.9591 vs `w1cur` 7.3481+7.0742 = 14.4223）——
即**最贵两级反而更贵了 0.46 ns，总长的改善来自路径其余部分**。

##### 三、与三档要求的距离（口径 = `docs/description.md`）

| 指标 | 当前（W=1） | 档 1 | 档 2 | 差距 |
| --- | ---: | ---: | ---: | --- |
| 面积 µm² | 11,482.960 | ≤ 9,000 | ≤ 18,000 | 档 1 需再降 **2,482.960（−21.62%）**；档 2 余量 36.21% |
| IPC（几何平均） | 0.3395 | ≥ 0.6000 | ≥ 0.8450 | 档 1 需 **×1.77**；档 2 需 **×2.49** |
| F_max | 40.70 MHz | ≥ 300（**硬性前提**） | — | 需 **×7.37**；400 MHz 加分需 ×9.83 |

三档是"面积上限与最低 IPC **同时**满足"：面积这一半已进档 2（11,483 < 18,000），
但 IPC 0.3395 离档 2 的 0.8450 差 2.49 倍，且**频率硬性前提未达**（40.70 ≪ 300）——
**当前分数为 0，且瓶颈是频率与 IPC，不是面积**。

##### 四、下一步（与 §15.10.14 结尾的判断一致，且本轮已把判据独立复核）

§15.10.14 已判死："**在上游拆掉这个共享使能之前，继续插流水是净负的**"。改动点是
`rs.v:237` 的 `if (push_valid[k2] && pvalid_w[k2])` —— 删掉 `&& pvalid_w[k2]`。
**本轮把"证行为保持"的两个前提逐条实测闭环**（不再是推演）：

1. `pvalid_w[gk] = (gk < 空槽总数)`：`rs.v:158-166` 的 `prec[ge]` 是 **`!valid_r` 的前缀和**
   （规范压缩计数），`rs.v:190` 的 `cand_p = !valid_r[ge] && (prec[ge] == gk)` ⇒
   第 gk 个空槽恰好归端口 gk ⇒ `pvalid_w[gk] = 1 ⟺ gk < rs_free_w`（`rs_free_w` 即 `!valid_r` 计数）。
2. `push_valid[k] ⇒ rs_free_w >= ISSUE_WIDTH`：`cpu_top.v:239` 把 rs 的 `push_valid` 接的是
   `rob_push_valid`，而 `cpu_top.v:502` `assign rob_push_valid[s] = issue_en && f2i_valid[s];`，
   `cpu_top.v:422` `issue_en` 含 `resources_ok`，`resources_ok` 含 `(rs_free_w >= ISSUE_WIDTH)`。

⇒ 合取项恒真。且 `pvalid_w` **只有 `rs.v:237` 一个使用点**（`:87` 声明 / `:197` 赋值），
删掉后整条 `pvc` OR 链（W × RS_SIZE = 64 根线、16 级深）成为死逻辑被优化掉。

**判据（§15.10.14 定死，不得用"某网扇出下降"当代理量）**：容器综合后
**`hot_ns` 显著下降且 `healthy_ns` 不退化**，总最小周期 < 24.5703 ns。
**风险**：若 ABC 只是把共享字面量挪到另一处因子分解点（`wb1` ↔ `w1cur` 之间已发生过一次
这种搬迁），则判据不达标 ⇒ 如实记为"未达标"，不得改判据凑结论。

#### 15.10.22 删 `rs.v` 的冗余写使能合取项 —— 单点改动拿回 **85.23 MHz（×2.09）**（2026-09-28）

**改了什么**（一处 RTL，`verilog/core/rs.v`）：删掉 push 写使能里的 `&& pvalid_w[k2]`，
并清掉随之成为死逻辑的 `pvc` 逐位 OR 链（`ISSUE_WIDTH × RS_SIZE` 根线）与 `pvalid_w` 声明。
`pvalid_w` 全文只有 `:237` 一个使用点。

> **两个扇出数别混**：`1088` 是 §15.10.14 记的**结构规模**（16 槽 × 68 位 = 该使能要驱动的
> RS 条目触发器位数）；`1149` 是本节 `w1cur` 的 `timing.rpt` 里那条网的**实测负载数**
> （1022 个 `AO21x1.A1` + 68 个 `.A2` + 59 个其他）。后者大是因为综合后每条触发器数据端
> 前面还挂了 mux 等单元。**本节所有结论以实测的 1149 为准**，RTL 注释里沿用的是 1088。

**为什么可删（证恒真，两个前提都已实测闭环）**：

1. `prec[ge]`（`rs.v:158-166`）是 `!valid_r` 的**前缀和**（规范压缩计数），`cand_p =
   !valid_r[ge] && (prec[ge] == gk)`（`:190`）⇒ 第 gk 个空槽恰好归端口 gk
   ⇒ `pvalid_w[gk] = 1 ⟺ gk < free_count`，而 `free_count` 就是 `!valid_r` 计数。
2. rs 的 `push_valid` 接的是 `rob_push_valid`（`cpu_top.v:239`），
   `rob_push_valid[s] = issue_en && f2i_valid[s]`（`cpu_top.v:502`），而
   `issue_en`（`:424`）含 `resources_ok`（`:422`）含 `(rs_free_w >= ISSUE_WIDTH)`。

⇒ `push_valid[k]=1 ⟹ pvalid_w[k]=1`。`pidx[k]` 在 `push_valid[k]=0` 时是无主索引，但那时本就不写。

**行为保持的实测证据**（不是只靠上面的证明）：W=1 与 W=4 各 8 条程序，
Icarus + `+FLCHK=1`（三条永久不变量：free_list 池内重复项 / 同一 preg 双持有 / RAT 单射性），
**逐位相同** —— `cycles`/`commit`/`flush`/`branch` 四个计数全等。W=1 用 `git stash` 做了
改动前/后的直接对照。
⇒ 这是**初筛**；随后用官方口径做了更强的验证（三档门禁 + 官方 perf，**57 个周期数与
6 个 IPC 逐位相同**），见本文 §三 / §四。

**实测结果**（`docs/timing/w1rs/`，容器 ASAP7 r28，冻结口径 `docs/timing/filelist_t4tmp.f`）：

| 指标 | `w1cur`（改前）| **`w1rs`（改后）** | 差 |
|---|---:|---:|---:|
| 最小周期 ns | 24.5703 | **11.7334** | **−12.8369（−52.2%）** |
| F_max | 40.70 MHz | **85.23 MHz** | **×2.09** |
| 总面积 µm² | 11,482.960 | **11,402.843** | −80.117（−0.70%） |
| 组合 / 时序 | 7,413.332 / 4,069.628 | 7,333.215 / **4,069.628** | 组合 −80.117，**时序一位不差** |
| 级数 / 健康级数 | 91 / 75 | 93 / 78 | +2 / +3 |
| healthy_ns | 3.8738 | **4.1149** | **+0.2411（+6.2%）** |
| hot_ns | 20.6283 | **7.5460** | **−13.0823（−63.4%）** |
| 最长级延时 | 7.3481 | **1.2558** | −6.0923 |
| 上限 A（热点全免费）| 258 MHz | **243 MHz** | −15 MHz |
| 前 5 热点网 | 1149@NOR2xp33 … | **192, 191, 186, 116, 98** | 共享字面量**消失** |

⇒ **那条扇出 1149 的共享写使能网被彻底拆掉了**（新热点最大只有 192），
时序面积一位不差（没增删触发器），组合面积还降了 80 µm²（死逻辑被清掉）。

##### 判据核对：**三条里两条达标，第三条未达标 —— 如实记录**

§15.10.14 定的判据是"`hot_ns` 显著下降**且** `healthy_ns` 不退化，总最小周期 < 24.5703 ns"：

| 判据 | 结果 |
|---|---|
| `hot_ns` 显著下降 | ✅ 20.6283 → 7.5460（−63.4%） |
| 总最小周期 < 24.5703 ns | ✅ 11.7334（−52.2%） |
| `healthy_ns` **不退化** | ❌ 3.8738 → **4.1149（+6.2%）** |

**不把第三条解释成"通过"**。一个可能的解释是**路径选择的变动**：hot 税塌下来之后，
原来那条路径已经不是最差的了（它的健康部分是 3.8738 ns），现在的最差路径是**另一条**
（91→93 级、起止触发器都不同、健康级数 75→78）。但**这是推定，没有证据闭环**
—— `timing.rpt` 只给 5 条路径且互为同源扇出，无法证明"旧路径仍在且更快"。
可确证的只有：最长级延时 7.3481 → 1.2558 ns（那条 7.35 ns 的级在**全路径上**都消失了）。

**不与 `pipe1` 混淆**：`w1rs` 的 85.23 MHz 与 `pipe1` 的 85.27 MHz 数值上几乎相同
（11.7334 vs 11.7275 ns，差 0.05%），**但两者不是同一棵树** —— `pipe1` 是**没有 W 级**的
（手法 3），`w1rs` **带着手法 4 的 W 级**。所以这次是"把手法 4 的败因拆掉后，
手法 4 不再拖后腿"，**不是"回到了手法 3"**。手法 4 宣称的收益（健康逻辑进 3.333 ns 预算）
在 `w1rs` 上**没有复现**（4.1149 > 3.333），这一点尚未解释。

##### 三、官方门禁 W=1/2/4 三档全绿 —— 且 **57 个周期数逐位相同**

`RTL` 改动落地后重建三棵变体树（`tools/run.sh` 改参数 + 回读校验），
三套并行后台跑官方 `make test`（`LATENCY=10`、`MAX_CYCLES=100000000`）：

```
w1r   Results: 19 passed, 0 failed
w2r   Results: 19 passed, 0 failed
w4r   Results: 19 passed, 0 failed
```

**比"PASS"更强的证据**：把三档各自的 19 条周期数与改动前（§15.10.20 表，
即 RTL 只差这一处合取项）逐条对照 —— **57 个数字全部逐位相同**：

```sh
# 提取 runs/<id>/test.log 的 (用例, 周期数)，与 §15.10.20 三列做 diff
diff <(sort 参照表) <(sort 实测)   # 三档全部为空输出
```

| 树 | 门禁 | 周期数 vs 改动前 | `UNOPTFLAT` | `SELRANGE` |
|---|---|---|---|---|
| `runs/w1r` | 19/19 PASS | **逐位相同 19/19** | 0 | 3 |
| `runs/w2r` | 19/19 PASS | **逐位相同 19/19** | 0 | 3 |
| `runs/w4r` | 19/19 PASS | **逐位相同 19/19** | 0 | 3 |

- `SELRANGE` 3 条是 [`execute_slot.v:252`](verilog/exec/execute_slot.v#L252) 三目守卫的
  Verilator 误报（三档同数、与 W 无关，非缺陷 6 的 `mem_subsystem` 指纹）。
- **意义**：这比"19/19 PASS"强得多。PASS 只说明**结果**对，逐位相同说明**连时序行为都没变**
  —— 即这次 ×2.09 的频率收益**不换正确性、也不换 IPC**，是纯赚的。

##### 四、官方 perf 口径 IPC：6 条 + geomean **逐位相同**

`make -C runs/w1r CONFIG=config.local.mk MAX_CYCLES=10000000 perf`：

| | `perf_median` | `perf_multiply` | `perf_qsort` | `perf_rsort` | `perf_towers` | `perf_vvadd` | **geomean** |
|---|---:|---:|---:|---:|---:|---:|---:|
| 改动前（§15.10.19 §四 W=1）| 0.2402 | 0.5506 | 0.2363 | 0.3481 | 0.2748 | 0.5128 | **0.3395** |
| **改后（`runs/w1r`）** | 0.2402 | 0.5506 | 0.2363 | 0.3481 | 0.2748 | 0.5128 | **0.3395** |

⇒ `docs/timing/results.csv` 的 `w1rs` 行 `ipc6` 字段**已按此实测填入**
（此前留空是纪律要求，不是遗漏）。

**综上**：这次改动的收益是 **×2.09 频率、−0.70% 面积、IPC 代价 0**。

##### 未决（本轮不处理，留档）

1. **`healthy_ns` 退化（3.8738 → 4.1149，+6.2%）** 没有解释。推定是路径选择变动，
   但 `timing.rpt` 证据不足以闭环（详见上文"判据核对"）。
2. **手法 4 宣称的收益未复现**：`w1rs` 带着 W 级却与无 W 级的 `pipe1` 打平
   （85.23 vs 85.27 MHz）⇒ 这次是"手法 4 不再拖后腿"，不是"手法 4 赚到了"。
3. 下一层（降负载数，**未启动**）：`RS_SIZE` 16→8 使能扇出减半、单轴 IPC 代价实测 4.9%
   （`perf_median` 单点）；以及 RS 条目载荷瘦身（96/144 位是 pc/imm/ptarget 这类
   ROB 里已有副本的每指令常量）。但**当前最大热点已只剩 192**，主要矛盾已转移到
   健康逻辑的 4.11 ns（离 300 MHz 的 3.333 ns 预算还差 23%）。

---

#### 15.10.23 参数前沿探索（9,000 µm² 档）—— `ROB=16` 是角点：**8,113.945 µm² / 95.27 MHz / IPC 0.3368**（2026-09-29）

**本轮目标（用户指示）**：在**面积 ≤ 9,000 µm²**（档 1 上限）的前提下，从最小参数集出发
**向上扩大**，提高 IPC 并尽可能少掉频率。口径全部为容器 ASAP7 r28 + `docs/timing/filelist_t4tmp.f`，
与 §15.10.21/§15.10.22 逐位可比。

##### 一、出发点与预算怎么定

结构性下限是 `PRF_SIZE = 64`（`FREE_NUM = PRF_SIZE − 32 ≥ 32`；`PRF_SIZE=40` 是永久死锁点）。
以 `minfeas`（全 min + `PRF=64`）为出发点：**5,542.412 µm² / 118.93 MHz / IPC 0.1737**。
预算 = 9,000 − 5,542.412 = **3,457.588 µm²**。

触发器单价由实测点反推（`stat.json` 的 DFF 计数配 `sequential_area`）：

| 对照 | ΔDFF | Δ面积 µm² | **µm²/flop** |
|---|---:|---:|---:|
| `minfeas` → `t1c` | 3,584 | 3,268.413 | 0.912 |
| `minfeas` → `t1d` | 2,580 | 2,571.533 | 0.997 |
| `minfeas` → `t1a` | 2,064 | 2,159.225 | 1.046 |
| `minfeas` → `w1rs` | 6,134 | 5,860.431 | 0.955 |

⇒ 合理区间 **0.91–1.05 µm²/flop**，取 ~0.95 折算 ⇒ 预算 ≈ **3,640 个触发器**。

##### 二、每参数的触发器定价

每条目触发器宽度由 RTL 寄存器声明逐个数出（未参数化的 pc/imm/ptarget 等 32 位字段按当前位宽计）：

| 参数 | `minfeas` | 满参数 | 缩小的 IPC 代价（**单轴**，基线是满参数） | 每条目 flops | 还原成本 flops |
|---|---:|---:|---:|---:|---:|
| `PF_DEPTH`/`PF_WIN` | 8/4 | 16/8 | **−36.7%** | 66 | **+528** |
| `LSQ_SIZE` | 4 | 16 | −13.5% | 84 | +1,008 |
| `RS_SIZE` | 4 | 16 | −4.9% | 143 | +1,716 |
| `RD_DEPTH` | 4 | 8 | −3.6% | ~40 | ~+80 |
| `ROB_SIZE` | 8 | 32 | ~−2% | 60 | +1,440 |
| `BHT_SIZE` | 8 | 32 | +0.5% | 2 | +48 |
| `RAS_SIZE` | 4 | 8 | 0% | 32 | +128 |
| `SQ_DEPTH` | 4 | 8 | 0% | 83 | +332 |
| `WR_DEPTH` | 4 | 8 | 0% | ~20 | ~+40 |
| `LD_INFLIGHT` | 2 | 8 | **未测**（该点修复前挂死） | 38 | +228 |

按"IPC 增益 / 100 flops"排序，`PF` 以 **0.110%/100flops** 遥遥领先（第二名 `RD` 是 0.046%），
`BHT`/`RAS`/`SQ`/`WR` 是 **0**。⇒ 预算几乎全该给 `PF`。

##### 三、四个候选点与实测

统一命令（`tools/run.sh <id> <参数…> --no-synth` 建树 + 容器综合 + 宿主 `make perf`）：

| id | `ROB` | `RS` | `LSQ` | `PF` D/W | `LD` | `RD` | `BHT` | `RAS` | `SQ` | `WR` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `t1a` | 8 | 4 | 16 | 16/8 | 8 | 8 | 8 | 4 | 4 | 4 |
| `t1b` | 8 | **16** | 16 | 16/8 | 8 | 8 | 8 | 4 | 4 | 4 |
| `t1c` | **32** | 4 | 16 | 16/8 | 8 | 8 | 8 | 4 | 4 | 4 |
| `t1d` | **16** | 4 | 16 | 16/8 | 8 | 8 | 8 | 4 | 4 | 4 |

（四者 `PRF_SIZE=64`、`ISSUE_WIDTH=1` 固定。）

| id | IPC | F_max MHz | 周期 ns | 面积 µm² | 组合 µm² | 时序 µm² | DFF | **IPC×F** | ≤9,000 | 门禁 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|:--:|:--|
| `minfeas` | 0.1737 | 118.93 | 8.4082 | 5,542.412 | 3,549.443 | 1,992.969 | 6,264 | 20.66 | ✅ | Icarus 快筛 |
| `t1a` | 0.3074 | 85.13 | 11.7461 | 7,701.637 | 5,102.256 | 2,599.381 | 8,328 | 26.17 | ✅ | 未跑 |
| `t1b` | 0.3071 | — | — | — | — | — | — | — | — | 未跑 |
| **`t1d`** | **0.3368** | **95.27** | **10.4961** | **8,113.945** | 5,320.534 | 2,793.411 | 8,844 | **32.09** | ✅ | **19/19 PASS** |
| `t1c` | 0.3396 | 70.75 | 14.1338 | 8,810.825 | 5,638.392 | 3,172.433 | 9,848 | 24.03 | ✅ | **19/19 PASS** |
| `w1rs`（满参数，对照） | 0.3395 | 85.23 | 11.7334 | 11,402.843 | — | 4,069.628 | 12,398 | 28.94 | ❌ | 19/19 PASS |

`t1b` 只测了 IPC：它相对 `t1a` 仅 IPC 差 **−0.0003**（0.3074 → 0.3071，逐条差异只在
`perf_median` 31774 vs 31654、`perf_qsort` 618519 vs 617903、`perf_rsort` 617567 vs 617610），
而 `RS` 4→16 要 ~1,680 flops（≈1,530 µm²）⇒ 在 9,000 档**先于频率被面积淘汰**，故未综合。

##### 四、三条与单轴外推**相反**的事实

1. **`RS_SIZE` 4→16 买到的 IPC 是 0**（`t1a` vs `t1b`）。单轴表里那个 −4.9% 是在"其余全满"
   的基线上测的；`ROB=8` 时 `RS=4` 根本不是瓶颈。**"满参数里有一大半面积买的是 0 IPC"**
   在本轮被直接证实：`t1c → w1rs` 差 `RS`/`BHT`/`RAS`/`SQ`/`WR` 五项，面积 **+2,592.018 µm²**，
   IPC **−0.0001**（0.3396 → 0.3395）。
2. **`ROB_SIZE` 8→32 买 +10.5%**（0.3074 → 0.3396），远高于单轴估的 ~2%；但它同时是
   本设计**最贵的频率动作**（11.7461 → 14.1338 ns，**−16.9%**），净吞吐反而 **−8.9%**。
3. **`t1c` 与 `w1rs` 的 IPC 打平（0.3396 vs 0.3395）而 `t1c` 慢 20.5%**。`t1c` 是 `w1rs` 的
   **缩减版**（只差 `RS`/`BHT`/`RAS`/`SQ`/`WR` 五项，全在 `t1c` 里取最小），把结构改小反而变慢 ——
   与本项目 `lsq-tree` / `rs-prefix` / `wb1` 三次负结果同源：**ABC 跨寄存器重新因子分解**。

##### 五、`ROB_SIZE` 的完整曲线与 `t1d` 角点

其余参数固定为 `t1a` 那一组，只动 `ROB_SIZE`：

| `ROB_SIZE` | IPC | F_max MHz | 面积 µm² | IPC×F | 关键路径健康 ns（ps/级） | 扇出税 | 上限A MHz | 最贵一级 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 (`t1a`) | 0.3074 | 85.13 | 7,701.637 | 26.17 | 4.0256 (53.7) | 66% | 248 | 1.1971 ns |
| **16 (`t1d`)** | **0.3368** | **95.27** | **8,113.945** | **32.09** | **3.6527 (43.0)** | 65% | **274** | 1.0782 ns |
| 32 (`t1c`) | 0.3396 | 70.75 | 8,810.825 | 24.03 | 4.2478 (54.5) | 70% | 235 | 2.0959 ns |

**IPC 强饱和**：8→16 买 **96%**，16→32 只再买 **3%**。而频率在 16 处取到最大值
（`t1d` 的 95.27 MHz 是**全项目 W=1 最高**，超过满参数 `w1rs` 的 85.23）。
⇒ **`t1d` 在 9,000 µm² 内同时是三轴最优，且严格支配当前设计点 `w1rs`**：

| | `t1d` / `w1rs` |
|---|---:|
| 面积 | **71.2%** |
| F_max | **111.8%** |
| IPC | 99.2% |
| IPC×F | **110.9%** |

`t1d` 的方向还应记一笔：**"主要矛盾已从扇出税转移到健康逻辑"只对满参数成立**。
`w1rs` 的税占 32%、健康 4.1149 ns；而 `t1a`/`t1c`/`t1d` 的税回到 **65–70%**，
健康 3.65–4.25 ns。9,000 档的配置**主要矛盾仍是扇出税**。

##### 六、扇出归因：随 `ROB_SIZE` 增长的只有两个信号

宿主 yosys 归因口径（`tools/preabc.py --tree runs/<id> --drop-memory` + `tools/census.py`，
**只用于命名，不作判分口径**）。`t1a`(ROB=8) vs `t1c`(ROB=32) 的 A/B：

| 信号 | `t1a` | `t1c` | 倍数 |
|---|---:|---:|---:|
| `prf rd[0].oh1` / `oh2` | 2048 | 2048 | 1.00 |
| `cpu_top cmt[0].lsq_oh` | 1056 | 1056 | 1.00 |
| `mem_subsystem idat[0].oh_g` | 1040 | 1040 | 1.00 |
| **`cpu_top cmt[0].cmt_oh`** | **448** | **1792** | **4.00** |
| `head_r` | 238 | 238 | 1.00 |
| **`push_valid`** | **131** | **299** | **2.28** |
| `execute_slot sel_oh[0..3]` | 141 | 143 | 1.01 |

`t1c` 的关键路径由一条 **272 负载**的网主导（`_051951_` = `AO21x1.A2 × 252` + …，单级
**2.0959 ns**），紧接着下一级再吃 1.3477 ns；而 `t1a` 同类网只有 `AO21x1.A2 × 67`
（扇出 194、1.1971 ns）。两者健康逻辑几乎相同（54.5 vs 53.7 ps/级）⇒ **`t1c` 的慢是
合成器因子分解 artifact，不是 ROB 的物理代价**（`w1rs` 同为 `ROB=32` 却是 85.23 MHz 即证）。

**但 `push_valid` 不是第二个 `pvalid_w`**：它是 `rob_push_valid = issue_en && f2i_valid`
（`cpu_top.v:502`），在 `rob.v:123` / `rs.v:229` / `lsq.v:189` / `free_list.v:49` 四处当写使能，
且要与 `ROB_SIZE` 宽的一热译码逐项相与 —— **是真实必要的全局广播，没有单点可删**。
要消掉只能改结构，而该方向已有 `rs-prefix` / `lsq-tree` / `wb1` 三次负结果，**本轮不投**。

##### 七、方法论结论：单轴消融因子**不可连乘**

用单轴因子外推 `t1a`（`minfeas` + `PF` + `LSQ` + `RD`）：

```
0.1737 × 1.58 (PF) × 1.156 (LSQ) × 1.037 (RD) = 0.3290
实测 t1a                                       = 0.3074   (−6.6%)
```

再叠加 `ROB` 的实测增益（×1.095）会偏得更多。原因是**每个单轴因子都是在"其余全满"的
基线上测的**，相互不可交换（`RS` 那项偏得最狠：单轴 −4.9%，实际 0）。
⇒ 参数消融表只能用来看**方向与量级**，任何组合设计都必须实测。

##### 八、对三档的意义（结论未变，只是数字更硬）

参数轴**已探到头**：IPC 天花板 **0.3396**（`t1c` 与 `w1rs` 两条独立路径撞同一值），
频率天花板 ~135 MHz（`minall2`），且**每一个提高 IPC 的参数动作都在吃频率**。
档 1 要 `(9,000 µm², IPC 0.6000)` + 硬前提 300 MHz ⇒ 最优参数配置 `t1d` 距 IPC 差
**1.78 倍**、距频率差 **3.15 倍**。**这个缺口不可能靠调参补上**，只能靠微架构改
（发射宽度、访存并行度、分支预测精度）。

##### 未决（本轮不处理，留档）

1. **`LD_INFLIGHT` 2→8 的独立 IPC 贡献未量化**。`t1a` 相对 `minfeas` 同时动了
   `PF`/`LD`/`LSQ`/`RD` 四项，×1.77 里 `LD` 的份额混在一起（该参数单轴从未测过，
   修复前挂死）。若要拆开需补一个 `LD=2` 的对照点。
2. **`t1c` 那条 272 负载网的 RTL 归属未定死**。A/B 只锁定到"随 `ROB_SIZE` 增长的
   只有 `cmt_oh`(4×) 与 `push_valid`(2.28×)"，但 pre-ABC 结构扇出与 post-ABC 的
   单网负载数不是 1:1（ABC 会 CSE/复制），**没有直接映射**。
3. **`ROB=16` 为何频率最高仍未解释**。它在健康 ns 上也是三者最优（3.6527 / 43.0 ps/级，
   上限 A 274 MHz 为全项目最高），目前只能记为"ABC 恰好在这一点抽得好"。

---

#### 15.10.24 I-cache 落地（三轴实测）+ D-cache 决策：**不做**，且给出了可证伪的上界（2026-09-29）

##### 一、I-cache 的实现与三轴实测

`verilog/core/icache.v`（直接映射、行粒度 `sram_fakeram`、tag 与数据同条目、`valid` 位图放 DFF），
接在 `mem_subsystem.v` 第 3 节，**删除**原取指预取窗口（`pf_tag_r`/`pf_data_r`/`pf_valid_r`/
`pf_pend_r`/`pf_next_r` = 1088 flop + 4 个 one-hot/AND-OR 读口，`idat[0].oh_g` 扇出恒定 1040）。
`fetch.v` / `lsq.v` / `cpu_top.v` **一行未改**（交付语义逐一对位）。

对照口径：`hd16` = `git archive 8998ca2` 的 RTL（旧预取窗口、无 icache）+ `RD_DEPTH 8→16`；
`ic1k` = 当前 RTL。**两行除 I 侧实现外参数逐位相同**（`RD_DEPTH=16` 是 icache 的硬要求
`≥ 2*IC_LINE_WORDS`，对照必须同步抬，其单价由 `t1d`→`hd16` 单独给出：**+2.7% IPC**）。

| 轴 | `hd16`（对照） | `ic1k`（I-cache） | Δ |
|---|---|---|---|
| 面积 µm² | 8400.865 | **8184.207** | **−216.658** |
| ├ SRAM | 0 | 386.984 | +386.984 |
| ├ 时序逻辑 | 2955.891 | 2639.767 | **−316.124** |
| └ 组合逻辑 | 5444.974 | 5157.456 | **−287.518** |
| Fmax | 83.46 MHz | 82.36 MHz | **−1.3%** |
| IPC(geomean) | 0.3459 | **0.4138** | **×1.196** |

逐条 IPC（`perf_median, multiply, qsort, rsort, towers, vvadd`）：

| | median | multiply | qsort | rsort | towers | vvadd |
|---|---|---|---|---|---|---|
| `hd16` | 0.2437 | 0.5494 | 0.2425 | 0.3626 | 0.2955 | 0.4923 |
| `ic1k` | 0.3427 | **0.6561** | 0.2801 | 0.3909 | 0.3994 | 0.5110 |
| 比 | +40.6% | +19.4% | +15.5% | +7.8% | +35.1% | +3.8% |

**三条轴两正一负，六条测试 IPC 无一下降**，`perf_multiply` 0.6561 **已越过档 1 的 0.6000 单点线**。

**收益归因：为什么只有 +19.6%？** 命中路径**没有变慢** —— `sram_fakeram` 同步读，命中即 1 拍交付，
与被它替换的旧预取窗口在顺序流上**同拍数**（契约本身就规定"下一拍交付"）。贵的是**缺失**：
AXI4-Lite 无 burst，填一行 8 字要背靠背发 8 笔单字 AR ⇒ 理论 `LATENCY + IC_LINE_WORDS` = 18 拍
（TB 判据上限 26），且 v1 是单 MSHR、填充期间取指**全停**。但收益小的主因不是这个，而是**收益的分布**：

| 用例 | 增益 | 码流形态 |
|---|---|---|
| median | **+40.6%** | 循环密集 |
| towers | **+35.1%** | 循环密集 |
| multiply | +19.4% | — |
| qsort | +15.5% | — |
| rsort | +7.8% | 顺序流 |
| vvadd | **+3.8%** | 顺序流 |

旧预取窗口只有 **16 字 = 64 字节**：顺序流本来就在窗口里跑（vvadd/rsort 几乎没有收益），
只有**循环体超过 64 字节**的程序（median/towers）才会让老窗口反复颠簸。
⇒ **I-cache 的真实收益来自「容量」，不是「延迟」** —— 这也解释了为什么几何平均被摊薄到 +19.6%，
并**反过来印证**了 §15.10.24 二 的 D-cache 判断：降延迟这条路上没有多少油水。

面积是**净减**：删窗口省下 603.6 µm²（DFF + 组合），SRAM 花掉 387.0。
> 原计划估的是"净减 900–1300 µm²"，**实测只有 216.7** —— 低估了缓存外围（tag 比较、
> `imem_hit` 的 32 位 decode、读写口仲裁）的代价。**本仓库第三次"估算与实际差数倍"**，
> 记在 `docs/timing/results.csv` 的 `ic1k`/`hd16` 两行里。**频率 −1.3% 正是原计划风险 1 预警的方向**
> （`hot_ns` 7.6680→8.0975，最热网 `224@XNOR2xp5`→`279@XNOR2xp5`），但 `healthy_ns` 反而变好
> （4.2414→3.9733）⇒ 是 ABC 因子分解的变化，不是健康逻辑退化。

**官方门禁**（`make test`，`MAX_CYCLES=1e8`）：**W=1 / W=2 / W=4 三档各 19/19 PASS、0 FAIL**
（W=1 见 §15.10.23；W=2/W=4 本轮补测）。`fetch.v` 一行未改而契约逐位对位 ⇒ I-cache 的交付语义在
三种发射宽度下均成立，含 W≥2 才可达的**跨行批装配**路径（`icache.v` 头注释【跨行批】一节；
硬要求 `IC_LINE_WORDS ≥ ISSUE_WIDTH` 在本轮配置 8 ≥ 4 下满足）。
> 口径提醒：**本轮起"周期数逐位不变"不再是行为保持判据** —— 缓存本来就改时序（如
> `correctness_pi` 在 W=2 下要 2,087 万拍）。判据是**结果正确**。

##### 二、D-cache 决策：**不做**（上界实验，非代理推理）

> 用户裁定：**先收口 I-cache + 跑 perf，再据数据定 D**；若做则取"读侧只读 + store 命中即整行失效"。
> 结论是**不做**，依据如下。

**先证伪了一个弱代理**：原打算用 `LD_INFLIGHT` 8→16 作"访存是否为瓶颈"的探针。
实测 **8 / 16 / 32 三档 geomean 全是 0.4138、逐位相同**（仅 `perf_qsort` 差 19 拍 / 499459，
证明参数确实接线生效）。补测 2 / 4 后得到完整曲线：

| `LD_INFLIGHT` | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|
| IPC(geomean) | 0.3648 | **0.4137** | 0.4138 | 0.4138 | 0.4138 |

**在 4 就饱和**（2→4 值 **+13.4%**，4→8 只值 +0.02%）。
根因：`ROB_SIZE=16`、`RS_SIZE=4` 把在飞指令数压到 16 条以内，其中 load 占比 ~1/4
⇒ **在飞 load 恒 ~4 条**，`LD_INFLIGHT=8` 已是 2× 过配。所以"再翻倍没用"证明的是**窗口限制**，
不是"访存延迟不暴露" —— **这个探针对 D-cache 的决策无效**，必须换判据（见下）。
> 副产品：它顺带**结清了 §15.10.23 的未决 #1**（"`LD_INFLIGHT` 2→8 的独立 IPC 贡献未量化，
> 若要拆开需补一个 `LD=2` 的对照点"）：**贡献 = +13.4%，全部由 `LD=4` 捕获，该轴在 4 之后是平台**。
> ⇒ "访存并行度"这个杠杆在本设计里**已经用尽**。

**改用严格得多的上界实验**：官方框架的 `LATENCY` 是参数。把从机延迟降到 **2 拍**即"完美存储
系统"——每次访问都 2 拍，**且 I 侧填充也从 18 拍降到 10 拍**。

| IPC(geomean) | @ `LATENCY=10` | @ `LATENCY=2` | 降延迟收益 |
|---|---|---|---|
| `hd16`（无缓存） | 0.3459 | 0.5038 | ×1.457 |
| `ic1k`（I-cache） | 0.4138 | **0.5650** | ×1.365 |

**决定性判据**：`0.4138 × 1.365 = 0.5650 < 0.6000`（档 1 的 IPC 门槛）。

⇒ **即便把存储子系统做到比任何真实 cache 都快，也到不了档 1。**

且 `LATENCY=2` 对真实 D-cache 是**偏乐观**的：

- D 侧：`LATENCY=2` 恒定 2 拍；真实 cache 命中 ~2 拍、**缺失 `LATENCY + LW = 18` 拍**。
  要在 D 侧打平需命中率 `h` 满足 `18 − 17h < 2 ⇒ h > 94.1%`（假设命中仅 1 拍、即比 `LATENCY=2` 还快 1 拍）；
- I 侧：真实 cache 的填充仍是 18 拍，而 `LATENCY=2` 把它降到 10 拍 —— 这一项**纯亏**。

按 90% 命中率估：D 侧平均 = `0.9×1 + 0.1×18 = 2.7` 拍（劣于 2.0），I 侧再劣 ⇒ 实际 IPC 约 **0.52–0.55**，
**低于 0.5650，更低于 0.6000**。而 `DC_SIZE=1024` 还要吃掉约 320 µm² 净面积（余量 815.8）。
**三条门里 G1 成立、G3 勉强、G2（真正的那条）不成立 ⇒ 不实现。**

**方向性结论：整个"存储/cache"方向已经封顶**（上界 0.5650）。剩余的档 1 缺口只能在**核内**
（发射宽度、分支预测、RS/ROB 窗口）。特别注意 §15.10.23 那条"RS/LSQ/BHT/RAS/SQ/WR 五项 IPC 增益
−0.0001"是**在没有 I-cache 时测的**——当时机器受取指饥饿支配，这些轴被掩盖了。
**I-cache 把取指瓶颈拆掉之后，这批参数轴必须重测**，这是下一步最便宜的动作（IPC 不需重新综合）。

##### 三、debug 记录（三条，都可复现）

1. **`tb_mem_axi` 的 T1 阈值是假警报，不是 RTL 缺陷**。`IC_LINE_WORDS=16` 时 4 条失败，
   一度怀疑填充逻辑；插桩后发现填充**完全正确**（`valid_r[12]` 被正确置位），只是耗时 63 拍
   超了硬编码的 60。根因：**冷启动代价 = `LATENCY + IC_LINE_WORDS`，随行字数线性增长**
   （AXI4-Lite 无 burst，填一行要背靠背连发 LW 笔单字 AR，LW=8 → 54 拍，LW=16 → 63 拍）。
   修法：判据参数化（`FETCH_MAX = 3*LATENCY + 3*LW + 8`），并把 T1 **拆成两段**——
   "冷启动 ≤ 一次行填充"与"**预热重访 ~1 拍/字**"，后者与 `LW` 无关，**才是"缓存真的在工作"的判据**。
   独立 oracle `tb_icache.v` 在 LW=16 下全绿，交叉验证了 RTL 无罪。
2. **`RD_DEPTH ≥ 2*IC_LINE_WORDS` 且必须是 2 的幂**（已写进 `mem_subsystem.v` 参数注释）。
   `axi_lite_master` 的读 FIFO **实际容量是 `RD_DEPTH−1`**（`rd_full_w` 留一格区分空满），
   容量不足时整行填充从 `LATENCY+LW` 劣化到约 `2*LATENCY+LW`（实测 T1 由 54 拍劣化到 70 拍）。
3. **造对照树不能只换 filelist**。`tools/run.sh` 拷的是**当前** `verilog/`，若只把 filelist 换成
   冻结口径而该口径缺 `icache.v`，`synth.py` 直接报
   `RAM library error … unsupported external module icache`（它**只认 `sram_fakeram`**）。
   对照树必须从 `git archive 8998ca2` 整体回到无缓存状态再补参数补丁。

##### 四、下一步

1. **重测核内参数轴**（I-cache 之后）：`RS_SIZE` / `BHT_SIZE` / `ROB_SIZE` / `PRF_SIZE` 等，
   **只需 IPC，不需重新综合**（秒级），这是当前性价比最高的动作。
   **已有先导证据**（本轮 W 门禁顺带取得；`ISSUE_WIDTH` 1→2 是**唯一变量**，其余参数与 `ic1k` 逐位相同）：
   `perf_multiply` 0.6561 → **0.8103**（+23.5%）、`perf_qsort` 0.2801 → **0.3435**（+22.6%）。
   ⚠ 口径：**两条单用例抽查**，不是 6 条几何平均，**不能**直接与 `ic1k` 的 0.4138 相减；
   但两条都超过 I-cache 的几何平均增益 +19.6% ⇒ **发射宽度是比缓存更值钱的杠杆**，应优先扫。
   另注 `correctness_pi` 在 W=2 下 IPC 仅 **0.149**（312 万条 / 2087 万拍），是典型的分支/依赖受限，
   与"停顿主要在核内"的判断一致。
2. **`IC_*` 的消融矩阵**（`IC_SIZE × IC_LINE_WORDS × IC_PREFETCH × IC_BYPASS`）——
   `docs/description.md:142` 要求的"Cache 配置敏感性分析"报告素材，**不是决策前提**，
   可与上面的参数轴并行。
3. **频率仍是硬前提**（82.36 MHz vs 300 MHz，差 3.6×）。`§15.10.11` 已证伪"删高扇出网 ⇒ 提频"，
   下一步必须从**流水级划分**入手，不能继续在组合逻辑上做局部手术。
4. **D-cache 留档不做**。若将来核内改进把 IPC 推到 0.55+ 之后再回来评估，届时应先重跑
   `LATENCY=2` 上界（本节的判据可原样复用）。

#### 15.10.25 频率缺口归因：300 MHz 硬前提 vs 82.36 MHz —— 病根是 100 级深度，不是扇出（2026-09-29）

`docs/description.md:163-167` 把 **300 MHz 列为三档（90/95/100 分）的共同前提**，400/500 MHz 另有 +2/+4。
而 `ic1k` 实测 **82.36 MHz**（最小周期 12.1416 ns）⇒ **差 3.64×**。
**在它解决之前，IPC 与面积上的任何投入都不产生阶段分** —— 这是本轮之后项目的头号风险。

**关键路径逐级分解**（`docs/timing/ic1k/path.json`，端点 `_141944_/QN → _142968_/D`）：

| | 级数 | 耗时 | 说明 |
|---|---|---|---|
| 合计 | **100** | **12.071 ns** | ⇒ 82.36 MHz |
| 扇出税 | 6 | **4.931 ns** | 见下表 |
| 其余 | 94 | 7.140 ns | |
| ├ 其中"健康"级 | 85 | **3.973 ns** | 46.7 ps/级 ⇒ 天花板 **252 MHz** |

六条扇出网（按单级 delay 降序）：

| 网 | cell | 扇出 | 负载电容 fF | 单级 ns |
|---|---|---|---|---|
| `_116755_` | NAND2xp33 | 130 | 63714.5 | 1.2470 |
| `_116750_` | XNOR2xp5 | **279** | 120793.5 | 0.9504 |
| `_084404_` | OAI21xp33 | 106 | 48816.2 | 0.8093 |
| `_084406_` | NAND2xp33 | 66 | 31509.5 | 0.7130 |
| `_075064_` | AOI33xp33 | 107 | 52037.9 | 0.6235 |
| `_084363_` | AOI21xp33 | 106 | 48725.0 | 0.5873 |

**决定性的一点**：把扇出税**全部归零**，健康逻辑本身也只有 **3.973 ns = 252 MHz**，**仍低于 300**。
而 `§15.10.11` 已证伪过"删高扇出网 ⇒ 提频" —— 这些网是 ABC 把共享子表达式提出来的**症状**，不是病根。

**病根是逻辑深度**：46.7 ps/级 × **71 级** = 3.333 ns（300 MHz），现在是 **85 级**（剔扇出网后）。
⇒ **必须在关键路径中间插入流水寄存器**，局部手术已经到头（与 §15.10.24 四.3 一致，本节给出位置与预算）。

**下一步动作**：先做**路径 → RTL 模块归因**（`path.json` 的 100 级 cell/net 都在，
可逐级映射回 `verilog/` 的模块与信号），确认这一刀切在哪一级，**再**实施。
`§15.10.11` 的教训是一律以容器实测为准，不得凭"这一级看起来慢"就动手。

> ⚠ **未决**：`ceiling_mhz = 252` 是**当前因子分解下**的健康逻辑上限，**不是物理上限**
> —— 重新划分流水级后 ABC 会重做优化，级数与 ps/级都会变。故 252 只能当"够不够"的判据，
> **不能**当"切完能到多少"的预测（本仓库已三次记录"估算与实际差数倍"）。


#### 15.10.26 切 LSQ 发请求回环 —— **实测反而更慢**（ROB=16: 82.36 → 76.65 MHz），已回滚（2026-09-29）

§15.10.25 把病根定在"必须插流水寄存器"，并指定先做**路径 → 模块归因**再动手。本节是那次动手的完整记录，
**结论是负面的**：改动让**每一个轴都变差**，已回滚（`verilog/core/lsq.v` / `tb/core/tb_lsq.v` /
`docs/architecture.md` 三处 `git checkout` 还原；工具链改动保留）。

**① 归因（新工具 `tools/pathsrc.py`，手法见 `tools/README.md`）**

`design.json` 与 `mapped.v` 是同一张 ABC 后网表的两种序列化，名字零重叠（`$abc$…` vs `_NNNNN_`），
故只能**按位置 join**（第 k 个实例 ↔ 第 k 个 cell），再借 Yosys 保留的 `src` 反查 RTL 行号。
对 `ic1k` 复现 73480/73480 类型全同：

| | cell | `src` | 网表内佐证（同 src 连续段） |
|---|---|---|---|
| 起点 | `_141944_` | `core/mem_subsystem.v:171.5-179.8` | **恰好 8 个** `DFFASRHQNx1` = `ld_wr_p`(4b)+`ld_rd_p`(4b)，异步复位风格吻合 |
| 终点 | `_142968_` | `core/axi_lite_master.v:121.5-131.8` | **1040 个** `DFFHQNx1` = `rd_addr_r`/`rd_tag_r`/`rd_data_r`/`rd_bresp_r`（无复位 ⇒ `DFFHQNx1`） |

5 条最慢路径共享同一起点 ⇒ 该指针的扇出锥支配全设计。整条路是一次**跨模块组合回环**：
`ld_wr_p/ld_rd_p → ld_inflight_w → ld_busy → (cpu_top 端口) → lsq 的 ~30 级 store_ok 距离链 +
first_one_f 优先链 + addr 16 选 1 → ld_accept → rd_req_valid → axi_lite_master 的 rd_addr_r 写使能`。

**② 手术**：只在 `verilog/core/lsq.v` 加 `req_v_r`/`req_idx_r`（异步复位）把"要发的那一条"寄存一拍，
`ld_start_valid = req_v_r && !kill[req_idx_r] && !ld_busy`；被接收那拍**同拍预装下一条**（掩码按"距 head 的距离"
而非绝对下标）；条目在请求登记后被 kill 时**同拍撤销并换装**（否则槽位复用后完成脉冲错位 ⇒ 静默错数）。
单测 `tb_lsq` 新增 L17~L20 与随机段偏置，全部通过；`make test` 在两个配置下均 **19/19**。

**③ 实测（ASAP7 r28 容器，`MODE=opt`）—— 六个数全负**

| run | 配置 | lsq.v | 面积 µm² | 最小周期 ns | fmax MHz | 级数 | healthy_ns | hot_ns |
|---|---|---|---|---|---|---|---|---|
| `ic1k` | ROB=16 | 旧 | 8,184.207 | 12.1416 | 82.36 | 100 | 3.9733 | 8.0975 |
| `base16syn` | ROB=16 | 旧 | 8,184.207 | 12.1416 | 82.36 | 100 | 3.9733 | 8.0975 |
| `req16` | ROB=16 | **新** | 8,202.388 | **13.0459** | **76.65** | 98 | **4.1931** | **8.7934** |
| `w1rs` | ROB=32 | 旧 | 11,402.843 | 11.7334 | 85.23 | 93 | 4.1149 | 7.5460 |
| `lsqreq` | ROB=32 | **新** | 11,545.714 | **11.8975** | **84.05** | 90 | 4.0322 | 7.7900 |

`req16` 与 `ic1k` 的两树差异经 `diff -rq` 核准**只有 `lsq.v`**（`student_top.v` 参数逐字相同）。
时序面积 +1.896 µm² ≈ 新增的 5 个触发器，**面积账干净**。

`base16syn` 是为排除最后一根死线而补跑的基线臂（旧 `lsq.v` + 本次的 `fill_busy` 修复 + ROB=16）：
它与 `ic1k` **逐位相同** —— 周期 12.1416015625、面积三项 5,157.456 / 2,639.767 / 386.984、
关键路径 cell 名 `_141944_→_142968_` 全部一致 ⇒ **那根无人读的 `unused_fill_busy_w` 在 `MODE=opt` 下
合成中性**，`base16syn → req16` 是严格的单变量对照，+7.4% 全部归给 `lsq.v`。
（`lsqreq` 那行**没有**同配置同 RTL 的综合基线：最接近的 `w1rs` 不含 I-cache，二者之差混了 I-cache 效应，
只能看"路径换到了哪里"，不能量化代价。）

IPC（宿主 Verilator，同机同 testcases 配对实测；`base16`/`base32` 两棵树只把 `lsq.v` 换回 HEAD 版本）：

| 配置 | 旧 lsq.v | 新 lsq.v | Δ |
|---|---|---|---|
| ROB=16 | 0.4143 | **0.4014** | **−3.1%** |
| ROB=32 | 0.4138 | **0.4005** | **−3.2%** |

ROB=16 逐条：median 0.3797→0.3686、multiply 0.6537→0.6511、qsort 0.3071→0.2967、
rsort 0.3830→0.3679、towers 0.3512→0.3379、vvadd 0.4932→0.4727 —— **六条无一例外全降**。
代价的来源是清楚的：请求寄存一拍后，候选池"只剩一条"时该条要多花一拍才能呈递
（预装只能装"被接收那拍**已经可见**"的下一条）；唯一能消掉它的办法是组合旁路，而那正好把刚切掉的环接回去。

**④ 为什么失败：路径换了身份，没有变短**

| | 起点 | 终点 | 级数 | healthy_ns |
|---|---|---|---|---|
| `ic1k`（旧） | `mem_subsystem.v:171.5-179.8` | `axi_lite_master.v:121.5-131.8` | 100 | 3.9733 |
| `req16`（新） | **同一个** 8 个指针触发器 | `exec/div.v:82.5-121.8`（除法器状态寄存器） | 98 | **4.1931** |
| `lsqreq`（新, ROB=32） | **同一个** | `core/rs.v:203.5-258.8` | 90 | 4.0322 |

回环**确实被切断了**（终点离开了 AXI FIFO），但同一批指针触发器还喂着**另一条同样长的链**：
`ld_rd_p → ld_idx_r 的 8 选 1（完成条目号）→ ld_done_idx → CDB 唤醒 → RS 的唤醒/选择锥 →
发射到执行单元 → 除法器状态寄存器的 D`。ABC 跨新寄存器边界重新因式分解后，这条链比原来那条**还慢**
——正是 §15.10.25 末尾那条警告（"252 只能当够不够的判据，不能当'切完能到多少'的预测"）和
本仓库三次"行为等价的结构改动反而变慢 1.2–2.8×"先例的又一次应验。

**⑤ 结论与对下一步的含义**

- 靠**挪动寄存器边界**来提频这条路，在"逻辑总量不变"的前提下是**零和**的：深度只是从一段搬到另一段。
  §15.10.25 的 `healthy_ns = 3.97 ns`（85 级 × 46.7 ps）才是真天花板 —— 300 MHz 要 3.333 ns，
  **哪怕不算扇出税也已经超了**。要真正提频只能**减少总逻辑深度**（少一级功能、少一次比较、缩小位宽），
  或者接受"多拍完成"（把长链本身拆成流水，而不是换个地方切）。
- 本节顺带确认的两条方法论事实，**后续所有实验都受它们约束**：
  1. **`tools/run.sh <id>` 不带参数时用的是 `student_top.v` 的提交默认值（ROB=32/RS=16/BHT=32/SQ=8/WR=8）**，
     与 `ic1k`/`t1d`/`hd16` 等归档行（ROB=16，由 `run.sh` 参数补丁生成）**不是同一台机器**。
     本节的第一次综合（`lsqreq`）就踩了这个坑，作废重跑才有 `req16`。
  2. `results.csv` 的 `ipc6` 列与 `params` 列**可能不对应**：`ic1k` 行的 `ipc6`（0.4138）经复现是
     **ROB=32** 配置的数字（`base32` 树逐位复现 `0.3427,0.6561,0.2801,0.3909,0.3994,0.5110`），
     而同一行的面积/频率是 ROB=16 的。~~该行未改动，等确认口径后再定。~~
     **（2026-09-30 结案，见 §15.11）**：已改正为 ROB=16 实测
     `0.3797,0.6537,0.3071,0.3830,0.3512,0.4932`（geo **0.4143**）；`constr1` 行同因同改；
     全表 27 行逐列复核，**这是唯一一处**参数/`ipc6` 不同源的行。
- 另修一个**真实缺陷**（保留）：`mem_subsystem.v` 里 icache 的 `.fill_busy()` 空连接会让
  `MODE=diagnose`（`-hieropt`，pass 10.8.7 OPT_HIER）直接报错退出 —— 该 pass 重写参数化模块端口表时
  处理不了空连接项。改成接一根真实导线（`unused_fill_busy_w`）后 diagnose 可跑通，`MODE=opt` 不受影响。

#### 15.10.27 为什么 §15.10.26 那一刀必然零和：**一个锥吃掉 63% 的组合逻辑**（2026-09-29）

§15.10.26 的结论"挪寄存器边界是零和的"当时只有一条证据（切完路径换了终点）。本节用两个新工具
把**为什么零和**量化出来：`tools/census.tcl`（路径普查）与 `tools/cone.py`（锥规模 + 逐级归因）。
两者都只读已有产物，**不新增任何综合**。

**① 官方产物有一个结构性上限，必须先知道**

`scripts/timing.tcl` 的 `report_checks` **写死 `-group_path_count 5`**。该文件属官方框架、勿改，
所以归档的 `timing.rpt` **永远只有 5 条路径**，`ic1k` 那 5 条还恰好同属一个 32 位寄存器的相邻位
—— 只看它必然得出"瓶颈是一条链，切一刀就好"。这是 §15.10.26 动手前**没能察觉**的信息缺口。

`tools/census.tcl` 用**与官方逐条相同的约束**（5 个 liberty + fakeram lib、`create_clock 3.333`、
transition/uncertainty 0.05、input/output delay 0.2/0.0、`set_load 5.0`、`set_case_analysis 0 reset`），
只把路径数放大到 4000（周期固定 3.333 ns；路径延时与周期无关，`delay = 3.333 − slack`，
与官方在 2.0 ns 下报的差一个 0.0726 ns 的常数 = uncertainty + setup，两边都有）。

**② 普查结果：4000 条路径只有 1 个起点**

| run | 路径数 | 起点 | 延时范围 ns | 中位 ns | >3.333 ns |
|---|---|---|---|---|---|
| `ic1k`（ROB=16，旧 `lsq.v`） | 4000 | **全部** `_141944_/QN` | 12.1413 → 9.1638 | 10.4714 | **4000/4000** |
| `req16`（ROB=16，§15.10.26 那一刀） | 4000 | **全部** `_141838_/QN` | 13.0451 → 10.3839 | 11.2971 | **4000/4000** |

两个 run 的起点是**同一个 `src`**（`mem_subsystem.v:171.5-179.8`，`ld_wr_p`/`ld_rd_p` 指针），
4000 个终点互不相同，而且**最慢的 4000 条全部超过 300 MHz 的 3.333 ns**。
⇒ 不是"某几条路径慢"，是**这一个 8 位指针触发器喂出去的东西整体都慢**。

**③ 锥规模：40850 个组合 cell ≈ 63% 的组合逻辑**

`tools/cone.py --cone _141944_`（从该 cell 的输出网做正向组合 BFS，到触发器为止）：

| | |
|---|---|
| 正向组合锥 | **40,850 个组合 cell** = 全设计组合 cell 的 **62.7%**（40850 / (73480 − 8315)）|
| 到达触发器 | **6,185** 个（全设计 8,315） |
| 按模块 | rob 980 / mem_subsystem 593 / rs 572 / axi_lite_master 532 / lsq 312 / execute_slot 239 / div 201 / rat 186 / fetch 164 / ready_table 63 / cpu_top 10 / free_list 7 / icache 4 / ras 2 / **无 src 2320** |

**独立交叉验证**：OpenSTA 的终点普查（同一批 4000 条路径）给出 rob 989 / mem 589 / rs 572 /
axi 532 / lsq 312 / rat 186 / fetch 164 —— 与上面这张**用网表 BFS 独立算出来的**直方图一致。
（execute_slot 239 vs 178、div 201 vs 104 的差是因为直方图口径不同：BFS 数"锥到达的全部"，
普查只数"进了最慢 4000 条的终点"。）

**结论：一个 8 位指针 bit 的组合锥覆盖 63% 的组合逻辑与 74% 的触发器。**
在这个形状下，"把某一段搬到寄存器另一边"只是把延时从一批终点搬到另一批终点 ——
这正是 §15.10.26 全部六个数变差的机制。**下一刀必须减少总逻辑深度或多拍完成，不能再是点切。**

**④ `src` 归因的盲区已量化：2352 个触发器是数组寄存器，不是漏查**

8315 个触发器里 **5963 个有 `src`、2352 个没有**（28.3%），全部是 `$auto$ff.cc:337:slice`
（Yosys 生成）且全部是 `DFFHQNx1`（无异步复位）。在 `mapped.v` 里它们恰好是**两个连续块**：

| 块大小 | 对应 RTL | 算式 |
|---|---|---|
| **2048** | `core/prf.v:18` `reg [31:0] regs [0:63]` | `PRF_SIZE(64) × 32` |
| **304** | `core/mem_subsystem.v:156-158` `ld_addr_r`/`ld_width_r`/`ld_idx_r` | `LD_INFLIGHT(8) × (32 + 2 + 4)` |

机制：这两处都是**变址切片写**（`regs[preg] <= …`、`ld_addr_r[p*32 +: 32] <= …`），
Yosys 推不出整字 `$dff`，只能建"逐位 `$dff` + 译码器"，这些新单元不带 `src`。
⇒ `pathsrc.py` 的 `?` 与 `cone.py` 的 `?（无 src）`**不是查不到，是一批确定的数组寄存器**；
其中 2320/2352 落在那个支配锥里 —— 即这个锥一路扇出到**整个物理寄存器堆的写口**
（`ld_rd_p → ld_idx_r 8 选 1 → ld_done_idx → 回写 PRF`），与 §15.10.26 观察到的
"终点换了但起点没换"完全吻合。

**⑤ 逐级归因（`tools/cone.py --path 0`，100 级 / 12.0709 ns）**

手法：以**所有触发器**为源做一次多源正向 BFS，给每个组合 cell 标上"到最近上游触发器的级数 +
那些触发器的模块"。**限制**：标签是"最近"的边界，回答"这段逻辑贴着谁的寄存器"，
不回答"这条路径穿过了谁"（要确定归因只能 `MODE=diagnose`）。

| 级 | 模块 | 段延时 | 占全路径 |
|---|---|---|---|
| 0-4 | `mem_subsystem` | 1.4280 ns | 11.8% |
| 5-53 | **`lsq`**（第一段） | **5.2956 ns** | **43.9%** |
| 55-77 | `execute_slot` | 1.3454 ns | 11.1% |
| 80-96 | **`lsq`**（第二段） | **2.7459 ns** | **22.7%** |
| 97-99 | `icache` / `axi_lite_master` | 0.1392 ns | 1.2% |

**lsq 两段合计 8.0415 ns = 全路径的 67%**。最贵的两级都在 lsq 段内：
级 89 `XNOR2xp5` 扇出 **279**（**0.9504 ns**）+ 级 90 `NAND2xp33` 扇出 **130**（**1.2470 ns**），
两级 = **2.1974 ns = 18.2%** —— 与 `tools/README.md` §3 记录的 `lsq.v` `merge_byte_f`
CSE 共享节点（49 级深、扇出 637）同源。

**⑥ 对下一步的含义**

1. **点切作废**（§15.10.26 已实测）。可行方向只剩两条：**(a) 减少总逻辑深度**（少一级功能 / 缩小位宽 /
   把宽比较提到条目级而不是叶子级）、**(b) 多拍完成**（把长链本身拆成流水）。两者都要动 `lsq.v` 的
   内部结构，而不是它的边界。
2. **工具已就位**：`census.tcl` 回答"有几条长路径"，`cone.py --cone` 回答"这一刀的收益会被多少终点分摊"，
   `cone.py --path` 回答"这段逻辑贴着谁的寄存器"。**下一刀动手前必须先跑 `--cone`**：
   锥规模没显著缩小就意味着还是零和。
3. 一个尚未回答的问题：**12 ns 里有多少是 RTL 深度、有多少是 ABC 的映射选择？**
   `synth.ys` 把 `CLOCK_PERIOD_NS` 以 ps 传给 `abc -D`（默认 2.0 ns ⇒ `-D 2000`），
   而本设计关键路径 ~12 ns ⇒ **默认等于让 ABC 放弃时序、纯按面积映射**。
   `tools/run.sh --period=<ns>` 就是这个旋钮的探针，见 §15.10.28。

**⑦ 与 §15.10.13（5 次"降深度"负结果）的关系 —— 两者不矛盾，是两类不同的改动**

§15.10.13 的 5 次负结果（`lsq1` +181% / `lsq-tree2` +22% / `rs-prefix` +23.7% …）**全部是"重构"**：
把 16 级串行链换成 4 级平衡树，**逻辑总量不变**。其失败机制已经查明：串行链的中间值每个只用一次，
树/前缀结构的中间值是**结构同构**的（每个节点都是同一个几比特比较），ABC 的 `strash`/`fraig`/`dch`
把它们合并成一个共享文字，扇出 = 节点数 × 位宽 ⇒ 实测造出扇出 1129 / 2631 的灾难节点，整版退化。
**"越是消除串行、换成平衡并行，越是在给 ABC 递共享节点。"**

本节给出的新事实是：这条路走不通的**真正原因**是 §15.10.25 的深度账单**没有被这些改写动过**
——`lsq-tree2` 的级数确实从 94 降到 58、上限 A 从 265 抬到 391 MHz（四项事前指标全变好），
但**扇出税从 14.05 ns 涨到 19.21 ns**，净效果是变慢。也就是说：
**重构把深度换成了扇出，而本流程（官方 `abc` 不带 `-constr`、不插缓冲、不做 upsizing）里扇出比深度更贵。**

⇒ 尚未被证伪的只有两类改动：
- **(a) 减少逻辑总量**（少一级功能 / 缩小位宽 / 把宽比较的**份数**减半），而不是重排同样的量；
- **(b) 改协议让长链跨拍**（把"当拍组合回环"变成握手/FIFO），而不是在同一拍里挪寄存器边界 ——
  §15.10.26 试的是 (b) 的**一半**（只切请求侧、留下 `ld_busy` 的同拍承诺与完成侧），
  所以指针仍是枢纽、路径只换了终点。完整的 (b) 需要同时切断**完成侧**
  （`ld_rd_p → ld_idx_r 8 选 1 → ld_done_idx → CDB → RS 唤醒`）。

#### 15.10.28 `CLOCK_PERIOD_NS` 在本流程里**完全无效**，且扇出税是流程结构性的（2026-09-29）

§15.10.27 ⑥-3 留下的问题："12 ns 里有多少是 RTL 深度、有多少是 ABC 的映射选择？"
`scripts/synth.py` 把 `CLOCK_PERIOD_NS` 以 **ps** 传给 ABC 的 `-D`（默认 2.0 ns ⇒ `-D 2000`），
`docs/description.md:350` 也说该参数"用于驱动 ABC 在逻辑优化阶段进行时序重构"。
故本次用 `tools/run.sh --period=<ns>`（新增的旋钮）在**完全相同的参数与 RTL** 上跑了三个点。

**① 实测：三个点的网表逐字节相同**

| run | `CLOCK_PERIOD_NS` | `abc -D` | 最小周期 ns | fmax MHz | worst slack ns | 由周期−slack 反推的路径延时 | 面积 µm² |
|---|---|---|---|---|---|---|---|
| `ic1k` | 2.0 | 2000 | 12.1416015625 | 82.36 | −10.141287 | **12.141287** | 8,184.207 |
| `abc6` | 6.0 | 6000 | 12.141357421875 | 82.36 | −6.141287 | **12.141287** | 8,184.207 |
| `abc34` | 3.4 | 3400 | 12.141552734375 | 82.36 | −8.741287 | **12.141287** | 8,184.207 |

- **`mapped.v` 的 md5 三者完全相同**（`10ee95b8333d555f663959c17301b82d`，各 9,307,588 字节）。
- 三条的**关键路径延时逐皮秒相同**（12.141287 ns）。最小周期那点 2.4e-4 ns 的抖动是 OpenSTA
  二分搜索的粒度噪声，不是网表差异。
- 面积三项（组合 5,157.456 / 时序 2,639.767 / SRAM 386.984）也逐位相同。
- 反证：`worst_setup_slack_ns` 随周期**变了**（−10.14 / −6.14 / −8.74），说明周期确实一路传到了
  OpenSTA 与 `synth.ys` 的 `abc` 命令行（已直接核对 `synth.ys` 里是 `-D 6000` / `-D 3400`）。
  ⇒ **不是"参数没传进去"，是 ABC 收到 `-D` 之后产出了同一张网表。**

**② 机制：`{D}` 落在 `&nf` 上，而官方流程走的是"无约束"那条脚本**

容器内 `yosys -p "help abc"` 给出默认的 ABC 脚本（`-liberty` 且**不带 `-constr`**）：

```
strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash;
&get -n; &dch -f; &nf {D}; &put
```

`{D}` 在这条脚本里**只出现一次**，即 `&nf {D}`，`-D` 的取值就是它替换的内容。
`yosys-abc -c "&nf -h"` 确认 `&nf` 是库映射器且确实有 `-D`：
`-D num : sets the delay constraint for the mapping [default = best possible]`。
但三个不同的 `-D`（2000/3400/6000，全都比 12.14 ns 的目标紧）产出同一张网表 ——
**本设计的时序在 ABC 眼里已经无解，不同约束下它收敛到同一个（面积最优的）解**。
`CLOCK_PERIOD_NS` 因此**不能用来买频率**，它只改 OpenSTA 的检查基准。

**③ 更重要的副产物：这条脚本里没有 `buffer` / `upsize`**

`help abc` 同时给出**带约束**那条脚本（`-constr`）的内容：

```
... &dch -f; &nf {D}; &put; buffer; upsize {D}; dnsize {D}; stime -p
```

即**只有在 `-constr` 分支里才会插缓冲与做驱动强度调整**。而官方 `scripts/synth.py`
（属官方、勿改）走的是无约束分支 ⇒ **本流程的映射结果既不做缓冲插入、也不做 upsizing**。

这正好解释了 §15.10.25 那张表里最刺眼的数字：一个 `NAND2xp33` 直接驱动 **130** 个负载
（63,714.5 fF）、一个 `XNOR2xp5` 驱动 **279** 个（120,793.5 fF），单级延时 1.2470 / 0.9504 ns
——**未经驱动能力优化的网表里，宽扇出必然是灾难**。扇出税占关键路径 **8.0975 ns / 67%**，
而它在**本流程内**没有任何旋钮可解（`config.mk` 里除本参数外没有别的综合开关）。

**④ 对下一步的含义**

> ⚠ **更正（同日，见 §15.10.32）**：下面第 1、2 条的**前提**被 `-constr` 实测推翻了。
> `-D` 在**无约束分支**里确实无效（① 的 md5 三点相同仍然成立），但 `buffer/upsize/dnsize`
> **只在 `-constr` 分支里**，而它一开就把最小周期从 12.1416 ns 打到 **4.0195 ns（÷3.02）**。
> ⇒ 扇出税**有**旋钮可解，而且它就是主因；"所有频率工作必须在 RTL 里"不成立。

1. **"换个综合参数就提频"这条路到此为止**（已证伪，不是猜的）。所有频率工作必须在 RTL 里。
2. 同时这也**加强**了 §15.10.27 ⑦ 的结论：既然流程不会补驱动能力，**RTL 里凡是造出宽扇出共享节点的
   写法都会被全额惩罚**，而 §15.10.13 那 5 次"重构"（串行链→平衡树）恰恰是**主动给 ABC 递共享节点**。
   ⇒ 唯一还有正期望的方向是 **(a) 减少逻辑总量** —— 让 ABC 根本没有可共享的东西可提。
3. `tools/run.sh --period=<ns>` 保留（它现在的作用是**证伪的工具**：任何"参数能不能提频"的猜想
   都可以用它一次综合 + 一次 md5 判定），但**不要再指望它出性能数**。

#### 15.10.29 全设计路径普查：**71% 的终点吊在一个触发器上**，设计是严格双峰的（2026-09-29）

§15.10.27 用的是 `census.tcl` 取 4000 条路径，看到的全是从 `_141944_` 出发的锥；但"4000 条
都同源"**不能**推出"设计里只有这一个问题"——它也可能是"这个锥恰好是最差的 4000 条，其余
稍慢一点"。这两件事的应对完全不同，所以把 `CENSUS_N` 开到 **30000**（> 终点数）再普查一次。

**① 结果：返回 8758 条 = 终点总数本身（`CENSUS_COUNT 8758`），即全设计每个终点的最差路径**

| 最差延时区间 (ns) | 终点数 | 占比 |
| --- | ---: | ---: |
| `[0, 1)` | 875 | 10.0% |
| `[1, 2)` | 1235 | 14.1% |
| `[2, 3)` | 457 | 5.2% |
| **`[3, 3.333)`** | **0** | **0.0%** |
| **`[3.333, 6)`** | **0** | **0.0%** |
| `[6, 9)` | 2161 | 24.7% |
| `[9, 99)` | 4030 | 46.0% |

**`[3, 6)` 区间里一条都没有** —— 分布不是"普遍偏慢"，是**严格双峰**，中间一条真空带。

**② 峰的归属（起点去重后只有 1 个）**

- **≥ 4 ns 的 6191 个终点，起点去重数 = 1**，全是 `_141944_/QN`，延时 **6.0695 – 12.1413 ns**。
- **≤ 4 ns 的 2567 个终点，来自 110 个不同起点**，最差 **2.6416 ns**。
- 交叉验证：`cone.py --cone _141944_` 独立算出该锥到达 **6185** 个触发器，与普查的 **6191**
  个终点相差 6（0.1%）——两个完全不同的方法（网表 BFS vs OpenSTA 路径枚举）互证。

`_141944_` 是 `verilog/core/mem_subsystem.v:171.5-179.8` 那 8 个触发器中的第 1 个
（`ld_wr_p[LD_IW:0]` / `ld_rd_p[LD_IW:0]`，`LD_INFLIGHT=8 ⇒ LD_IW=3 ⇒ 各 4 位`，
网表里 `_141944_`–`_141951_` 连续 8 个 `DFFASRHQNx1`）。这 8 位的扇出为
`58 / 14 / 92 / 3 / 8 / 7 / 10 / 3`：最小的两个（扇出 3）都只驱动一个 `XNOR2xp5`，
正是减法器第 0 位的裸异或；其余位参与进位链与 8 选 1 变址。**与"`ld_inflight_w = ld_wr_p − ld_rd_p`
是一根进位链，进位链末端（`>= LD_INFLIGHT=8` 只判最高位）才是枢纽"的读法一致**
（这是旁证，不是证明——真正定论要看 §15.10.27 ⑤ 的逐级归因）。

**③ 这条结论比 §15.10.27 强在哪**

§15.10.27 说的是"一个锥吃掉 63% 的组合逻辑"，容易被读成"全设计都慢，得整体重写"。
普查给出的是**可执行的分界**：

- **29.3% 的终点（2567 个）已经满足 300 MHz**（最差 2.6416 ns），**一个都不用动**；
- **70.7% 的终点（6191 个）全部**要压到 3.333 ns 以下。它们的最差路径中位数约 **10.36 ns**
  （第 2560 名切片），即**中位路径要缩 3.11×，最差那条要缩 3.64×**。

**④ 为什么 §15.10.26 那一刀必然无效（普查版解释）**

那 6191 个终点是 **6191 个各不相同的终点**，散布在 rob / rs / prf / axi / lsq 里。切掉一条链
只让**经过切点**的那部分变短；§15.10.26 切了请求侧，最差路径立刻换到完成侧
（`ld_rd_p → ld_idx_r 8 选 1 → ld_done_idx → CDB → RS 唤醒 → execute → div`，13.05 ns / 98 级），
**因为完成侧本来就有一条差不多长的链在排队**。这不是意外，是双峰分布的必然：
锥里任何一条链被切断，剩下的链里最长的那个立刻顶上来。

**⑤ 对"还能不能到 300 MHz"的定量回答**

1. 必须让 **6191 条路径同时**降到 3.333 ns 以下 ⇒ 沿这些路径**每一个组合段**都要 ≤ 3.333 ns。
   这是**再流水化（re-pipelining）**，不是"再切一刀"。
2. 可动的范围明确：**只涉及这个锥**（40,850 个组合 cell = 全设计组合逻辑的 62.7%），
   另外 29.3% 的终点不必碰。这比"整体重写"小得多，但比任何一次点切大得多。
3. 现有证据表明**单点/单侧改动期望为负**（§15.10.13 五次重构、§15.10.26 一次点切，全部实测退化）。
   剩下的唯一形态是 **(b) 的完整版**：请求侧与完成侧**同时**跨拍，且跨拍后各段的深度
   都必须落在 3.333 ns 以内——这需要一次**多级**流水改造，并配套改握手协议
   （见 §15.10.27 ⑦ 末段"完整的 (b)"）。
4. **风险已量化**：6 次实测负结果 + ABC 会跨新寄存器边界重新因式分解 ⇒ 任何单次改动的
   结果都必须在容器里实测，不允许用级数/面积/锥规模代替。

**⑥ 本轮不做的事（记录在案，避免下一个人重走）**

- 不动 `_141938_/QN` 那 740 个终点（`exec/execute_slot.v:183.5-194.8`）—— 它们最差 **2.6416 ns**，
  不是问题。普查前它看起来像"第二大起点"，普查后证明它离违约线还有 20% 余量。
- 不再做任何"结构改写"（§15.10.27 ⑦ 已给出机制：重构 = 把深度换成扇出，而本流程扇出更贵）。
- 不再动综合参数（§15.10.28 已证伪）。

---

#### 15.10.30 关键路径的**逐语句**归因：最大一段是 `merge_byte_f`（44%），且整条路是一条"同拍冲刷回环"（2026-09-29）

> **⚠ 更正（同日晚，用 `mapped.v` 直接追网表）**：下面 **三.1 被证伪** ——
> "请求选择链的 `addr_r[pidx*32+:32]` **根本不在计时路径上**"是**错的**，它正是路径的**尾巴**。
> 错的根源：本节只做了"从 `_141944_` 出发的**前向**锥 + 终点落在哪个模块"，而 `pidx = head_r + pdist`
> 里的 `pdist` **本身就在 `_141944_` 的锥里**（`pdist = first_one_f(cand)`，`cand` 依赖 `kill` ← 完成合并）
> ⇒ `addr_r` 的选择位是一位**汇合节点**，不是"起点之前的逻辑"。**五 的排序因此不必推翻**
> （C2 仍第一），但"请求侧可以先不管"这个推论作废。取证与逐位对应见 **§15.10.31**。
>
> 另：本节 **四** 的结论（`merge_byte_f` 是"扇出税质量"不是"深度"）**仍成立**，未被推翻。

§15.10.27 ⑤ 的逐段表用的是"最近上游寄存器所属模块"，那是**邻域标签**不是路径遍历
（该节自己也注明了）。本轮换掉它：宿主 yosys 0.68 在 **`runs/ic1k/verilog/` 的同一份 RTL**
上重跑 elaborate 阶段（`read_verilog -sv -D SYNTHESIS` 逐源 + FakeRAM + `hierarchy -top student_top`
+ `proc` + `memory_collect`），得到**语句级**网表（14691 cell，每 cell 带 `src = 文件:行`），
在其上做 ① 从 `ld_wr_p`/`ld_rd_p` 出发的前向锥 BFS，② 最长路回溯。

> 踩过的坑（免得下次重踩）：`src` 不在 cell 顶层，在 **`cell['attributes']['src']`**；
> 参数是 yosys 二进制串（`s32'000…1010000`），按十进制解析会炸；
> 锥的 BFS 必须建**消费者**映射（`net → [(cell, port)]`），建成"驱动者"映射的话
> 锥会退化成起点触发器本身。

##### 一、先证这份分析可信（否则下面的结论不能用来下刀）

同一套解析器跑**真实映射网表** `mapped.v`，从 `_141944_`/QN 做前向锥：
**40851 个 net、最长 103 级、到达 6195 个触发器**。
对照 §15.10.27 的"锥内 40850 个组合 cell"、§15.10.29 的"6191 个终点" —— **三方吻合**。
⇒ 结论：**普查里那 6191 个慢终点，全部在这个锥里**；锥不是"一条长链带侧枝"，
而是**一个约 100 级的共享前缀 + 6195 个分叉终点**（这些终点的**中位**最差路径 10.36 ns，
即中位终点也继承了约 88 级前缀）。**任何单点切割都救不了它** —— 切掉一段，
其余终点照样继承剩下的前缀；只有把**每一个**组合段都压到 3.333 ns 以下，6195 个终点才同时达标。

##### 二、路径的 RTL 形状（逐语句，与 ⑤ 的实测段逐位对齐）

| 段 | RTL 语句 | 实测 | 占 |
|---|---|---:|---:|
| 1 | `mem_subsystem.v:189-191`：`ld_a_w`/`ld_w_w`/`ld_i_w` 三个 **8 选 1**，选择位 `ld_rd_p[2:0]` | 1.43 ns | 12% |
| 2 | **`lsq.v:256-271` `merge_byte_f`**：16 项 × 4 字节的 32 位地址范围比较 + 16 级优先更新串行链 + `dt[bj*32+bo+:8]` **512 位变量位选** | **5.30 ns** | **44%** |
| 3 | `lsq.v:291-297` `load_cdb_result` → `execute_slot.v:256/270` CDB 旁路 → `branch.v` → `cpu_top.v:760/773` `ce_w`/`inv_one` | 1.35 ns | 11% |
| 4 | `lsq.v:99/102` `kill`/`dead` → `lsq.v:115` `dead_skip_f` **16 级串行** → `lsq.v:124` `free_count_w` → `cpu_top.v:422-424` `resources_ok` → `cpu_top.v:902` `fetch_stall` | **2.75 ns** | **23%** |
| 5 | `fetch.v:73-124` → `ras.v:33-70` | 0.14 ns | 1% |

段 1/2 与 ⑤ 的"级 0-4 `mem_subsystem` 1.4280 / 级 5-53 `lsq` 第一段 5.2956"**逐位吻合**；
段 3/4 与"级 55-77 `execute_slot` 1.3454 / 级 80-96 `lsq` 第二段 2.7459"吻合。
⇒ 两套独立方法给出同一分段，⑤ 那次的模块标签这次是对的（但机制上仍不该依赖它）。

**这是一条单拍闭环**：完成 → 8 选 1 → `merge_byte_f` → CDB 旁路 → execute/branch →
误预测/冲刷 → LSQ `kill` → `dead_skip_f` → `free_count` → `issue_en` → `fetch_stall` → 取指重定向 → RAS。

##### 三、三个修正（对本轮计划的直接影响）

1. **最大的一段是完成合并不是请求选择。** 原计划的 S1/S2 排序要按数据改：
   `merge_byte_f` 占 44%，而请求选择链的 `addr_r[pidx*32+:32]` **根本不在计时路径上**
   （它的选择位 `pidx` 由 `head_r` 组合算出，但 `ld_start_*` 只驱动 `mem_subsystem` 的
   **起点触发器** `ld_addr_r` 等，属"起点之前的逻辑"，不在 `_141944_` 之后的锥里）。
2. **扇出税的来源定位到了。** `addr_r[mem_done_idx * 32 +: 32]` 是 **32 位 × 16 选 1** 变量位选：
   选择位 `mem_done_idx[3:0]` 的第 k 位要驱动 `32 × 8/4/2/1` = **256/128/64/32** 个 mux。
   实测的 **279 / 130 / 66**（§15.10.27 热级表）与这个 **4:2:1** 比例一致。
   ⇒ 那些宽扇出**不是"一个信号被很多消费者需要"**，而是**一个宽位选的选择树**。
   这解释了为什么"减少消费者"这条路不存在（没有 279 个消费者，只有 1 个选择位），
   也解释了 ABC 为什么在这里造出 2320 个无 `src` 的 cell（CSE 结果）。
   **唯一解仍然是"让这个选择树变小"**：`merge_byte_f` 内部的 `dt[j*32 +: 8]` × 4 处调用
   就是这个树的另一副面孔（见下）。
3. **段 4 那 2.75 ns 是"同拍冲刷"链，而且它是主动选择的结果。**
   store 提交（`ce_w`）组合地失效 LSQ 条目（`cpu_top.v:773` `inv_one`）→ 组合地改变
   `lsq_free_w` → 组合地决定 `issue_en` → 组合地卡取指（`cpu_top.v:902`）。
   `cpu_top.v:409` 的注释（"`lsq_free_w` 内部已含本拍失效腾出的槽，此处不再另加"）
   说明这是**有意为之的同拍性**；`fetch_stall` 的另一项 `flushing_r` **本来就是寄存器**。
   ⇒ 可以换成"保守一拍"（本拍腾出的槽不计入，至多多停一拍发射）把它从路径上摘掉。

##### 四、`lsq` 的"质量 vs 深度"分家（决定 S2 该怎么做）

`lsq` 是 `prf` 之外最大的组合模块（3103 个语句级 cell，全设计 305 个 `$shiftx` 里它占 200）。
但拆开看：

| 部分 | 规模 | 拓扑深度 |
|---|---:|---|
| `merge_byte_f`（L237-285）及其 4 次调用 | **1365 个 cell 的锥中占 1244（91%）** | **浅（约 5 级）** |
| 请求链 `dead_skip_f`(L115) → `cand`(L141) → `first_one_f`(L153) → `pidx`(L157) → `issued_r[pidx]`(L218) | 少 | **深** |

⇒ **`merge_byte_f` 是"扇出税质量"，不是"深度"**。它与段 4 一起构成 67% 的扇出税来源
（§15.10.25 的 8.0975 ns）。而 4 次 `merge_byte_f` 调用**不能合并成一次扫描** ——
未对齐访问跨两个 store 时，每个字节的 `bj`（命中项）**确实不同**（L262-266 的优先级更新）。
⇒ S2 的可行形态只有两种：(i) 把"匹配拍"（算 `found/bj/dj`）与"取数拍"（`dt[bj*32+bo+:8]`）分开；
(ii) 把 16 项扫描换成**按地址索引的 forwarding 表**（SQ 深度只有 4，表很小）。
两种都要处理"提交与完成拆拍后，本拍提交的 store 在 LSQ 与 sq 里同时不可见"的静默错数风险。

##### 五、切点清单（按实测收益重排，全部落在语句边界上）

| 编号 | 语句位置 | 切法 | 收益 | 风险 |
|---|---|---|---:|---|
| **C2** | `lsq.v:256-271` + 4 次调用（L274-283） | 匹配拍 / 取数拍分开，或换 forwarding 表 | **5.30 ns → ~2.7+2.7** | **高**（三层合并同拍性） |
| **C3** | `cpu_top.v:409/423` `lsq_free_w` | `resources_ok` 改用**不含本拍失效**的保守 `free_count` | **2.75 ns** | **低**（至多多停一拍发射） |
| **C1** | `mem_subsystem.v:189-195` 交付元组 | `ld_a_w/ld_w_w/ld_i_w/ld_raw_w` 寄存一拍再出 `ld_done_*`；`issued_r` 清除随之后移 | 1.43 ns | 中（`ld_done_valid` 后移一拍，`sq` 释放条件要同步） |
| **C4** | `mem_subsystem.v:163-168` 在飞管理 | 独立 4 位在飞计数器 + 寄存的 `ld_busy`（保守多报忙） | 小（单独 0.139 ns） | 低 |

**注意 C2 与 C3 都不新增任何数据通路寄存器**（C1/C4 才加）—— 它们是**换函数形状**，
这正是 §15.10.26 失败（切在链尾、只切一侧）所缺的东西，也是原计划 S1/S2 的本意，
只是现在**切点的选择有了实测依据**：C2 打 44%，C3 打 23%，两者合计 67%，
正好等于 §15.10.25 量到的扇出税占比。

**顺序建议（待用户裁定）**：原计划是"第一次 = S4+S1（请求侧）+ S3 残余（完成侧）"。
数据说请求侧的 `addr_r[pidx*32+:32]` 不在计时路径上、S1/S4 合计只值约 1.5 ns，
而 C2+C3 值 8 ns 且都不需要动 `ld_start_*`/`ld_busy` 握手。
⇒ 建议第一次手术改为 **C3 + C1**（低风险侧先落地，验证"换函数形状"这条路），
C2 单独做第二次。

#### 15.10.31 关键路径尾巴的**逐门取证**：`pidx[0]` 一个人驱动 261 个 mux 选择端（2026-09-29）

> ⚠ **标题里的结论"261 个 mux 选择端"已于 2026-09-30 被证伪**（见下文 二.1 与 四 的更正）：
> 那些引脚是 `AOI21xp33` 的 `A2`，而该单元的函数 `!(B + A1·A2)` 里 `A1`/`A2` 对称，
> **引脚名不携带角色信息**。网络本身是**共享中间文字**，不是 mux 选择位。
> 本节保留原文以免抹掉推理过程，**但按 四 的升级规则读**。

§15.10.30 的更正需要证据，不能只凭"扇出比例像"。用 `runs/ic1k/build/synth_ic1k/opt/`
的 `mapped.v`（ABC 映射网表）+ `design.json`（带 `src`）直接追网表，结论是**逐门确定**的。

##### 一、路径尾部的形状（官方 `timing.rpt` 的第 1 条，共 100 门）

| 级 | 累计 ns | 单级 delay | 扇出 | cell |
|---:|---:|---:|---:|---|
| 1 | 0.1677 | 0.1677 | 57 | `_141944_/QN`（起点触发器 `DFFASRHQNx1`） |
| 2 | 0.4323 | 0.2646 | 111 | `_074388_/Y` `INVx1` |
| 3 | 0.8683 | 0.4360 | 73 | `_075049_/Y` `NAND2xp33` |
| 4 | 1.5957 | 0.6235 | 107 | `_075064_/Y` `AOI33xp33` |
| 5 | 2.3656 | 0.5764 | 93 | `_077145_/Y` `AOI22xp33` |
| 6 | 4.5932 | 0.3789 | 69 | `_084287_/Y` `NOR2xp33` |
| 7 | 5.3093 | 0.5873 | 106 | `_084363_/Y` `AOI21xp33` |
| 8 | 6.1187 | **0.8093** | 106 | `_084404_/Y` `OAI21xp33` |
| 9 | 6.8317 | 0.7130 | 66 | `_084406_/Y` `NAND2xp33` |
| 10 | 7.4232 | 0.4078 | 66 | `_097882_/Y` `AOI21xp33` |
| 11 | 8.4050 | 0.1679 | 29 | `_098454_/Y` `OAI211xp5` |
| 12 | 9.0040 | 0.3618 | 67 | `_099094_/Y` `O2A1O1Ixp33` |
| **13** | **10.3539** | **0.9504** | **279** | **`_116750_/Y` `XNOR2xp5`** |
| **14** | **11.6009** | **1.2470** | **130** | **`_116755_/Y` `NAND2xp33`** |
| 15–100 | 12.0709 | 剩余 0.47 | ≤13 | 9 个小门 → `_142968_/D` |

（前 14 级之外的 86 级合计只有 **0.47 ns**：它们是 mux 树"等选择位到位"之后的快速收敛。）

##### 二、这 2.20 ns 是什么：`pidx[0]` 的译码

1. ~~`_116755_/A = _116750_/Y = _059441_`。**网表追线**：`_059441_` 的 **279 个负载里 261 个是 `A2` 端口**
   （`AOI21xp33` 122 个、`O2A1O1Ixp33` 84 个、`OAI21xp33` 40 个…）。
   在 `AOI21/OAI21/O2A1O1I` 构成的 mux 里，**`A2`/`B1` 是选择端、`A1`/`B` 是数据端**
   ⇒ 这是一个**选择位**，不是数据位。`_059446_`（下一级，扇出 130：`B1` 65 + `A2` 62）同理。~~

   > ⚠ **本条已于 2026-09-30 证伪并更正。** 推翻它的是 r28 官方 liberty 里的**单元函数**本身，
   > 不是又一轮指纹比对：
   > `AOI21xp33_ASAP7_75t_R` 的 `function : "(!A1 * !B) + (!A2 * !B)"` ≡ `!(B + A1·A2)`
   > —— **`A1`/`A2` 是一对完全对称的 AND 输入，库里不存在"选择端 vs 数据端"这个区分**。
   > 引脚名 `A2` 上挂着 261 个负载，只说明"这个网被 261 个门的某个 AND 输入共用"，
   > **推不出它是索引位**。
   >
   > 该看的是**驱动它的东西**（`/tmp/casc.py` 实测）：`_059441_` 由 `_116750_/Y`
   > （**`XNOR2xp5`**，扇出 279）驱动 —— 它已经是**算好的函数**，不是原始索引位；
   > 邻居 `_059443_`(137) ← `OR2x2`、`_059444_`(155) ← `XNOR2xp5`、`_059446_`(130) ← `NAND2xp33`、
   > `_059439_`(75) ← `XNOR2xp5`、`_059440_`(82) ← `INVx1`。⇒ 这是一个**级联的共享中间文字**
   > （ABC 的 `&fraig`/`scorr`/`dc2` 做出来的 CSE 公共子表达式），
   > 而同一批门真正的数据位是那些**低扇出的触发器兄弟网**：`_004078_` 11、`_004046_` 13、
   > `_004142_` 15（全部由 `DFFHQNx1` 驱动）。
   >
   > ⇒ §15.10.30 三.2 那个 "279/130/66 与 4:2:1 一致" 的指纹是**巧合**：
   > 任何 16 选 1 × 32 位、以及任何一批被大量复用的共享文字，都会算出同样的比值。
   > **结论的方向没变**（尾巴上确实是一堆宽扇出的共享节点），但**那些节点的身份**不是
   > "某个 mux 的选择位"，这直接影响下面 三 的措辞与 §15.10.13 五连负的解释 —— 见 §15.10.33。
2. `_116750_/A = _019232_ ← _073467_/Y(INVx1) ← **_139419_**`。
   `_139419_` 是 `DFFHQNx1`，`src = core/lsq.v:165.5-228.8`（lsq 的 posedge 块），
   且它是**全设计扇出最高的触发器（286）**；紧邻的 `_139420_`/`_139421_` 实测扇出 **145/73**
   —— **2:1 的二进制权重组**，与"某个 4 位索引寄存器的低位"一致（第 4 位 `_139422_` 实测 58，
   不落在 36 上，所以**具体是 `head_r` 属推断，不是实证**；实证的只有：选择位来自
   **lsq 内、离一个高扇出触发器只有 1–2 级门**，而 `rd_wr_p` 在 `axi_lite_master.v`，
   故排除它）。
3. `_116750_/B = _059429_ ← _116738_/Y`，回溯 12 级内命中 **231 个触发器**
   （`lsq.v` 132、`rob.v` 85、`execute_slot.v` 10…）⇒ 一个**很晚才到**的深锥输出 = `pdist[0]`
   （`pdist = first_one_f(cand)`，`cand` 依赖 `kill` ← 完成合并 ← 起点 `ld_rd_p`）。
4. ⇒ `_116750_ = XNOR(head_r[0], pdist[0]) = ~pidx[0]`，`_116755_` 是 2 位部分译码。
   ⚠ 这条**同样是建立在被证伪的引脚名推理之上**（见 二.1）—— `_116750_` 是 `XNOR2xp5` 这一点
   是实证的，但"所以 = `~pidx[0]`"不是。

**结论**：~~路径最后 2.20 ns 就是 **`addr_r[pidx * 32 +: 32]` 这棵 16 选 1 × 32 位变量位选的译码**，
而它慢不是因为"选择树大"，是因为**选择位 `pidx` 本身挂在 100 级链的末端**（`pdist` 是链尾）。
终点 `_142968_`（5 条归档路径是 `_142968_`–`_142972_`）落在
`core/axi_lite_master.v:121.5-131.8` 的读请求 FIFO 写入 —— 即 `ld_start_addr` 的下游。~~

> ⚠ **上面这条结论已被 二.1 的更正推翻**（2026-09-30）。站得住的只有两条：
> ① 路径最后 2.20 ns 落在**一批宽扇出的共享中间文字**上（`_059441_` 279 → `_059446_` 130 …），
> 它们由 `lsq.v` 里一个扇出 286 的触发器经 1–2 级门驱动；
> ② 终点是 `axi_lite_master.v:121.5-131.8` 的读请求 FIFO 写入。
> 而"这批文字就是 `pidx` 的译码"**没有证据**。

##### 三、对方案的两条硬约束（重要）

1. **S1 只搬端点、不斩链。** `ptr_nxt` 仍要算 `pidx_nx = head_r + first_one_f(cand_nx)`
   ⇒ 链 `… → pdist → ptr_nxt → ld_ptr_r/D` **深度不变**，只是端点从 axi FIFO 换成 `ld_ptr_r`。
   S1 真正省下的是**那批共享文字之后的负载树**（L13–L14 的 2.20 ns 换成"寄存器→译码→mux"≈0.9 ns）。
   ⚠ 这句里的"译码"原按"选择位"理解，已被 二.1 更正为"共享文字"；**但 S1 的实测效果不受影响** ——
   它的依据是 `c1s1` 的综合数字（−3.1%），不是这条机制推断。
2. **C1 斩的是链头**（1.43 ns）。⇒ 第一次手术的账面收益 ≈ 1.43 + 1.3 ≈ 2.7 ns，
   落点应在 9.3–10.5 ns 一带；要再往下必须动**中段**（C2 `merge_byte_f` 5.30 ns / C3 同拍冲刷 2.75 ns），
   即 §15.10.30 五 的原排序。

##### 四、一条方法论修正：**扇出指纹不足以定位**

§15.10.30 三.2 用"实测 279/130/66 与 4:2:1 的比例一致"断定那是
`addr_r[mem_done_idx * 32 +: 32]` 的译码。这个推断**不成立** ——
`addr_r[pidx * 32 +: 32]`、`addr_r[mem_done_idx * 32 +: 32]`、`rd_addr_r[rd_wr_p * 32 +: 32]`
**都是** 16 选 1 × 32 位，选择位都是 4 位，**算出来的 256/128/64/32 一模一样**。
判别靠的是另外两条，缺一不可：
1. **位置**：L13/L14 之后只剩 9 级 / 0.47 ns 就到终点 `_142968_/D` ⇒ 它是**紧挨终点**的那一级，
   而 `mem_done_idx` 的译码在 5.30 ns 那一段（链中段），不可能在 10.35 ns 处；
2. **所属模块**：选择位回溯 1–2 级门即命中 **`lsq.v` 的触发器**，而 `rd_wr_p` 在 `axi_lite_master.v`。
⇒ 只有 `addr_r[pidx * 32 +: 32]` 同时满足。

> ⚠ **本条自身也有一个漏洞，2026-09-30 补上：引脚名同样不足以定位。**
> 上面把 `A2` 当"选择端"用，而 `AOI21xp33` 的函数是 `!(B + A1·A2)` —— `A1`/`A2` 对称，
> 引脚名**不携带任何角色信息**（见 二.1 的更正）。所以"位置 + 所属模块"这两条判据里，
> 第二级其实还夹着一次非法的引脚名推理。
> ⇒ **升级后的规则**：在 post-ABC 网表上定位一个宽扇出网的**身份**，只看三条 ——
> ① 它**由什么驱动**（`XNOR2xp5`/`OR2x2` 这类"已经算好的函数"⇒ 是共享文字，不是原始索引位）；
> ② 它的**低扇出兄弟网**由什么驱动（触发器 ⇒ 那些才是数据位）；
> ③ 它到**起终点**的位置。**引脚名、扇出数、4:2:1 比值，一条都不能用。**

#### 15.10.32 `-constr` 实测：扇出税是**流程**问题 —— 12.1416 → 4.0195 ns（÷3.02）（2026-09-29）

起因：用户转述助教建议"加 `-constr` 综合优化试试"，并明确**在原有官方脚本基础上增加**、
判分口径待定、**暂不计入评分标准**。§15.10.9 六 曾把这条实验搁置，本次以单变量对照重做。

##### 一、单变量对照（RTL 逐字相同）

| 变体 | RTL | ABC 脚本 | 最低周期 | fmax | 面积 µm² | 组合 µm² | 时序 µm² |
|---|---|---|---:|---:|---:|---:|---:|
| `ic1k`（基线） | HEAD | 官方 | 12.1416 ns | 82.36 MHz | 8,184.21 | 5,157.46 | 2,639.77 |
| `constr1` | **HEAD（逐字相同）** | 官方 **+ `-constr`** | **4.0195 ns** | **248.79 MHz** | **8,941.70** | 5,914.95 | **2,639.77（不变）** |

- **RTL 逐字相同**：`diff -rq runs/ic1k/verilog runs/constr1/verilog` 只有 `mem_subsystem.v`
  一处注释 + `.fill_busy()`（空连接）vs `.fill_busy(unused_fill_busy_w)`，`opt` 展平后网表无异；
  `filelist_ic.f` 只差注释。⇒ 单变量成立。
- **脚本只差一行**：`scripts/synth.py:109` 多传 `-constr /work/abc.constr`；
  `abc.constr` = `set_driving_cell INVx1_ASAP7_75t_R` + `set_load 5.0`。
  官方 SDC **没有** `set_load`、也**没有** `set_driving_cell`（只有时钟与端口输入/输出延时）
  ⇒ 这两个值在官方口径里没有定义，只能自己定（口径待定，见 五）。
- **时序面积逐位相同（2,639.767 µm²）** ⇒ ABC **没有搬触发器**（`dretime`/`retime` 在本设计上
  是空操作），全部收益来自**缓冲插入与驱动强度调整**。这也排除了"retiming 造出了假起点"的解释。

##### 二、机制取证：这是**全局**改动，不是只治了那条路径

看两版 `mapped.v` 的**全设计**扇出分布（`reset` 不计）：

| | 网数 | 扇出 ≥64 | 扇出 ≥256 | **最大扇出** | 缓冲单元数 |
|---|---:|---:|---:|---:|---:|
| `ic1k` | 73,342 | **349** | **10** | **351** | **0** |
| `constr1` | 85,984 | **0** | **0** | **18** | **12,245**（`HB1xp67`）+ 约 400 个其他 |

- `-constr` 让 ABC 插了 **12,245 个 `HB1xp67`**，单元总数 73,480 → 86,122（+17.2%）。
- 面积只涨 9.3%（+757.5 µm²；757.5 / 12,245 ≈ 0.062 µm²/个，与 `HB1xp67` 的面积相符）。
- 关键路径随之变化（`path.py` 口径）：扇出税 **8.0975 ns（67%）→ 0.0000 ns（0%）**，
  路径上最大扇出 **286 → 10**，单级 **46.7 → 36.5 ps/级**，级数 100 → **109**（缓冲换来的级数）。

##### 三、这条结果推翻/确认了什么

1. **确认** §15.10.25 的扇出税诊断：这 8.10 ns / 67% 是真的，也确实能被消掉 —— 消掉之后
   周期直接除以 3.02。它是本设计提频的**唯一主因**，不是"之一"。
2. **推翻** §15.10.28 ④ 的"扇出税在本流程内**没有任何旋钮可解** ⇒ 所有频率工作必须在 RTL 里"。
   旋钮一直都在，就是 `-constr`（§15.10.28 ③ 自己已经查出 `buffer/upsize/dnsize` 只在那一支里）。
3. **追认** §15.10.13 的五连负、§15.10.26（+7.4%）、§15.10.31 与 `c1s1`（−3.1%）：它们全部是
   在"流程不插缓冲"这个前提下做的 RTL 挣扎。前提一换，**"重构 RTL 去消除共享节点"整条路线的
   目标就消失了** —— 共享节点还在，只是不再被惩罚。
4. **§15.10.28 ①（`-D` 三点 md5 相同）依然成立**，但那是因为**无约束分支里 `{D}` 只喂 `&nf`**；
   `-constr` 分支里 `{D}` 还要喂 `upsize {D}` / `dnsize {D}`。
   ⚠ **但 `-D` 不属于本次实验的变量** —— 用户 2026-09-30 裁定："**除了 `constr`，其他都用官方的
   参数**"。⇒ `-D`（= `CLOCK_PERIOD_NS` × 1000）**固定在官方默认 2.0 ns / 2000 ps**，不做扫描，
   这一条只作为"机制上它为什么在那一支里会生效"的记录保留，**不派生任何实测结论**。
   本节（以及后续）全部数字都出自官方默认参数这一个点。

##### 四、还剩多少：300 MHz 的缺口从"结构性"变成"深度"

| | 现在 | 300 MHz 需要 |
|---|---:|---:|
| 最低周期 | 4.0195 ns | **3.3333 ns**（差 0.686 ns，17%） |
| 级数 | 109 级 | ≤ **91 级**（按 36.5 ps/级 算） |

⇒ **扇出税归零之后，剩下的问题变成纯深度**，而深度是 RTL 拆流水**能直接砍**的量
（`pipe1` 的实测机制：−34%）。这与 §15.10.13 那五次失败的重构**不是同一类改动** ——
那五次是在同一拍里重排逻辑量，拆流水是把功能重新划到两拍。

**面积口径提醒**：`constr1` 的 8,941.70 µm² 距一档上限 9,000 只剩 **58.3 µm²**，
但一档要求 IPC ≥ 0.6000 而当前 IPC 是 0.4138 ⇒ 一档在本配置下**IPC 不可达**；
真实目标在二/三档（18,000 / 36,000 µm²），那里面积**根本不是约束**。
⇒ 后续所有改动按"目标档位的面积上限"记账，而不是按 9,000 记账。

##### 五、口径状态

判分口径**待定**（用户 2026-09-29 转述：助教让加 `-constr` 试试，后续可能更改，暂不计入评分标准）。
本节的数字一律标注为 **"官方脚本 + `-constr`"** 口径，与官方口径的数字分开记，不混用。

##### 六、复现命令与踩过的坑

```sh
# 逐字传参, 不要用 shell 变量拼 (见下)
# 不传 --period ⇒ CLOCK_PERIOD_NS 保持官方默认 2.0 ns (Makefile:22 的 ?= 2.0)
tools/run.sh constr1 --constr \
    ROB_SIZE=16 RS_SIZE=4 BHT_SIZE=8 RAS_SIZE=4 SQ_DEPTH=4 WR_DEPTH=4 \
    --filelist=docs/timing/filelist_ic.f
```

- **坑**：把参数列表放进 shell 变量再用 `$P` 展开，在**本机 zsh 下不会做单词拆分**，
  `--filelist=...` 会被并进上一个参数的值里；`--filelist=` 的值含 `/`，会提前终止参数补丁那条
  `sed` 的 `s` 命令（报 `bad flag in substitute command: 't'`），`set -e` 让整次运行静默退出。
  ⇒ `run.sh` 必须逐字传参。
- `tools/run.sh --constr` 会把补丁打在**变体树内**的 `scripts/synth.py` 上，并 `grep` 自检；
  打不上直接失败退出（静默不生效等于跑了个假对照）。官方 `scripts/synth.py` 本身不动。

#### 15.10.33 阶段总结：范围裁定、`-constr` 口径下的全设计普查与锥归因（2026-09-30）

本轮是**收尾轮**：不推进手术，只把 `-constr` 这条线取证到位、把越界的部分撤回、把口径钉死。

##### 一、范围裁定（用户 2026-09-30）：**只有 `-constr`，其余一律官方参数**

助教建议的是"**在原有官方脚本基础上增加 `constr`**"。本轮我一度把 `--period`（即 `abc -D`）
当成第二个可扫的旋钮跑了 3 个点 —— **这越界了，已作废**：

- 作废的树 `runs/cp1`（`--period=1.0`）、`runs/cp4`（`--period=4.0`）**已删除**；
- 由它们派生的任何数字（3.9990 / 4.1025 ns 等）**不作为结论**，撤回；
- 判据锚点回到 `Makefile:22` 的 `CLOCK_PERIOD_NS ?= 2.0` ⇒ `abc -D 2000`，**全场唯一取值**。

> 附注（不是新实验，只是口径澄清）：`-D` 在**官方分支**里早已被证伪并归档 ——
> `results.csv` 的 `abc6`（`-D 6000`）与 `abc34`（`-D 3400`）两行与 `ic1k`（`-D 2000`）
> 的 `mapped.v` **md5 完全相同**（§15.10.28）。此处只把它当作"这个旋钮不该被扫"的依据。

##### 二、`constr1` 的全设计终点普查（官方参数 + `-constr`，唯一在范围内的树）

`runs/constr1/build/synth_constr1/opt`，`tools/census.tcl`，时钟 3.333 ns，`CENSUS_N=30000`。

**8758 个终点**（与 `ic1k` 逐位相同 —— 同 RTL 同参数，`-constr` 只加缓冲不加触发器）：

| 区间 ns | 终点数 | |
|---|---:|---|
| [0.1, 1.0) | 2567 | |
| [1.0, 2.2) | **0** | ← 空 |
| [2.2, 2.8) | 2145 | 满足 300 MHz |
| [2.8, 3.3) | 16 | 压在线上 |
| **[3.3, 4.1)** | **4030** | **不满足** |

- 最差 **4.0190 ns**，与 §15.10.32 报的 `min_period_ns` 4.0195 **自洽**（差 0.0005）。
- 仍然是**双峰**，但坏峰从 ic1k 的 [9, 99) 被压到 [3.3, 4.1)。

**按起点归并（关键）**：

```
失败终点 (>=3.3333ns): 4028
不同起点数: 2
   3966  _165976_/QN   → core/lsq.v:165.5-228.8          (1336 个 DFFHQNx1 = LSQ 阵列写块)
     62  _167230_/QN   → core/mem_subsystem.v:171.5-179.8 (8 个 DFFASRHQNx1 = 在飞指针)
```

⇒ **不是 4030 条各自独立的坏路径，是 2 个锥**，其中 98.5% 吊在**一个**触发器上。

> 旁证：`_167230_` 正是 §15.10.29 在 ic1k 上认定的**唯一来源**（`mem_subsystem.v:171-179`
> 那 8 个在飞指针，当时独占 6191/8758 个终点）。`-constr` 之后它**掉到 62 个终点**
> （≤3.9708 ns）—— 扇出税归零把那根锥基本放平了。

##### 三、锥的形状：**共享前缀 + 各自的尾巴**（决策依据）

`_165976_/QN` 一个人扇出 **4515 个终点**，延时从 **2.2505 铺到 4.0190（1.77 ns 跨度）**：

| 区间 ns | 终点数 |
|---|---:|
| [2.2, 2.4) | 528 |
| [2.4, 2.8) | 3（实测确有空洞） |
| [2.8, 3.3) | 16 |
| [3.3, 3.8) | 561 |
| **[3.8, 3.9)** | **1913** |
| [3.9, 4.0) | 1463 |
| [4.0, 4.1) | 31 |

**这 1.77 ns 的跨度是本阶段最有决策价值的一条**：同一个起点既产生 2.25 ns 的路径、也产生
4.02 ns 的路径 ⇒ 它们共享的那段前缀**至多 2.25 ns**，其余差全是各自的尾巴。
⇒ **在共享前缀上插一级寄存器，整组终点会一起平移**，平移量 = 切点之前那半段的延时。
要把最差从 4.0190 压到 3.3333 需平移 **0.686 ns** ⇒ 切点必须落在前缀中**靠后**的位置
（前面留 ≥0.686 ns，后面留 ≤ 3.3333 − 尾巴）。

⇒ 这与"修一条换一条"完全不同：**这是一个单点、整组受益的切口**。代价是共享前缀上**增加一拍
延迟**（load 交付 → CDB → 唤醒这条回环变长一拍）——那是 IPC 的账，不是频率的账。

##### 四、路径归因（`pathsrc.py` 位置 join，86122 个 cell 类型逐个相同 ✓）

`timing.rpt` 第 0 条：**109 级**，`_165976_` → `_166762_`。

| 端 | cell | 类型 | 同 src 连续段 | RTL |
|---|---|---|---|---|
| 起点 | `_165976_` | `DFFHQNx1` | 1336 个（第 1289） | `core/lsq.v:165.5-228.8` |
| 终点 | `_166762_` | `DFFHQNx1` | 32 个（第 30） | `front/fetch.v:191.5-194.8`（`pc_r`） |

⇒ 跨域回环：**LSQ 阵列 → … → `pc_r`**，109 级 / 36.5 ps per 级 / 扇出税 0。
※ `pathsrc` 报的行号属于**变体树内那份 RTL**（= HEAD）；工作区那份 `lsq.v` 已被 S1 改过、
行号不同，两者不可混用。

##### 五、S1 + C1 的状态（工作区，未提交）

| 项 | 值 | 口径 |
|---|---|---|
| `c1s1`（S1+C1，官方流程） | 12.1416 → **11.7666 ns**（−3.1%），面积 8,214.43 µm² | 官方参数，**在范围内** |
| 分解 | healthy 85级/3.9733 → 75级/4.0047 ns；hot 8.0975 → 7.7147 ns | ⇒ 收益**全部**是 0.38 ns 的扇出税 |
| 在 `-constr` 下的效果 | **未测** | 唯一的两点对比被 `-D` 混淆，已作废 |
| IPC | **未测** | — |

⇒ S1+C1 的**收益是实测的**（−3.1%），但**代价未测**（IPC）。按计划 §2C 的三条判据
（周期↓ / IPC 不退化 / 面积不越档），**第 2 条缺证**。本轮不据此推进。

##### 六、本轮修订的文档

1. **§15.10.31 二.1 证伪并更正**：`AOI21xp33` 的函数是 `!(B + A1·A2)`，`A1`/`A2` 对称
   ⇒ 引脚名**不携带**"选择端/数据端"信息。热网其实是一批**共享中间文字**（由 `XNOR2xp5`/
   `OR2x2` 驱动），真正的数据位是那些低扇出的触发器兄弟网。§15.10.30 三.2 的 4:2:1 指纹是巧合。
2. **§15.10.31 二/三/四 相应加注**，定位规则升级为"看驱动源 + 看低扇出兄弟 + 看位置，
   **不许用引脚名/扇出数/比值**"。
3. **§15.10.32 ③④ 与 六**：写入范围裁定，删掉"`-D` 需要重扫"的待办。

##### 七、下一步（本轮**未执行**）

按 三 的算术，切口在**共享前缀靠后处**（`lsq` 阵列 → `pc_r` 这条回环的完成侧），
候选仍是计划 §2B 的 **C3**（CDB 载荷寄存 + 唤醒/旁路同时后移）。
~~**动刀前必须先补 S1+C1 的 IPC**~~ → **已补，见 §15.11：−6.06%，S1+C1 已回滚。**

---

### 15.11 S1+C1 判定回滚 · 拆半对照 · `ipc6` 口径修复（2026-09-30）

本轮的全部改动**没有一行留在 RTL 里**（见 五），留下的是一条可以提前算账的**架构事实**（见 二）。

##### 一、S1+C1 的判定：−3.1% 周期换 −6.06% IPC，回滚

`runs/c1s1`（HEAD RTL + `ic1k` 参数 + I-cache，`LATENCY=10`）补测六个官方用例，
与 `runs/ipc_base16`（同参数、同 filelist、同机 Verilator）逐案对照：

| 用例 | 基线拍 | 仅 S1 | 仅 C1 | S1+C1 | ΔS1 | ΔC1 | ΣΔ | 实Δ |
|---|---|---|---|---|---|---|---|---|
| perf_median   |  18332 |  18885 |  18891 |  19525 |  553 |  559 |  1112 |  1193 |
| perf_multiply |  33228 |  33362 |  33362 |  33490 |  134 |  134 |   268 |   262 |
| perf_qsort    | 455496 | 471468 | 471467 | 486767 | 15972 | 15971 | 31943 | 31271 |
| perf_rsort    | 510959 | 531948 | 531948 | 552935 | 20989 | 20989 | 41978 | 41976 |
| perf_towers   |  15028 |  15620 |  15625 |  16220 |  592 |  597 |  1189 |  1192 |
| perf_vvadd    |   9173 |   9571 |   9572 |   9969 |  398 |  399 |   797 |   796 |
| **geo** | **0.4143** | **0.4014** | **0.4014** | **0.3892** | −3.11% | −3.12% | −6.21% | **−6.07%** |

**判定**：周期确实降了 3.1%（12.1416 → 11.7666 ns，82.36 → 84.99 MHz），但代价是 IPC −6.07%，
**六条全降**。82 → 85 MHz 离 300 MHz 门槛还差 3.5 倍，等于**一步都没靠近门槛就先把分丢了**
⇒ 按计划 Step 0.3 的判定门（IPC 退化 ≤0.5%）**否决**，`verilog/core/lsq.v`、
`verilog/core/mem_subsystem.v` 与 `tb/core/tb_lsq.v`（28a68e0 为 S1 同步改过 TB 的镜像逻辑）
一并回滚，工作区退到 `HEAD^`。复验：官方 `make test` **19/19**、单元 TB **16/16**（Icarus，退出码与 `ALL TESTS PASSED` 双条件）。

##### 二、拆半对照给出的**新结论**：这台机器的约束性递推是 **load 往返**

`runs/s1only` / `runs/c1only` 是只含一个 hunk 的两棵树（已按 RTL 内容与 `build/sim` 时间戳核对：
`ld_ptr_r` 命中数 14/0/0/14，`ld_a_c` 命中数 0/0/3/3，与名义一致）。结论有两条：

1. **两者各 −3.1%，且 geo 相同到小数点后四位**（0.4014 / 0.4014）。
2. **逐案代价相等**：ΔS1 与 ΔC1 在六个用例上分别差 **6、0、1、0、5、1 拍**（相对误差
   **0.00% ~ 1.07%**，且四个用例是 0.00%~0.25%），而 S1+C1 的实际增量≈两者之和
   （rsort/towers/vvadd 差 ≤3 拍；median/qsort 差 81/672 拍，即 6.8%/2.1%，是六条里仅有的两条
   非可加项 —— 幅度小且**方向不一致**，不足以动摇"两处无共同松弛量"的读法）。

S1 在**发起侧**加一级寄存器（`lsq` 的发起指针状态化），C1 在**交付侧**加一级寄存器
（`mem_subsystem` 的载荷寄存）—— 两者位置毫不相干，代价却逐案相同。唯一自洽的解释是：

> 两者都加在**同一条环路**（load 发起 → 访存 → 回 → CDB → 唤醒消费者 → 再发起）上，
> 且这条环路是这些程序的**约束性递推** —— 每绕一圈都被罚满，没有空隙可以吸收。

反证：若这条环路不是瓶颈（例如前端供得上、有空隙），多出来的一拍会被前端气泡吸收，
**两个不同位置的代价不可能逐案相等**；而 S1+C1≈Σ 说明两处**没有共同的松弛量**可分。

**对 Step 3 的直接约束（可以提前算清的账）**：

- 落在这条环路上的寄存器，**位置无关，代价都是 ~3.1% IPC / 拍**。计划 §2B 的
  **C2**（`merge_byte_f` 载荷合并寄存）与 **C3**（CDB 载荷寄存）**都在这条环路上**
  ⇒ 各自预计 −3.1%，**不必每项都跑一遍才知道**（跑一遍只为确认，不是为发现）。
- 落在环路**之外**的切割（fetch 侧、AXI 握手侧）预计 IPC 代价接近 0。

##### 三、`-constr` 下这笔账完全不同（本轮不动，但判据要写下来）

同样是 −3.1% IPC 的代价，在两个流程里买到的距离**差一个数量级**：

| 流程 | 当前 | 门槛 3.3333 ns 差 | 一刀 3.1% 买到 | 值不值 |
|---|---|---|---|---|
| 官方 | 12.1416 ns | **−72%** | 0.375 ns（占缺口 4.3%） | 不值（82→85 MHz） |
| `-constr` | 4.0195 ns | −17%（0.686 ns） | 0.124 ns（占缺口 18%） | 方向对，但单刀不够 |

⇒ **判据不是"这一刀值不值"，而是"这一刀之后离 300 MHz 还差多少"**。回滚 S1+C1 是因为它在
官方流程里买的 3% 频率一步都没靠近门槛；同样的刀若出现在 `-constr` 的缺口里就是明确该留的。
这条判据随 `-constr` 存在与否而变，但下面这条纪律不变。

**同时注意一个尚未证实的预期**：C1 切的是 `mem_subsystem` 的交付侧，而 `-constr` 的关键路径是
`lsq.v:165-228 → fetch.v:191-194 (pc_r)` —— **C1 很可能根本不在这条路径上，在 `-constr` 下买不到
周期**。这正是"S1+C1 只按官方流程判、在 `-constr` 下从没量过"遗留的盲区，也是 §15.10.33 新增的
"每个候选两边各综合一次"纪律要防的误判：只按官方判会高估它，只按 `-constr` 判会当成废刀。

##### 四、口径修复（本轮唯一的遗留产物）

1. **`results.csv` 的 `ic1k` 行**：`ipc6` 由 ROB=32 的错值 `0.3427,...,0.5110` 改为 ROB=16 实测
   `0.3797,0.6537,0.3071,0.3830,0.3512,0.4932`（geo **0.4143**），由 `runs/ipc_base16` 免重建复认
   （`--sim runs/ipc_base16/build/sim`，未重编译），且与 `base16syn`/`abc6`/`abc34` 三行既有值**逐位一致**。
2. **`constr1` 行**同因同改（其 RTL 与 `ic1k` 逐字相同，继承了这个错值）。
3. **`c1s1` 行**补 `ipc6` = `0.3565,0.6486,0.2874,0.3540,0.3254,0.4538`（geo 0.3892）+ 回滚记录。
4. **全表 27 行逐列复核**：`ic1k`/`constr1` 是**唯一**两处参数与 `ipc6` 不同源的行（已闭合）；
   其余行 `ipc6` 与 `params` 对得上。`tools/README.md` 坑 10 **结案**（保留教训：`snap.py` 的
   `--ipc` 是手抄的，不校验机器）；§15.10.26 二.2 **结案**。
5. **I-cache 归因随之修正（结论加强，不改变方向）**：与 `hd16`（ROB=16，geo 0.3459）对照，
   I-cache 的 geo 收益是 **×1.198（+19.8%）**，逐案 median +55.8% / qsort +26.6% / multiply +19.0%
   / towers +18.9% / rsort +5.6% / vvadd +0.2%。原记的 "+40.6% / +3.8%" 是拿 ROB=32 的
   `ipc6` 比出来的，作废。**"I-cache 的收益是容量不是延迟"这个结论因此更强**：收益集中在
   足迹最大的 median/qsort，而 vvadd（足迹最小）几乎为零。

##### 五、本轮收尾状态

- 工作区 = `HEAD^`（S1+C1 那三个文件全部回滚），无未提交 RTL 改动。
- 门禁复验：官方 `make test` **19/19**；单元 TB **16/16**（Icarus，正确性签署方；含 `tb_icache`/`tb_mem_axi`）。
- 测量树 `runs/ipc_base16`（基线）、`runs/s1only`、`runs/c1only`、`runs/c1s1` **只有 IPC，没有综合
  产物** ⇒ **不进 `results.csv`**（该表每行都要有面积/周期，缺列的行会污染口径）；数据落在本节表格里。

##### 六、喂给下一步

- **Step 1（气泡归因）**照原计划做，但多了一个已知答案：load 往返是**约束性递推**，
  所以 `STALL` 分类里看不到它（它不是"挡"出来的，是**串行延迟**）。归因表要专门加一列
  "发射拍 IPC"，才能把这类延迟和前端饥饿区分开。
- **Step 3（拆流水）**的账已经能提前算：环路内 −3.1%/拍，环路外 ≈0。选刀时**先问它在不在环路上**，
  再问它离门槛有多远。

---

### 15.12 Step 1：官方 `perf_*` 六点的气泡归因（2026-09-30）

§15.11 末尾要求"归因表要专门加一列'发射拍 IPC'"，本节照做。**结论分两类，且两类的病根完全不同**。

##### 一、口径与工具（先说清这台机器不是官方那台）

- **程序**：`testcases/perf_*/program.data` → `tb/top/prog/perf_*.data`（6 个，新增）。
  转换只有一件事：**去掉首行 `# Generated from...`**（`$readmemh` 不认 `#`）；字节与 `@地址` 原样保留，
  已按 token 逐字节复核与源一致（含 `@` 行）。
- **停机**：官方镜像**没有** `TERM_RAW`（`addi a0,x0,255`），只靠 `sw a0,0(t0)`（t0=0x80000000）
  加一句自循环。查 `cpu_top.v:852-857` 发现 RTL **本来就实现了**这个判据
  （`sw_valid && sw_ready && sw_addr==MMIO_EXIT_ADDR && sw_width==2'b10`，与从机判据一致）
  ⇒ 六个程序全部正常停机，**不需要 `+PERF=N` 兜底**（计划里预留的那条退路没用上）。
- **唯一改的 RTL**：`verilog/core/memory.v` 的 store 路径加 `&& (sw_addr < MEM_SIZE)`。
  那条 MMIO store 的地址 0x80000000 远超 TB 的 256 KiB 阵列，原先会越界索引 `mem[]`。
  该文件 `filelist.f:5` 明写"保留在列表里供 TB 复用, student_top 不再例化它"，
  `hierarchy -top student_top` 会剪掉 ⇒ **综合面积零影响**（见 §15.13 若有复测）。
- **两档配置**：`LATENCY=3`（TB 缺省，`sim/bench/`）与 `LATENCY=10`（对齐官方，`sim/bench10/`）。
  两档都**不含 I-cache**（TB 直连 `cpu_top` + `core/memory.v`），`ROB=32/RS=16/LSQ=16`（TB 缺省）。
  官方是 `ROB=16` + I-cache + AXI。**这台机器不是官方那台**，下面的绝对值只用于定位病根，
  **不可与 `results.csv` 的 `ipc6` 并列**。

##### 二、总表（`LATENCY=10`，对齐官方口径）

| 程序 | 拍 | 提交 | IPC | 发射拍 | 空转 | 冲刷 | 缺批 | 结构挡 | 误预测 |
|---|---|---|---|---|---|---|---|---|---|
| perf_median   |  18021 |   6961 | 0.3863 | 10863 | 3902 |  4543 | 2610 |     5 |   548 |
| perf_multiply |  32693 |  21722 | 0.6644 | 22862 | 1140 |  2196 | 7624 |    11 |   864 |
| perf_qsort    | 433119 | 139884 | 0.3230 |248282 |108398|119553 |56244 |  9040 | 11104 |
| perf_rsort    | 437502 | 195719 | 0.4474 |195906 |  187 |   218 |35331 |206047 |    29 |
| perf_towers   |  11127 |   5278 | 0.4743 |  5867 |  589 |   858 | 1164 |  3238 |   254 |
| perf_vvadd    |   7846 |   4524 | 0.5766 |  4537 |   13 |    18 |  912 |  2379 |     7 |
| **geo** | | | **0.4652** | | | | | | |

（geo 0.4652 vs 官方 `ipc_base16` 的 0.4143 —— 差在 I-cache 与 ROB 尺寸，不是同一口径，勿混。
`qsort` 的提交数是 139884 而非 139900：halt 窗口截断在 ROB 排空期内，属口径噪声 ≤0.012%。）

**结构挡按资源细分**（`LATENCY=10`）：

| 程序 | 结构挡拍 | rob 满 | rs 满 | freelist 空 | lsq 满 |
|---|---|---|---|---|---|
| perf_qsort  |   9040 | 7370 | 1541 | 0 |  268 |
| perf_rsort  | 206047 |36843 |136457| 0 |   97 |
| perf_towers |   3238 |   10 |   75 | 0 | 3131 |
| perf_vvadd  |   2379 | 2373 |    0 | 0 |    0 |

##### 三、决策门的答案：**两类程序，两种病根**

- **A 类（median / multiply / qsort）：前端**。结构挡 ≈ 0（qsort 2.1% 除外）。
  主项是 **冲刷恢复**（median 25.2% / qsort 27.6%）与 **缺批**（multiply 23.3% / median 14.5%）；
  `qsort` 另有 **25.0% 的空转**（有批、能发射、但没有就绪指令）。
  ⇒ 这一类的下一步是 **Step 2（分支预测 + 取指供给）**，不是拆流水。
- **B 类（rsort / towers / vvadd）：结构挡 29%~47%**。
  rsort 是 **RS 满**（136457 拍，占其运行时间 31%）；towers 是 **LSQ 满**（97% 的结构挡）；
  vvadd 是 **ROB 满**（100%）。
  ⇒ ~~这一类的下一步是**容量 / 访存并行度**~~ —— **此处当场的读法是错的，已由 §15.13 证伪**：
  加容量对这四条一律无效（geo 全放大 −2.7%），结构挡只是 load 延迟的**记账**。
  B 类的解同样在**缩短 load 往返**，与 A 类同源。**先看 §15.13 再引用本节。**

**这与 `LATENCY=3` 的结论完全不同**（L=3 时结构挡对六条里有五条是 0）：
**结构挡是"延迟足够长"才显形的**，而官方口径恰恰是 L=10 ⇒ 一切容量结论必须在 L=10 下做。

##### 四、B 类结构挡的性质 —— **已由 §15.13 证实并结案**

当时的读法是"B 类结构挡很可能不是真容量不足，而是 **load 延迟的代理**"。
**§15.13 的容量消融已证实这一读法**：把 `ROB/RS/LSQ/PRF` 放大到 128/64/64/256，
结构挡会"换人"甚至清零，**但总拍数不动或变差**（geo 0.4652 → 0.4525）。
⇒ 结构挡是**记账**不是原因，**B 类的解不在容量上**。详见 §15.13 二/三。

##### 五、误预测按类（Step 2 的输入）

`bin_f` 把控制转移分 7 类（0=jal 1=ret 2=其余 jalr 3=beq 4=bne 5=其余条件 6=非控制）。
`LATENCY=10` 下的绝对数：

| 程序 | jal | ret | 其余 jalr | beq | bne | 其余条件 |
|---|---|---|---|---|---|---|
| perf_median   | 0 |   2 |   2 |    0 |    5 |  539 |
| perf_multiply | 0 | 101 | 101 |  556 |  105 |    1 |
| perf_qsort    | 0 |   3 |   2 | 1334 |    1 | 9764 |
| perf_rsort    | 0 |   2 |   2 |    1 |   11 |   13 |
| perf_towers   | 0 |  70 |  69 |  103 |    9 |    3 |
| perf_vvadd    | 0 |   1 |   1 |    0 |    4 |    1 |

两条**稳健**读数（两档配置下都不变，故可信）：

1. **`其余条件`（bxx）在 median/qsort 上压倒性**（539/548、9764/11104）—— 这是 Step 2 的主战场，
   与 `docs/plan.md:114-140` 的旧结论（`bxx` 59.2%）方向一致。
2. **`ret` 与"其余 jalr"的误预测数几乎恒等**：2/2、101/101、3/2、2/2、70/69、1/1 —— **六个程序全中**。
   这两个 bin 是**不同的指令**（`jalr x0,0(x1)` vs 其余 jalr），误预测原因也不同
   （前者是 RAS 目标错，后者是"非 ret jalr 一律预测不跳"⇒ 必错）。它们**成对出现**，
   最自然的解释是**间接调用/返回配对**：每个间接调用（jalr）配一个 ret，RAS 两端一起错。
   ⇒ **Step 2c 的根因排查应当从这里入手**，而不是先怀疑 RAS 深度。

⚠ **两处口径警告**：① `bin_f` 归因用的是 `rob_raw_w[misp_fs_w]`，`misp_fs_w` 指向的槽若已被覆盖，
分类会串味 —— 这解释了为什么同一程序在两档延迟下 per-class 数会变（qsort 的 beq 846→1334，
总数 10428→11104）。**只有上述两条（两档都不变的）可以当结论**，逐类绝对值不能。
② `kj[]`（`taken`）计的是 **fetch 的预测取跳**次数，不是实际取跳次数，故 `misp/taken` **不是**误预测率；
本表的 `ret` 一行里 `misp≈taken` 恰好说明"凡预测取跳的 ret 几乎都错了"，但 `其余 jalr` 的
`taken=0` 而 `misp>0`，比值无意义。

##### 六、本轮新增/改动的文件

- `tb/top/prog/perf_{median,multiply,qsort,rsort,towers,vvadd}.data`（新增，由
  `testcases/perf_*/program.data` 去掉 `#` 行生成，可一条命令重建）
- `verilog/core/memory.v`：store 越界丢弃（TB 专用，综合剪除）

---

### 15.13 容量消融：**结构挡是"延迟的记账"，不是容量不足**（2026-09-30）

§15.12 四留下的未验证读法，本节跑完对照并**正式确认**。结论：**结构容量不是 IPC 瓶颈，
加容量买不到 IPC，全放大反而更差**。方法：`LATENCY=10` 下分别放大单一结构 + 全放大，
其余不动（六条 `perf_*`，提交数在五个变体间**逐条完全一致** ⇒ 程序做的是同样的活）。

##### 一、总拍数 / IPC（括号内 IPC）

| 变体 | median | multiply | qsort | rsort | towers | vvadd | **geo** |
|---|---|---|---|---|---|---|---|
| 基线 L10 | 18021 (.3863) | 32693 (.6644) | 433119 (.3230) | 437502 (.4474) | 11127 (.4743) | 7846 (.5766) | **0.4652** |
| RS=64   | 18021 (.3863) | 32693 (.6644) | 433414 (.3227) | 437602 (.4473) | 11138 (.4739) | 7846 (.5766) | 0.4651 |
| LSQ=64  | 18021 (.3863) | 32693 (.6644) | 433122 (.3230) | 437506 (.4474) | **10948 (.4821)** | 7846 (.5766) | 0.4665 |
| ROB=128 | 18021 (.3863) | 32693 (.6644) | 436078 (.3208) | 437492 (.4474) | 11127 (.4743) | 7824 (.5782) | 0.4649 |
| 全放大  | 18021 (.3863) | 32693 (.6644) | **440554 (.3175)** | 437772 (.4471) | **13100 (.4029)** | 7736 (.5848) | **0.4525** |

（全放大 = `ROB 32→128, RS 16→64, LSQ 16→64, PRF 64→256`。）

**median / multiply 在五个变体下逐拍完全相同** —— 它们本来就没有结构挡，是纯前端程序（见 §15.12 三）。
其余四条：**放大容量要么不动、要么变差**，geo 全放大 **−2.7%**。

##### 二、结构挡"换人"：堵住一个，下一个顶上

| 程序 | 基线 | RS=64 | LSQ=64 | ROB=128 | 全放大 |
|---|---|---|---|---|---|
| qsort  | 9179 (rob:7370) | 8690 (rob:8389) | 9169 (rob:7622) | 4784 (lsq:2876) | **158** (rs:158) |
| rsort  | 173397 (rs:136457) | **208034 (rob:202946)** | 173369 (rs:136483) | 161101 (rs:160985) | 164730 (rs:164730) |
| towers | 3216 (lsq:3131) | 3228 (lsq:3159) | 2453 (rs:1564) | 3207 (lsq:3131) | **0** |
| vvadd  | 2373 (rob:2373) | 2373 (rob:2373) | 2373 (rob:2373) | 2348 (lsq:2348) | 2277 (rob:2277) |

**rsort 是最刺眼的一条**：RS 从 16 加到 64，`rs 满` 从 **136457 拍归零**，代价是
`rob 满` 从 36843 涨到 **202946** —— **总拍数纹丝不动（437502 → 437602）**。
若 RS 容量是真瓶颈，136457 拍的解阻塞不可能一点收益都没有。⇒ **它是记账，不是原因。**

##### 三、判决性证据：towers 的"三种记账"迁移

全放大把 towers 的结构挡**清零**（3216 → 0），总拍数却 **+17.7%**（11127 → 13100）：

| towers | 发射拍 | 冲刷 | 缺批 | 结构挡 | 提交 |
|---|---|---|---|---|---|
| 基线 | 5867 | 858 | 1164 | 3216 | 5278 |
| 全放大 | **8624 (+2757)** | **3662 (+2804)** | 809 (−355) | **0 (−3216)** | 5278 |

**提交数一样（5278），多出来的 2757 个发射拍全是无效功**：更深的机器把错误路径取/执行得更远，
于是冲刷的账也更贵（+2804）。结构挡消失的每一拍，都以"空转 + 冲刷"的形式等量甚至超额还了回来。

⇒ **"结构挡"这个分类从来不是真正的原因，它只是"机器在等的时候，指令堆在哪里"的一种记账方式。**

##### 四、正式确认：接下来要突破的 IPC 瓶颈（按可攻击性排序）

1. **load 往返延迟 —— 统一病根**。三重独立证据：
   ① `LATENCY 3→10` 多 7 拍，六条里五条 IPC 掉 25%~34%（每拍 4~6%，`multiply` 免疫，是天然对照组，§15.12）；
   ② 官方配置上 S1/C1 各给往返加一拍，各 −3.1%（§15.11）；
   ③ 本节：加容量买不到任何东西。
   它在 A 类表现为**空转**、在 B 类表现为**结构挡** —— 同一件事的两种记账。
2. **分支误预测**。冲刷占 median 25.2% / qsort 27.6%，且**放大容量会把它加重**（towers +2804、
   qsort +7591）—— 是唯一"越深越痛"的独立项。⇒ **Step 2 方向确认无误。**
3. **取指供给**。`multiply` 的缺批占 23.3%，是它唯一的大项（它结构挡 0、冲刷仅 6.7%）。

##### 五、对计划的修订

- **Step 2（分支预测）**：确认是正确方向，且优先级高于任何容量调整。§15.12 五 的两条稳健读数
  （`bxx` 压倒性、`ret` 与"其余 jalr"成对误预测）直接喂给它。
- **Step 3（拆流水）**：账更严峻。load 往返既然是**约束性递推**（§15.11），凡是切在这条环路上的
  寄存器都要付 **3~6% IPC / 拍**。选刀必须**先问在不在环路上**，再问离 300 MHz 多近。
- **容量调整（ROB/RS/LSQ/PRF）**：**从候选表里划掉**。本节证明它买不到 IPC，而且面积是要计分的
  （`docs/area_budget.md`）—— 是纯亏。§15.10.23 那条"五轴增益 −0.0001"由此得到机制解释。
- **未做、留给下一步**：`空转`里 load-use 与"其他长延迟（乘除）"各占多少尚未拆开；
  `ISSUE_WIDTH=1→2` 是本仓库已测过的最大单点 IPC 杠杆（multiply +23.5% / qsort +22.6%），
  但代价是面积，本轮**未在本 bench 口径下复测**，不作结论。

---

### 15.14 回滚 walker 并行化 (`ROLLBACK_WIDTH`) + 两项零 RTL 测量（2026-10-01）

本轮三件事：① **作废**上一轮 W 扫描的错口径数字并重建对照；② 两笔零 RTL 测量（A1 冲刷气泡 +
错路长度直方图、A2 D-cache 命中率离线模拟）；③ 落地 `ROLLBACK_WIDTH` 参数化，量出宽度扫描曲线。

#### 一、口径修正：上一轮的 W 扫描作废，重建四棵对照树

上一轮在 `runs/rw4` / `runs/rw8` 上量得 geo 0.4428 (+6.9%) / 0.4471 (+7.9%)，**作废**。原因：
`tools/run.sh` 只给命令行上显式列出的参数打补丁，其余取**工作区默认值** ⇒ 那两棵树实际是
`ROB=32 / RS=16 / BHT=32 / RAS=8 / SQ=8 / WR=8`，而基线 `ic1k` 是 `ROB=16 / RS=4 / BHT=8 /
RAS=4 / SQ=4 / WR=4`；且它们的 filelist 是**过期的** `filelist_t4tmp.f`（不含 `core/icache.v`，
而 `mem_subsystem` 例化它 ⇒ 那两棵树的综合根本跑不出来）。旁证：rw4 的 rsort 0.3910 / vvadd
0.5110 与归档的 ROB=32 基线逐位重合。

重建 `runs/rw{1,2,4,8}ic`（`--filelist=docs/timing/filelist_ic.f` + 显式写全六个 ic1k 参数），
四棵树互相**只差 `student_top.v` 里 `parameter ROLLBACK_WIDTH` 那一行**（`diff -rq` 验证）。

**锚点**：W=1 的官方 IPC **逐位复现基线** `0.3797,0.6537,0.3071,0.3830,0.3512,0.4932`（geo **0.4143**）
⇒ 新树、新 filelist、含参数化的 HEAD RTL 在 W=1 下与归档基线行为完全相同，W>1 的差可干净归给
这一根变量。

#### 二、A1：ic1k 口径的冲刷气泡与错路长度

**口径声明**：TB 直连 `cpu_top`（**无 I-cache**），参数覆盖到 ic1k 的重命名/分支配置
（`ROB=16 / RS=4 / BHT=8 / RAS=4 / LSQ=16 / PRF=64`），`MEM_LATENCY_TB=10`，W=1。
⇒ `nobatch` 被**高估**（I-cache 缺席），但 `flushcyc` 与误预测分布由 BHT/ROB 决定、**不受 I-cache
影响**，这两项可用。覆盖法：`iverilog -P` / `verilator -pvalue+` 覆盖 TB 参数（TB 头注释已载明）。

| 程序 | 总拍 | 发射 | 缺批 | **冲刷** | 冲刷占比 | `rs 满` | 误预测 |
|---|---|---|---|---|---|---|---|
| median | 16293 | 8826 | 2482 | **2535** | 15.6% | 1883 | 576 |
| multiply | 32701 | 22870 | 7627 | **2202** | 6.7% | 0 | 864 |
| qsort | 405900 | 209113 | 61893 | **80229** | **19.8%** | 30243 | 10887 |
| rsort | 443755 | 195782 | 50244 | **104** | 0.02% | 127455 | 34 |
| towers | 11575 | 5704 | 1032 | **716** | 6.2% | 3044 | 254 |
| vvadd | 7858 | 4539 | 616 | **19** | 0.2% | 2086 | 7 |

**错路长度 R 直方图**（R = 冲刷首拍读 FSM 的 `walk_ptr_r - flush_fs_r + 1`，按 `RW` 位**模**运算 ——
`set_last` 已把 `rob_last` 截到 `misp_fs_w+1`，跨 0 回绕时 32 位减法会给出负数）：

| 程序 | R=1 | R=2 | R=3 | R=4 | R=5-8 | R=9-16 | ΣR | ΣR/误预测 | ΣR vs 实测冲刷 |
|---|---|---|---|---|---|---|---|---|---|
| median | 97 | 120 | 1 | 122 | **236** | 0 | 2438 | 4.23 | −3.8% |
| multiply | 202 | 300 | 259 | 100 | 2 | 1 | 2000 | 2.31 | −9.1% |
| qsort | 132 | 1170 | 589 | 175 | **4323** | **4498** | 80097 | 7.35 | −0.1% |
| rsort | 10 | 6 | 6 | 8 | 4 | 0 | 94 | 2.76 | −9.6% |
| towers | 39 | 119 | 20 | 59 | 14 | 3 | 677 | 2.66 | −5.4% |
| vvadd | 2 | 2 | 2 | 0 | 1 | 0 | 17 | 2.42 | −10.5% |

三条读数：

1. **W=1 时一次误预测恰花 R 拍**（1 拍检测 + R−1 拍逐条撤），故 ΣR 应与实测冲刷拍数相等。
   在两个冲刷大户上成立（qsort −0.1%、median −3.8%，二者合计占全部冲刷拍的 **96.7%**）；
   其余四条差 −5%~−10%，方向一律是"实测 **大于** ΣR" —— 机制是**冲刷中途又冒出更老的误预测**
   （`misp_older_w` 扩展 `flush_fs_r`），首拍记下的 R 捕捉不到这部分，程序越密集越明显（multiply
   864 次误预测最密），绝对量越小百分比越晃（vvadd 只有 19 拍）。
2. **直方图总项数与 `misp` 逐条相等**（576 / 864 / 10887 / 34 / 254 / 7）—— 记账完整，无漏采。
3. **R 的分布在两条大户上是重尾**：qsort **81%** 的误预测 R≥5（4323 + 4498），median 41% 落在 R5-8；
   其余四条集中在 R≤4。这直接预告了 walker 并行化的收益**只可能**来自 median 与 qsort。

#### 三、A2：D-cache 命中率离线模拟（零 RTL、零面积）

TB 落地址流（`+LTRACE=1` → `sim/ltr_<prog>.txt`，只记**被接受**的 load 与**真正落盘**的 store，
MMIO 停机写已剔除），`tools/dcache_sim.py` 离线扫 容量×相联度×行大小，并用官方实测的
"延迟→IPC"曲线（LATENCY 2..10，§15.13 前的六点表）插值出预估 IPC。

**工作集极小**（这是本节最硬的一读数）：

| 程序 | 访问数 | 触及 16B 行 | 工作集 |
|---|---|---|---|
| median | 2461 | 302 | 4.7 KB |
| multiply | 518 | 103 | 1.6 KB |
| qsort | 56431 | 1030 | 16.1 KB |
| rsort | 66584 | 1605 | 25.1 KB |
| towers | 3184 | 22 | **0.3 KB** |
| vvadd | 1500 | 300 | 4.7 KB |

| 配置 | geoH | L_eff | 预估 IPC | vs 0.4143 |
|---|---|---|---|---|
| 8KB 2路 64B | 0.968 | 2.26 | 0.5611 | **+35.4%** |
| **4KB 2路 64B** | 0.956 | **2.35** | **0.5588** | **+34.9%** |
| 1KB 2路 64B | 0.930 | 2.56 | 0.5536 | +33.6% |
| 2KB 1路 64B | 0.916 | 2.67 | 0.5509 | +33.0% |
| 1KB 1路 16B | 0.809 | 3.53 | 0.5313 | +28.2% |
| （全命中上界 = `LATENCY` 10→2） | 1.000 | 2.00 | 0.5674 | +37.0% |

`L_eff = H×2 + (1−H)×10`。**1KB 就吃掉上界的 91%，4KB 吃到 94%，8KB 到 96%** —— 边际收益
在 1KB 之后迅速消失，与工作集表一致。

**局限（结论必须带上这几条）**：① `hit=2` 取自官方 `LATENCY=2` 那个**全命中上界实测点**，不是真实
cache 的 tag+data 拍数；② `L_eff` 用算术平均代替真实 MLP 动态 —— 本核 `LD_INFLIGHT=8`，多个 miss
会重叠，故这是**保守的一阶估计**（真实收益通常好于此）；③ trace 里 load 按发射序、store 按提交序，
与程序序不完全一致；④ trace 来自 TB（无 I-cache），曲线取自官方运行 ⇒ 只借它做 IPC 映射。
⇒ **A2 的结论是"这个方向值得投"，不是"投下去就有 +35%"。**

**补测（同日；上面那两张表里有三处乐观假设，补掉后结论缩水但方向不变）：**

**(1) store 策略。** 原表默认"写分配+写回"。把"store 提交怎么动缓存"显式建模后
（`tools/dcache_sim.py` 的 `STORE_POL`）：

| store 策略 | geoH | L_eff | 预估 IPC | vs 0.4143 |
|---|---|---|---|---|
| `alloc` 写分配+写回（原表口径） | 0.956 | 2.35 | 0.5588 | +34.9% |
| **`update` 写直达 + 命中按字节更新 + 未命中不分配**（现实实现） | **0.841** | 3.27 | 0.5368 | **+29.6%** |
| `wbinv` 写直达 + 命中**失效整行** + 未命中不分配 | 0.670 | 4.64 | 0.5078 | +22.6% |

⇒ 原表高估 11.5 个千分点。`update` 与 `alloc` 的差全在"store 未命中要不要顺带取行"；
**`wbinv` 崩掉 17 个点**说明**写更新远比写失效值钱** —— qsort/rsort 的 load 与 store 打在同一批
数组元素上，失效等于把刚取回来的行白扔。⇒ store 必须做字节掩码写更新（`sram_fakeram` 的
`WRITE_GRANULARITY` 可到 1 bit，硬件上做得到）。

**(2) 取行流量 —— 原表完全没给 AXI 读通道记账，而这才是真正的约束。**
官方从机口径（[scripts/sim.cpp:100](../scripts/sim.cpp#L100)：`arready = !reset && ar.size() < DEPTH(=16)`，
`step()` 每拍至多 `read()` 一笔）⇒ **AR 通道硬上限 1 笔/拍**，且每笔 AR 只回 4 字节
⇒ 取一行要发 `行字数` 笔 AR。算"取行 AR 拍数 ÷ 基线总拍数"（基线恰好每 load 1 笔 AR）：

| 程序 | 基线拍 | 16B 行 | 32B 行 | 64B 行 |
|---|---|---|---|---|
| perf_median | 16293 | 17% | 27% | **47%** |
| perf_multiply | 32701 | 3% | 4% | 7% |
| perf_qsort | 405900 | 3% | 3% | 3% |
| perf_rsort | 443755 | 14% | 23% | **42%** |
| perf_towers | 11575 | 4% | 7% | 14% |
| perf_vvadd | 7858 | 31% | **46%** | **77%** |

`vvadd` 在 64B 行下**取行 AR 拍数（6032）就已接近基线总拍数（7858）** ⇒ 不是"收益变小"，是
**物理上跑不过基线**（分母还会因缓存而变小，占用率只会更难看）。rsort 42% / median 47% 同量级偏高。
⇒ **行越大命中率越高，但取行流量按行字数线性涨** —— 这是 A2 原模型整条缺失的轴。

**(3) 字粒度缓存已出局**（无行、无填充 FSM、无 `ld_busy` 阻塞、AXI 流量还不增，本该最省事）：
`vvadd` 1200 个 load 全落在 **1200 个不同字**上（零重访）、`multiply` 重访率 0.010
⇒ 空间局部性只能靠"整行取回"吃到，字粒度两头不占，六条程序 geoH **恒为 0.000**。

**修正后的结论**：D-cache 仍是下一轮该投的方向，但预期从 **+34.9% 下修到 +25~30%**，且设计必须
**带宽感知**：① 行取 16B/32B 量级（不是 64B）；② 取行不得让需求 load 排队（需求优先 / 后台节流填充）；
③ store 写更新、不写失效。**把最悲观的一条（`vvadd` 一分不赚）也算进去**，geo 仍有
**0.5214（+25.9%）** —— 仍是 walker 那 +3.45% 的 8 倍。

#### 四、Step B：回滚宽度扫描（官方 `make perf LATENCY=10`，六点全部自带正确性校验）

| `ROLLBACK_WIDTH` | median | multiply | qsort | rsort | towers | vvadd | **geo** | Δ |
|---|---|---|---|---|---|---|---|---|
| 1（基线） | 0.3797 | 0.6537 | 0.3071 | 0.3830 | 0.3512 | 0.4932 | **0.4143** | — |
| 2 | 0.3968 | 0.6556 | 0.3319 | 0.3830 | 0.3520 | 0.4932 | **0.4232** | +2.15% |
| 4 | 0.4036 | 0.6566 | 0.3448 | 0.3830 | 0.3525 | 0.4932 | **0.4273** | +3.14% |
| 8 | 0.4052 | 0.6566 | 0.3497 | 0.3830 | 0.3525 | 0.4932 | **0.4286** | +3.45% |

增量 `1→2: +0.0089`、`2→4: +0.0041`、`4→8: +0.0013` —— **严格递减**，W=4 已吃到 W=8 收益的 **91%**。

- 收益**全在 median（+6.7%）与 qsort（+13.9%，W=8）**；`multiply` / `towers` 在 W=4 饱和。
- **`rsort` 与 `vvadd` 逐位不动** —— 它们是天然的**阴性对照**：A1 量出这两条只有 34 / 7 次误预测，
  且 `rsort` 的 443755 拍里有 127455 拍是 `rs 满`。这条与 §15.13 "结构挡是记账不是原因" 相互印证：
  walker 削的是"冲刷恢复"，对没有冲刷的程序一分不给。

**RTL 改动**（新增**独立**参数 `ROLLBACK_WIDTH`，与 `ISSUE_WIDTH` **解耦** —— 发射宽度决定"一拍
进多少"，回滚宽度决定"一拍退多少"，二者最优值本就不同）：

| 文件 | 改动 |
|---|---|
| `cpu_top.v` | 加 `parameter ROLLBACK_WIDTH = 4`；walker `generate` 上界、`walk_done`、`walk_ptr_r` 递减步长、`walk_idx_w`/`walked_valid`/`wlk_push_preg`/`walk_flush_*`/`flclr_c` 按新宽度定标；commit 侧仍是 `ISSUE_WIDTH` ⇒ 零扩展到 `ROLLBACK_WIDTH` |
| `rat.v` | 加参数，**仅 flush 三端口**与 flush 循环上界按它定宽；rename 仍 `ISSUE_WIDTH` |
| `free_list.v` | 加参数，**仅 push 端口**按它定宽；pop 计数链仍 `ISSUE_WIDTH`，push 计数链拆出独立一条 |
| `student_top.v` | 加参数默认值并下传（`tools/run.sh` 的 sed 补丁锚点） |

三个守住的正确性点：① **同 rd 冲突的胜者顺序** —— `rat.v` 的语义是"槽序更老者赢"（walker 的 `jj`
递增 = 年龄递减），故只提高循环上界，**不改方向、不加 `break`**；② **free_list 写不越界** —— 由
`push_ok[k]` 门控写使能，安全性来自"归还数 == 之前弹出数"，与宽度无关；③ **`walk_ptr` 不跳过冲刷点**
—— 只在 `!walk_done`（`rem > ROLLBACK_WIDTH`）时才可能结束，`walk_ptr' = walk_ptr − W ≥ fs+1`。

**一处真回归（已修）**：`tb/core/tb_rat.v` 用 `IW=4` 驱动 flush 端口，而 `rat` 的 flush 端口宽度
现在是 `ROLLBACK_WIDTH`（**默认 1**）⇒ 端口被 Verilog **静默截断**成 1 位，"flush 多槽同 rd 更老赢"
用例恒等于只驱动 slot0，`5999 TESTS FAILED`。显式传 `.ROLLBACK_WIDTH(IW)` 后恢复
`ALL TESTS PASSED`。（注意与另一类**假**失败区分：TB 的 PRF 影子检查器原先只扫 `ISSUE_WIDTH_TB`
个 push 槽，而 walker 一拍归还 `ROLLBACK_WIDTH_TB` 项 —— 那是检查器局限，已同步加宽三处循环。）

**留待宽度定稿时再做的一件事**：`cpu_top.v` 里 `flclr_c` 仍是 `jj` **串行 OR 链**
（`flclr_c[jj] = flclr_c[jj-1] | flc_one`），宽度 ×4/×8 后链深跟着涨。改成把各槽 one-hot 直接
归约的**扁平 OR**（让综合器自己平衡树）能削这一段组合深度。**本轮没做**：它在判据上是纯时序项，
而本阶段综合暂停、且改它要重跑全部正确性 ⇒ 与宽度选点一起做。

#### 五、门禁与面积

- **IPC**：见上表，W=4 geo 0.4273 > 0.4143。✅
- **正确性**：`make -f Makefile.tb run` **16/16 全 `ALL TESTS PASSED`**（Icarus，签署方）；
  `make test`（官方 19 案例）在 W=4 上 **19 passed, 0 failed**。✅
- **面积/频率**：**本轮暂停**。助教方的综合脚本尚未定稿（`ACMClassCourse-2025/RISC-V-CPU-2026`
  至 2026-10-01 仍只有 initial commit，两分支的 `scripts/` 与本仓库副本逐字节相同），故宽度最终选点
  **待综合口径定下来后按 IPC/面积比决定**；暂定 W=4（吃到 W=8 收益的 91%，宽度只有一半）。
  `docs/timing/results.csv` 是**综合快照**表（列为 area/min_period/levels/hotnets），本阶段没有综合
  数字可填，故**不入档** —— 宽度扫描的实测 IPC 以本节表格为准；待宽度定稿时连面积一起补行。

#### 六、结论与下一步

1. **回滚并行化是确定性但小的一刀**：+3.45% 封顶（W=8），W=4 性价比最高。它只动"冲刷恢复"，
   对 `rsort`/`vvadd` 这种没有冲刷的程序**一分不给**。
2. **A2 把下一步指向 D-cache**：等效延迟 2.35 拍（4KB/2路/64B），预估 +34.9%，是 walker 的 **10 倍**；
   工作集只有 0.3–25.1 KB，1KB 就吃到上界的 91%。它是目前唯一能单方向把 0.41 往 0.6 推的杠杆。
3. **A1 顺带给 Step 2（分支预测）定量**：qsort 的重尾 R 分布说明"错路走得深"，而错路从哪来 ——
   §15.13 已定位 `bxx`；下一步该做的仍是压低**误预测次数**（R 分布管不了次数）。

### 15.15 D-cache 落地：`idxinv` 写策略 + 单 MSHR 合并 + 三路 AR 仲裁（2026-10-01）

#### 一、判据换版：为什么现在做

`docs/architecture.md` 旧文记的 D-cache 决策是「不做」，依据是上界实验：把 `LATENCY` 降到 2 拍
（比任何真实缓存都快）也只得 **0.5650**，而档 1 的地板是 **0.6000** ⇒ "整条存储方向的屋顶低于地板"。

**该判据是"够不够档 1"，本轮已换成"不固定面积上限、只求 IPC/面积 之比最大（面积 ≤ 档 3 的 36000 µm²）"**
（用户裁定）。现基线 `ic1k` = **8184.207 µm² / geo IPC 0.4143**，离 36000 还有 **4.4×** 面积余量，
而 0.5650 那个"上界"在新判据下**不再是否决理由**。旧文已划线留痕（`architecture.md:355`）。

同时，旧决策里记的 store 策略「命中即整行失效」已被离线实测**证伪为不必要**（见下）。

#### 二、离线模型：store 策略选型

`tools/dcache_sim.py`，6 条 `perf_*` trace，2 KB / 1 路 / 32 B 行：

| store 策略 | geoH | 预估 geo IPC |
|---|---|---|
| `alloc` 写分配（乐观上界，无实现） | 0.956 | — |
| `update` 写直达 + 命中更新 | 0.841 | 0.5350 (+29.1%) |
| `wbinv` 命中才失效（要看 tag） | 0.670 | 0.4961 |
| **`idxinv` 按索引失效（不看 tag）** | — | **0.4960 (+19.7%)** |
| `none` 不做任何失效（**错**，仅作对照） | — | 0.5350 |

**`idxinv` 与 `wbinv` 逐配置完全同值** ⇒ "不看 tag、清掉该**组**的 valid 位"是**零命中率代价**的，
且**零 SRAM 访问、零 tag 比较、零写口仲裁**。故本轮取 `idxinv`。
`update` 的 **+7.9%** 记成下一轮的杠杆（代价：每条 store 要 1 读 + 1 写两个端口周期 + pending 寄存器 + tag 检查）。

#### 三、带宽约束：为什么是 32 B 行而不是 64 B

AXI4-Lite **没有 burst** ⇒ 一次读事务只回 4 字节，且**读地址通道只有 1 AR/拍**
⇒ 填一行 L 个字要 **L 笔背靠背 AR**。把"填充 AR 拍数 ÷ 基线拍数"实测出来：

| 行大小 | vvadd | rsort | median |
|---|---|---|---|
| 16 B | 31% | 14% | 17% |
| **32 B** | **46%** | **23%** | **27%** |
| 64 B | 77% | 42% | 47% |

**64 B 行对 vvadd 物理不可行**（再加上取指填充就顶满读通道）。取 **32 B**（= `DC_LINE_WORDS=8`，
与 I 侧同值），vvadd 通道占用 46% + 取指 ≈ 78%，可行。

#### 四、独立复核提出的 4 处硬伤与对应设计

| # | 硬伤 | 若不修的后果 | 设计答案 |
|---|---|---|---|
| 1 | **完成序 ≠ 接受序**：命中 T+1 交付、缺失 LATENCY 拍后交付 | 若 `ld_done_idx` 仍取 FIFO 队首，会把 A 的 idx 配 B 的数据写进 A 的目的寄存器 —— **静默算错** | `ld_addr/width/idx_r` 改成 **miss 队列**：**推送时写、回包时读**；命中走自己的 `lk_*_r`。`tb_mem_axi` T9 专门钉死这条（先推缺失、后推命中，断言命中先完成且 idx/data 配对） |
| 2 | **一拍两次交付** | LSQ 只有一个 `mem_done_valid` 口，丢一个脉冲 = 该条 `issued_r` 永远为 1 ⇒ **挂死** | 全设计**只有 AXI 回包一个交付源**：`hit_valid = hit_raw_w && !rsp_busy`（**抢不到交付端口就不交**，降级成缺失）。互斥可证 ⇒ 每拍恰一个脉冲。代价是命中撞回包时白读一次 SRAM + 一趟 AXI 往返 |
| 3 | **填充安装 vs 在飞 store** | 装进"store 还没落盘"的旧行 ⇒ 读到旧值 | **填充中止**（三层）：起填时同组有 `sq_b_ack=0` 的条目 ⇒ 不起填；填充中同组 store 提交 ⇒ 置 `fill_poison_r`（粘滞），停发新 AR、回包照数但不写 SRAM、不置 valid；安装那一拍 `sw_valid` 落同组 ⇒ 不置 valid |
| 4 | **组合环（UNOPTFLAT）** | 综合/STA 无解 | D-cache **绝不让 `sw_valid` 组合影响交付数据**：`sw_valid → inv_valid → fill_wr_w → busy → ld_busy → ld_accept` 这条链终止（没有从 `ld_accept` 组合回到 `sw_valid` 的路径）；`hit_valid`/交付数据只来自 SRAM/FIFO 的**寄存器输出**。Verilator 构建无 UNOPTFLAT 即为证 |

#### 五、实现要点（`verilog/core/dcache.v` + `mem_subsystem.v`）

- **多路不需多读口**：一条目 = `DC_WAYS × (32×DC_LINE_WORDS + 32)` bit（tag 占每路最高 32 位槽），
  一拍读出**所有路**的 tag+data，tag 比较在 T+1 并行出 `hit` + `hit_way`。安装只写中选路的 lane
  （`wmask` 逐 lane 选通）。
- **缺失 skid 复用查表寄存器本身**：`park_w = miss_go_w && !rd_req_ready` 时保持 `lk_*_r` **并置
  `lk_miss_r`**（SRAM 数据已失效，不得再比 tag）。归纳：lookup 结果存在 ⟺ 上一拍 `ld_accept`；
  而 `ld_accept ⇒ ld_busy=0 ⇒ park_w=0` ⇒ skid 在被占用前必然空闲。
- **`!rd_req_ready` 必须从 `ld_busy` 拿掉**（基线里有这一项）：命中与 SRAM 访问都不占 AXI 槽位，
  用通道可用性闸接受会把**纯命中流一起掐死**；安全性由 `park_w` 独立保证。
- **MSHR 合并**：`miss_go_w && fill_busy_r && 同一行` ⇒ 不推 AR，置 `lk_wait_r` 停住；填充完成那拍
  **重放**（把 `lk_addr_r` 重新摆上 SRAM 地址口，1 拍后再判定 ⇒ 这次命中）。
  **不做合并会把 vvadd 打回基线**：单 MSHR 下填充期间对该行的每个 load 都会各发一笔 AR，
  32 B 行 = 每行 8 笔重复 AR，而 vvadd 是顺序流必中。
- **`rd_ok_r <= !fill_wr_w`**（在 T 拍采样后 AND 进 T+1 的 hit）：`sram_fakeram` 的**写偷读**
  （写周期 `rdata <= 'x`）⇒ 被偷判缺失，自纠正；同一拍让 `ld_busy` 抬高避免无谓降级。
- **fill 让路口径修正**：原式 `rd_req_ready && !ld_accept` 在 D-cache 下会**饿死填充**
  （命中流的 `ld_accept` 每拍为 1 却不占 AR 槽）。正确项是"本拍真正的需求 AR 用户"：
  `fill_req_ready = rd_req_ready && !demand_ar_w`，`demand_ar_w = dc_ms_valid`。
  优先级 **需求 load > 取指填充 > D 填充**，各自 `ready = rd_req_ready && !更高优先者`。
- **`ld_done_cnt_r` 改成数 `ld_done_valid`**（含命中）：否则每命中漂 1 ⇒ SQ 先不退休、后静默提前退休。
- **参数化**（`docs/description.md` 第 2 节逐项要求"Cache 容量与**相联度**"）：
  `DC_SIZE` / `DC_LINE_WORDS` / `DC_WAYS` 都是真参数。`DC_SIZE=0` 旁路（`DC_SETS` 钳到 1，不例化
  DEPTH=0 的阵列、不触发 `$fatal`）。

#### 六、多路相联的真参数化（`DC_WAYS`）—— 复核中发现并修掉的两个真 bug

初次写多路支持时留了两处硬编码，**在默认配置（WAYS=1）下完全不可见**：

| 位置 | 症状 | 修法 |
|---|---|---|
| `hit_way_w = way_hit_g[1] ? 1 : 0` | **2 路硬编码** ⇒ `DC_WAYS≥3` 时 way2/way3 命中会返回 **way0 的数据**（静默算错） | 换成通用优先编码函数 `hitway_f` |
| `lru_r[set] <= (hit_way == 0)` | 与它自己的注释（"1 = way0 是最近最少用"）**极性相反** ⇒ 实际按 **MRU** 替换（2 路下命中率最差） | 整体换成组内 **round-robin 指针** `rr_r`，极性歧义消失；WAYS=1 时该分支不被展开，**零触发器** |

`tb_dcache` 的 T4/T5 同时从"直接映射假设"改成相联度无关：T4 加多路分支（同组灌 `DC_WAYS+1` 条
不同 tag 的行，验证空路优先 + round-robin 替换的顺序），T5 改成自己先清组再填，不再依赖 T4 的残留状态。
**WAYS = 1 / 2 / 4 / 8 四档全部 `ALL TESTS PASSED`**；WAYS=1 的网表与改动前逐比特一致。

#### 七、正确性门禁

**单元 TB**：`make -f Makefile.tb run` **17 / 17 `ALL TESTS PASSED`，0 失败**（Icarus 签署 ——
Verilator 是二态，X 传播缺陷只有 Icarus 能抓）。新增 `tb/core/tb_dcache.v` 单独覆盖 D-cache：
`make -f Makefile.tb run TB=core/tb_dcache` 在 **`DC_WAYS` = 1 / 2 / 4 / 8 四档全绿**
（WAYS=1 计数：`accept=34 done=34 ms=20 fill_req=162`，账本"接受数 == 完成数"）。

计划里列的覆盖项逐条落到 T1–T12：

| 计划要求 | 落在 |
|---|---|
| 复位恒等 | T1 |
| 缺失 → 填充 → 再命中 | T2 |
| 合并缺失（waiter 重放后命中，且**不额外发 AR**） | T3（`chk(n_ms == ms_n + 1)` 钉死"合并的那条不再发 AR"） |
| 起填即清 valid ⇒ 半行不得假命中；tag 比较有效 | T4 |
| store 提交按索引失效（**不看 tag**）后必缺失 | T5 |
| 起填时 SQ 有未落盘的同组 store ⇒ 不起填 | T6 |
| 填充途中才出现未落盘 store ⇒ 同样作废 | T7 |
| 填充全程 store 提交到同组 ⇒ 写被抑制、不置 valid | T8 |
| 缺失推送被 `ready` 挡住（park）后地址不得丢失 | T9 |
| 命中撞回包 ⇒ 降级缺失，交付脉冲**不重不漏** | T10（注入合成回包，断言 `ms` 恰 +1、交付恰 1 次） |
| 背靠背访问不丢交付、不错配 idx | T11 |
| 填充中复位 ⇒ 干净重启 | T12 |
| `DC_SIZE=0` 旁路永不命中、永不起填 | 旁路实例 `dut_off` 的常驻断言（含"命中与回包不得同拍"） |
| 写偷读判缺失 | **不单列，见下** |

**关于"写偷读判缺失"（`rd_ok_r`）—— 探针实测后改写成不变量，未加测试。**
`docs/sram.md` 的 `sram_fakeram` 写口偷读是**与地址无关**的：`rdata <= 'x` 在每个 posedge 无条件执行，
只有 `en && !we` 那一支才赋真值 ⇒ **任何**安装写的那一拍，读口都出 X（不限于同组）。逐比特读码
确认相位正确：`rd_set_w` 取自**当拍** `rd_addr_w`，`rd_addr_q` 打一拍寄存，`rd_ok_r <= !fill_wr_w`
采样的正是发起读那一拍 ⇒ 与 `rdata_w` 同源，不存在错拍。

但**接受路径上这个守卫恒为 1**：`dcache.busy` 含 `fill_wr_w` 项，`mem_subsystem.v:212`
`ld_busy = (ld_inflight >= LD_INFLIGHT) || dc_busy`，而 `accept` 必须 `!busy` ⇒ 安装写那拍根本收不下
load ⇒ 下一拍 `rd_ok_r` 必为 1。**它不是被测试保证的，是被 `busy` 组合保证的。** 守卫真正活着的
地方是**重放路径**：`lk_replay_r` 那拍把 `lk_addr_r` 重新摆上读口，下一拍 `hit_raw_w` 里
`rd_ok_r` 是实打实的判据（被偷 ⇒ `rdata_w` 是 X ⇒ 判缺失走 AXI，自纠正，不会拿 X 当数据）。

用一次性插桩副本量化过（非归档实验，仅本次取证）：整个 TB 跑出 **`fill_wr_w` 共 128 拍、其中撞上
驻留查表的 16 拍**，Icarus 全程无 X 逃逸、无数据错配。故不再补一条测试，改为在本节记录该不变量。

**`tb_mem_axi` 补交错完成用例（T9）**：有 D-cache 后**完成序 ≠ 接受序**（命中 T+1 交付，缺失等 AXI）。
故意**先发缺失、后发命中**，断言完成顺序是"命中先回"、且每条完成记录的 `idx ↔ data` 严格配对。
这是硬伤 1（FIFO 队首取 idx）唯一的可观测症状 —— 账本"收下数 == 完成数"在错配下**照样平衡**，
只有逐条比对 idx 才抓得出来。

**全量 `make test`**：**19 passed, 0 failed**（`MAX_CYCLES`/`LATENCY` 走默认 10）。

#### 八、集成后才暴露的两个真 bug —— 单元 TB 与离线模型都抓不到

`make -f Makefile.tb run` 17/17 全绿、`tb_dcache` 四档相联度全绿之后，**全量 `make test` 仍然挂**
（`correctness_bulgarian` 超时；HEAD 对照 `PASS cycles=529157`）。两个缺陷都在这一层才现形。

**先切"共享路径 vs 缓存阵列"**：拿 `DC_SIZE=0`（旁路）跑 bulgarian —— **也挂**。而 `DC_SIZE=0` 下
`dc_hit_valid ≡ 0`、`ld_done_valid ≡ ld_resp_hs`，交付语义与 HEAD 逐比特相同 ⇒ 病在
`mem_subsystem.v` 的重接线里，不在 `dcache.v` 的阵列。这条对照把搜索空间砍掉一半（事后看，
两个 bug 恰好一个在这一半、一个在另一半，所以这一刀必须先切）。

**缩到最小复现**：`hanoi`（HEAD `PASS cycles=9118 result=184`，只有 3674 条动态指令）。
限拍 VCD 按时间窗扫描：**全部信号在 t=1331 之后不再翻转**，而 VCD 一直录到 t=60009 ——
机器在第 ~665 拍**整体冻死**，不是变慢（HEAD 同参数 VCD 每拍 ~10 KB，当前树每拍 173 B，
密度差 60× 独立佐证了"冻住"这个读法）。

**Bug A —— `mem_subsystem.v`：接受/推送记账错位（与 D-cache 无关）**

HEAD 的 `ld_wr_p` 数的是 **accept**；改成 miss 队列后数的是 **`dc_ms_fire_w`（缺失推送）**。
推送比接受晚 ≥1 拍（中间隔着 D-cache 的查表寄存器），而 `ld_busy` 仍拿 `ld_inflight_w >= LD_INFLIGHT`
卡 —— **接受那一刻不进计数器** ⇒ 在飞数能冲到 `LD_INFLIGHT + 1 = 9`。8 槽数组按
`ld_wr_p[LD_IW-1:0]` 取模寻址 ⇒ 第 9 笔 **覆盖最老在飞条目的 addr/width/idx** ⇒
那条老 load 的回包带着新 load 的 idx ⇒ LSQ 清错 `issued_r` 位、正确那一位恒 1 ⇒ head 卡死。

插桩实测（hanoi 30000 拍内**仅触发一次**，一次就够）：`inflight=8 wr=3 rd=11 slot=3` ——
`wr=3/rd=11` 的活条目占槽 `3,4,5,6,7,0,1,2`（槽号 mod 8，**全部 8 格**），下一笔写槽 3
正是最老那条。铁证。

**修**：把"本拍正在推送的那条"补进占用——`ld_occ_w = ld_inflight_w + dc_ms_fire_w`，
`ld_busy = (ld_occ_w >= LD_INFLIGHT) || dc_busy`。
归纳保证：接受 ⇒ `busy=0` ⇒ 在飞未推送的 load 至多 1 条，且它的推送最早在下一拍 ⇒
只要接受那拍 `在飞 + 本拍推送 + 1 <= LD_INFLIGHT` 就永不越界。修后 hanoi `PASS cycles=10197`，
bulgarian 的 OVF 探针 0 次触发。

**Bug B —— `dcache.v`：把 1 拍脉冲当电平用（D-cache 专有）**

`coalesce_w`（并入在填行）与 `fill_last_w`（填充最后一拍）**可以同拍发生**。那一拍只置了
`lk_wait_r <= 1`，而退出条件写的是 `if (fill_last_w)` —— 一个 1 拍脉冲。posedge 之后
`fill_busy_r` 已清、`fill_last_w` 再也不会为 1 ⇒ **`lk_wait_r` 恒 1** ⇒ 该 load 永不交付 ⇒
同样是 `issued_r` 恒 1、head 卡死、全机冻结。

插桩实测：bulgarian t=20765 同拍命中 `[COAL-LAST]`，紧接着 t=20767 起**每拍** `[WAITSTUCK]`
直到 300000 拍上限。修后同一用例 t=501261 / t=505299 各命中一次，每次后面**只有一拍** `[WAITSTUCK]`
（那正是"检测到并当场退出"的那一拍），程序 `PASS cycles=572018`。

**修**：退出条件改成电平 `if (fill_last_w || !fill_busy_r)`。保留 `fill_last_w` 那一项只为不白丢 1 拍：
它那拍 `fill_busy_r` 还是 1，快路径抓得到；而重放读最早只能是下一拍（那一拍安装写已过、读口不再被偷），
`!fill_busy_r` 单独用会迟 1 拍才发起重放。

**为什么两道门禁都没抓住**
- `tb_dcache` 的 T3 覆盖了"合并缺失"，但那是**构造**出来的时序，没撞上"并入恰在最后一拍"这个 1/L 窗口；
  Bug A 更是 `mem_subsystem` 层的记账，根本不在 `tb_dcache` 的视野里。
- 离线模型 `tools/dcache_sim.py` 建模的是**命中率**，不是握手记账 —— 它按定义看不见这两类缺陷。
- 两个 bug 的共同形状：**A 是"两个计数器的口径分岔了"，B 是"脉冲 vs 电平"**。
  两者都不改变单拍行为，只改变跨拍不变量，所以只有真跑长程序才暴露。
  这也是"`make -f Makefile.tb run` 全绿 ≠ `make test` 全绿"的又一例证 —— 门禁必须跑满 19 个用例。

**门禁现状**：`make -f Makefile.tb run` 17/17；`make test` 19/19；
`DC_SIZE=0` 消融 `PASS cycles=543254`（HEAD 529157，旁路比基线慢 2.7% = 每笔缺失多 1 拍的代价）。

#### 九、IPC 实测 —— 以及一处**必须先纠正的对照口径**

计划书门禁 2 写的对照是 `ic1k` 的 `0.3797/0.6537/0.3071/0.3830/0.3512/0.4932`（geo 0.4143）。
**那台机器与当前树不是同一台**：`ic1k` 的 `run.sh` 参数补丁把 `ROB_SIZE` 压到 16、`RS_SIZE` 4、
`BHT_SIZE` 8（`runs/ic1k/verilog/top/student_top.v:11-15`），而 `student_top.v` 的**提交默认值**是
ROB=32 / RS=16 / BHT=32 / RAS=8 / SQ=8 / WR=8 / `ROLLBACK_WIDTH=4` / `IC_SIZE=1024` / `LD_INFLIGHT=8`。
两者 IPC 不可相减（§15.10.25 ⑤ 已记过同一类坑，此处是它的第二次复现）。

故本轮另做**同配置对照**：`git archive HEAD` 出一棵不含 `dcache.v` 的树（参数与工作树**逐位相同**，
`diff` 只差 D-cache 那三个 `parameter`）。

| 用例 | **HEAD 对照**（无 D-cache） | D-cache `idxinv` | **+ AR 中止**（本轮终值） | 终值 vs HEAD |
|---|---|---|---|---|
| `perf_median` | 0.4128 | 0.5606 | **0.5606** | **+35.8%** |
| `perf_multiply` | 0.6586 | 0.6630 | **0.6630** | +0.7% |
| `perf_qsort` | 0.3456 | 0.2904 | **0.3214** | **−7.0%** |
| `perf_rsort` | 0.3910 | 0.3733 | **0.3812** | −2.5% |
| `perf_towers` | 0.4018 | 0.3126 | **0.3399** | **−15.4%** |
| `perf_vvadd` | 0.5110 | 0.7257 | **0.7257** | **+42.0%** |
| **geo** | **0.4428** | 0.4573 | **0.4732** | **+6.87%** |

**读法：D-cache 不是全面加速，是"再分配"。** vvadd / median 两个空间局部性强的用例大涨
（+42.0% / +35.8%），qsort / towers / rsort 三个 store 密集的用例**倒退**。倒退的机制就是 `idxinv`
本身：每次 store 提交清掉**整组**的 valid，1 路下等于把整行扔掉（32 B 行只写了 4 B）——
这正是 §二 离线表里 `update`（写直达 + 命中更新）比 `idxinv` 高 **+7.9%** 的那个差。

**`DC_SIZE=0` 消融**（旁路，走同一套 `mem_subsystem` 接线）：`correctness_bulgarian`
`PASS cycles=543254` vs HEAD `529157`（−2.7%，每笔缺失多 1 拍的代价）。
**注意它不等于"逐比特复现基线"**：旁路路径上 D-cache 仍占一拍查表寄存器 ⇒ 只作**方向性**对照。

#### 十、AR 带宽的收支判据 —— 为什么命中率 33% 时 D-cache 会倒退

AXI4-Lite 无 burst、1 AR/拍、每 AR 只回 4 B ⇒ 一次 L 字填充 = **L 笔 AR**。设 n 次 load、
h 命中、m 缺失（h+m=n）：无缓存发 **n** 笔 AR；有缓存发 **m(1+L)** 笔（1 笔需求 + L 笔填充）。
**缓存赢在 AR 条数上 ⟺ m·L < h ⟺ h/m > L**。L=8 时门槛是命中率 **88.9%**。

实测（插桩副本，abort 前，L=8/2048/1 路）：

| 用例 | fill | pois（污染） | fspois（起填即污） | mid（途中污） | invblk | hit | ms（需求 AR） | coal | `hit/ms` | 门槛 |
|---|---|---|---|---|---|---|---|---|---|---|
| towers | 576 | 200（**35%**） | 102 | 98 | 143 | 570 | 940 | 282 | 0.61 | 8 |
| qsort | 16447 | 7862（**48%**） | 5263 | 2599 | 3082 | 15887 | 23433 | 10549 | 0.68 | 8 |
| rsort | 20456 | 15399（**75%**） | 2202 | 13197 | 8154 | 11590 | 24997 | 3567 | 0.46 | 8 |

**`hit/ms` 比门槛低一个数量级** ⇒ 当前 D-cache 是**读带宽的净消耗者**：qsort 有缓存要发
`23433×9 ≈ 21.1 万` 笔 AR，无缓存只要 `39320` 笔 —— **5.4 倍**。
**它仍然净赢 +3.5%，靠的是延迟掩盖（一笔 10 拍的往返换成 1 拍命中），不是带宽。**
这条判据同时解释了 §九 里的三个倒退用例：store 密集 ⇒ 污染率高 ⇒ 填充作废后既付了 AR 又没留下行。
（"命中率"一节的两个原始比值：towers `570/(570+940)=37.8%`、qsort `40.4%`、rsort `31.7%`——
定义不同数值不同，故上表**以原始计数器为准**，比值只是换算。）

#### 十一、污染填充的 AR 中止（**+3.48%**）

`fill_req_valid` 原先**不带污染门控** ⇒ 一旦本次填充被污染，剩下的 L−k 笔 AR 照发不误，
读回的数据全部丢弃（`fill_wr_w` 已把它挡在 SRAM 外）。§十 的实测说污染率 35~75%，
且 rsort 有 **65% 是"填充途中"才污染**（`mid/fill`）⇒ 白发的正是行尾那几笔。

**改法**：`fill_abort_w = fill_busy_r && (fill_poison_r || fill_poison_now_w)`，
`fill_req_valid` 与上 `!fill_abort_w`。**已发出的必须收完**（回包与 AR 一一对应，漏收的会被下一次
填充当成自己的响应 ⇒ 字下标错位），故收尾分两支：正常 = 收满一行；中止 = `fill_word_r == fill_cnt_r`（无在飞）。
**中止且无在飞时必须当拍收尾**，不能等回包 —— 否则 `fill_last_w` 永不置位、`fill_busy_r` 恒 1，
该组再也起不了填充。**这又是"脉冲当电平用"的形状（与 §八 Bug B 同族），是写这条时第一个要防的坑。**

这条改动**不改变任何数据通路**：污染后本来就不写 SRAM、不置 valid，省掉的只是"必被丢弃的 AR"。
故它只可能改变时序、不可能引入新的错值路径 —— 增益精确落在污染率高的用例上，实测正好如此：

| 用例 | 无 abort | +abort | Δ | 污染率 |
|---|---|---|---|---|
| median | 0.5606 | 0.5606 | **0**（逐比特不变） | — |
| multiply | 0.6630 | 0.6630 | **0** | — |
| vvadd | 0.7257 | 0.7257 | **0** | — |
| qsort | 0.2904 | 0.3214 | **+10.7%** | 48% |
| towers | 0.3126 | 0.3399 | **+8.7%** | 35% |
| rsort | 0.3733 | 0.3812 | +2.1% | 75% |
| **geo** | 0.4573 | **0.4732** | **+3.48%** | — |

**零污染的用例逐比特不变、高污染的用例大涨** —— 增益的位置与机制的预测完全对齐，
这是这条改动"确实按它声称的方式生效"的证据。单元 TB 侧的独立旁证：
`tb_dcache` 的 `fill_req` 计数 **162 → 140**，而账本 `accept=34 done=34` 仍平衡。

#### 十二、`DC_LINE_WORDS` 的证伪性对照（预注册方向性预测，**结论是不改**）

§十 的判据给出一个**方向性**预测：行越小 ⇒ 每次填充的 AR 越少 ⇒ **命中率低时小行更优**；
反之命中率高的顺序流靠大行摊薄 tag 开销与往返，**大行更优**。这是"用理论选一个点去证伪"，
不是扫参数找上限；三个点都是**预测先写下来再测**：

| 用例 | 局部性 / 污染 | 预测 | L=8 | L=4 | L=2 | 命中？ |
|---|---|---|---|---|---|---|
| qsort | 低命中率、高污染 | L 小者优 | 0.3214 | 0.3666 | **0.3876** | ✅ 单调 |
| rsort | 最低命中率 | L 小者优 | 0.3812 | **0.3977** | 0.3903 | ~ |
| vvadd | 顺序流 | L 大者优 | **0.7257** | 0.5470 | 0.3722 | ✅ 单调 |
| median | 顺序流 | L 大者优 | **0.5606** | 0.5035 | 0.3939 | ✅ 单调 |
| multiply | 顺序流 | L 大者优 | **0.6630** | 0.6565 | 0.6394 | ✅ 单调 |
| towers | 低命中率 | L 小者优 | 0.3399 | **0.3602** | 0.3402 | ~ |
| **geo** | | | **0.4732** | 0.4602 | 0.4110 | |
| 组数（2 KB 同容量） | | | 64 | 128 | 256 | |

**逐用例方向性预测成立（4/6 单调、2/6 交叉但都在 L=4 取到局部最优），
但几何平均上大行的收益压倒小行 ⇒ `DC_LINE_WORDS` 保持 8，不改参数。**
（geo 由 vvadd 的 **+95.0%** 与 median 的 **+42.3%**（L=8 vs L=2）主导，而 qsort/rsort/towers
三个用例的反向差额只有 **+20.6% / +4.3% / +6.0%**。）"L 越小越好"这条直觉读法**被证伪**并留痕于此。

#### 十三、一次"潜伏缺陷"误报的完整留痕（探针污染 stdout）

做 §十 的插桩时，我给 `dcache.v` 加了一段每 16384 拍 `$display("[STAT] ...")` 的临时探针。
随后四个参数变体（L=4 / L=2 / L=4+4 KB / 8 KB）在 `make perf` 上**全部**报
`exit result mismatch: expected N, actual [STAT] t=32769 ...` —— 当时读作
**"D-cache 里有个被 2048 这个配置碰巧掩盖的潜伏缺陷"**，并已准备按此方向根因分析。

**该读法是错的。** 证伪它的是两条：
1. 直接按 OJ 协议复现：stdout 是 `'[STAT] t=32769 ...\n0\n'`，而 `scripts/oj_io.py` 的
   `compare_output` 要求**逐行完全相等**（期望只有 `0` 一行）⇒ 多出的探针行必然判失败。
2. `DC_SIZE=8192` 变体的 8 个"失败"用例里有 **4 个是 `fill=0 pois=0 hit=0 ms=0`**
   —— 前 16384 拍缓存根本没被访问过，不可能有缓存缺陷。同一条报文形态（`got[0]` = `[STAT]` 行）
   在 8 个用例里完全一致。

**根因**：`$display` 走 **stdout**，而 OJ 的输出比对是**精确全等**，不是子序列匹配。
`make test` 19/19 之所以曾通过，是因为那次门禁跑在探针加进去**之前**。

**规则（已固化）**：① 任何插桩不得进 `verilog/`（会同时污染**交付物**）；
② 门禁与 perf 一律在**无探针**的树上跑；③ 探针一律走 stderr 或独立文件句柄。
那次"四个变体全错"的观测**整体作废**，不作为任何结论的依据。

#### 十四、门禁现状与面积

| 门禁 | 结果 |
|---|---|
| `make -f Makefile.tb run`（Icarus，17 个单元 TB） | **17 / 17 `ALL TESTS PASSED`** |
| `make CONFIG=config.local.mk test`（19 个 correctness） | **19 passed, 0 failed** |
| `make CONFIG=config.local.mk perf` | **geo 0.4732**（同配置 HEAD 对照 0.4428，**+6.87%**） |
| 面积 / 频率 | **本轮不跑 `make synth`**（脚本仍在变）；逐比特估算见 `docs/area_budget.md` §3.1 |

**面积（估算，非实测）**：行阵列 64×288 = 18432 bit ≈ **774 µm²** + 触发器 221 bit ≈ **84 µm²**
+ miss 队列 304 bit ≈ **115 µm²** + 组合（tag 比较 / 3 路仲裁 / `sq_blk`）≈ 100 µm²
⇒ **约 1075 µm² 量级**。§十一 的 AR 中止只加一个比较器与一个 mux，**面积增量可忽略**。
现基线 `ic1k` 8184 µm² + 本项 ≈ 9.3k µm²，**仍远低于档 3 的 36000 µm²**（用掉 26%）。
**净增量必须由 `make synth` 出，估值不可当实测用。**

**下一轮的杠杆（按 §十 的判据排序）**
1. `update`（写直达 + 命中更新）：离线 +7.9%，直接消掉 §九 的三个倒退用例 —— 代价是每条 store
   要 1 读 + 1 写两个 SRAM 端口周期 + pending 寄存器 + tag 检查。
2. **需求 AR 并入填充**（critical-word-first）：现在一笔缺失要 **1 笔需求 AR + L 笔填充 AR = 9 笔**，
   而填充里本来就含被需求的那一字 ⇒ 省掉那笔独立需求 AR，并把该字的 AR 提到行首。
   §十 的表里 `ms`（需求 AR）与 `fill` 同量级 ⇒ 这是 **~11% 的读流量**。
3. 多 MSHR / 更大 `LD_INFLIGHT`：`LD_INFLIGHT` 在 4 就饱和（§15.10.24），已被证伪，不再试。

**归档说明**：`tools/snap.py` 需要综合产物目录（`--artifacts` 里得有 `timing.rpt`），
而本轮**不跑 `make synth`** ⇒ `docs/timing/results.csv` 本轮**不追加行**，
所有数字以本节与 `docs/area_budget.md` §3.1 为准（后者明确标为估算）。
不为填表去跑一次综合（"不为文档数字新跑实验"）。

