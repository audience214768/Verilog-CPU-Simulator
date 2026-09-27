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
| 释放 RS | `rs_clear_valid = sel_valid & ~div_hold_w` —— **没被收下就不清条目**（清了这条指令再也不会被选中 ⇒ 死锁） |
| 不广播 | `exec_valid = sel_valid && !is_load && !is_div`（否则当拍广播一个占位结果并把 ROB 置就绪） |
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
