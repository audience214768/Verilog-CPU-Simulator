# RV32IM 乱序多发射 CPU — 架构设计文档

> 本文件是**设计规格**：设计决策、参数表、时序约定、模块接口、握手协议、正确性陷阱清单。
> **官方框架侧（`student_top` / AXI4-Lite / MMIO 终止 / I+D Cache / DIV）全部已实现并实测。**
> 改 RTL 前先对照本文；RTL 与本文不一致时**以 RTL 为准并回头改本文**（本文曾是"目标规格"，
> 落地后多处已与实现分叉 —— 凡标「待验证」的段落视为历史推断）。
> 过程记录 / 阶段计划 / debug 台账 / 消融矩阵在 `docs/plan.md`；
> 评测口径一律以 `docs/description.md` 为准（该文件只由用户手动修改）。

## 背景 (Context)

verilog-cpu-simulator 是 PPCA 大作业：一个**可参数化的乱序多发射 RV32IM CPU**（Verilog-2005，可仿真可综合）。**`verilog/filelist.f` 里 25 个模块已全部实现**（I-cache / D-cache 均已落地），且**官方链路全通**（`student_top` + AXI4-Lite：`make build` 通过、`make test` 19/19 PASS、`make perf` 6/6 通过并给出 IPC）。**RV32IM 指令集已补齐**（DIV/DIVU/REM/REMU 见 `docs/plan.md` §15.10；LB/LBU/LH/LHU 更早已实现）。
本文定义**全部模块的 input/output 接口**、cpu_top 布线、握手协议与已验证的正确性不变量。参考工程 `/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`（C++ 版 Tomasulo，单发射）的接线已全部分析，本设计**借用其验证过的机制、修正其不合理处**。

需求（**以 `docs/description.md` 为准**，该文件只由用户手动修改；本节及全文的指标口径随其更新）。
以下按 description.md 的**章节名**索引（旧文档用的行号指针已随该文件改版全部失效）：

| 来源章节 | 要求 |
|---|---|
| §架构要求与设计规范 · 1. 指令集 | RV32IM **全量**：LB/LBU/LH/LHU/SB/SH/LW/SW + MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU。免除项**只有** `CSR*`/`FENCE`/`FENCE.I`/`ECALL`/`EBREAK`。访存按自然边界对齐，不要求非对齐 |
| §架构要求与设计规范 · 2. 微架构要求 | 乱序发射 + **按序提交**；参数化：发射宽度、ROB 深度、PRF 大小、保留站/发射队列深度、**Cache 容量与相联度**（新增） |
| §架构要求与设计规范 · 3. 终止与输出约定 | 向 MMIO `0x80000000` 做 32 位 store（`WSTRB=4'hf`）标记结束；退出值 = `WDATA[31:0]` |
| §架构要求与设计规范 · 4. 内存布局 | 外部 **256 MiB** 小端 RAM（`0x00000000`–`0x0fffffff`），字节默认清零 |
| §顶层模块与 AXI4-Lite 协议 | 顶层**必须**叫 `student_top`，AXI4-Lite master 端口模板固定，`reset` **高有效**（初始化保持 5 拍） |
| §顶层模块与 AXI4-Lite 协议 · 总线与内存约定 | 每通道 16 项队列；请求最快"握手后下一周期"被服务；**服务到响应可见默认 10 拍**（`--latency` 可调）；`sram_fakeram` 的 SRAM 估算面积**计入总面积** |
| §评分标准与时间安排 · 1. 正确性（85 分） | 两阶段：基础程序（向量乘/向量加/0-100 累加，75 分）→ 仿真程序（`testcases/correctness_*`，85 分）；退出值须与标准答案**完全一致** |
| §评分标准与时间安排 · 2. 性能（15 分 + 4 分频率加分） | 面积 = Yosys+ASAP7 综合 + SRAM 估算（µm²）；IPC = 动态指令数 / 运行周期数，`testcases/perf_*` 取**几何平均**；频率 ≥300 MHz 是硬性前提（400/500 MHz 分别 +2/+4）。三档"面积上限与最低 IPC 同时满足"：**(9000, 0.6000) / (18000, 0.8450) / (36000, 1.0985)** |
| §评分标准与时间安排 · 3. 时间安排与 AI 政策 | 中期检查第 7 周、DDL 第 14 周周六；报告需含**参数敏感度分析**与**架构探索总结**，两人一组；Code Review 考察架构权衡与 LLM 交互记录 |

> **两条必须记住的算法事实**（旧文档的说法已作废）：
> ① 旧上限 10000/20000/40000 是**上一版** description.md 的数字，旧文档里的"余量 22%"按旧上限算，**不成立**；
> ② "档位设计为 IPC ×1.3 ↔ 面积上限 ×2" **只有 2→3 档严格成立**（0.8450×1.3 = 1.0985 ✓，18000×2 = 36000 ✓）；
> 1→2 档面积翻倍但 IPC 倍数是 **1.4083**（0.6000×1.3 = 0.78 ≠ 0.8450）。

## 已确认的设计决策（与用户商定）

| # | 决策 | 与参考工程的关系 |
|---|---|---|
| D1 | **状态式 RS**：RS 只存物理寄存器号+译码字段，不存操作数；执行时 `prs==0→0 / CDB 旁路 / ready_table→PRF 索引读` | 同参考（其 RS 不存值）；PRF 用索引读而非 64×32 全阵列广播（参考缺陷#1） |
| D2 | **误预测恢复 = 并行 walker**（W 条/周期回滚 RAT/free_list/ready_table），RAS 1 周期 head 恢复 | 同参考语义但并行化（参考 1 条/周期）；RAT 快照方案留作消融实验 |
| D3 | **RAS 保留但深度参数化（默认 8）**：程序调用极少，价值由消融量化；BHT 才是重点（循环回边） | 同参考（head 指针恢复，不重写栈） |
| D4 | **内存无缓存 v1**：同步 RAM + `MEM_LATENCY` 飞行槽倒计时（多路在飞）；store 提交时直写（1 周期同步写本身就是延迟）；缓存/缓存延迟留作消融 | 参考的 cache+store buffer 不做；延迟参数仅为性能建模（RAM 本身零延迟） |
| D5 | **CDB 纯组合**，W+1 槽（W 执行 + 1 load 完成）；写回逻辑（PRF 写/ready 置位/ROB ready 置位）在 cdb.v；**所有 ROB ready 标记统一经 CDB**（rob_wr 位，代替参考的 NONE 哨兵+三写者） | 改进：省 1 拍、无槽清空逻辑、单一写者 |
| D6 | 执行槽 = alu.v（内实例化 adder32+mul）+ branch.v（内实例化 adder32），全组合 1 周期；访存有效地址由槽内 alu 计算 | 参考无独立分支单元（缺陷#5） |
| D7 | **窄标签**：phys=$clog2(PRF_SIZE)、rob=$clog2(ROB_SIZE)、lsq=$clog2(LSQ_SIZE)；x0=phys0 读口短路为 0 | 参考 32 位标签满天飞（缺陷#1） |
| D8 | 批内转发：同批第 i 条指令的组合读口必须看到第 0..i-1 条的 rename（在 rat.v 内部实现） | 多发射新增问题，参考单发射无此需求 |
| D9 | LSQ：发射时建条目、执行时写 addr/data、完成时字节合并前向、store 提交时直写内存 | 同参考机制（store 前向 + 排序保证），合并逻辑移入 lsq.v |

**额外修正（审查 Plan 代理初稿发现）**：
- free_list 复位 = {32..PRF_SIZE-1}（count=PRF_SIZE-32），RAT 恒等映射 `map[i]=i`，ready_table 0..31 就绪——沿用参考已验证方案
- 终止标记（**旧约定，Phase C 后退役**）= `ori x0,x0,255`（raw `0x0FF06093`），**不用**参考的 `li a0,255`（0x0ff00513 会把 a0 返回值冲掉）；标记指令正常提交，提交时锁存 halt，ROB 排空后采样 `x10 & 0xFF`。**官方约定**是向 MMIO `0x80000000` 做 32 位 store、退出值取 `WDATA[31:0]`，见「目标架构」C.5 与 C.7
- 同周期多误预测（W 槽）→ 冲刷到**最老**的误预测分支；walker 中途新误预测 → 范围扩展（沿用参考语义）
- load 完成正确性：发起条件含"所有更老 store 已执行完（addr+data 就绪）"，完成时字节合并才正确（参考只查 addr，若 store 数据未就绪会取到旧值——参考的潜在缺陷，已修）

## 参数表（全部经 cpu_top 下传；exec 单元无参数）

| 参数 | 默认 | 含义 | 使用模块 |
|---|---|---|---|
| `ISSUE_WIDTH` (W) | 1 | 前端/发射/执行/提交宽度 ∈{1,2,4} | 全部 |
| `ROB_SIZE` | 32 | ROB 条目数（2 的幂） | rob, cpu_top |
| `RS_SIZE` | 16 | RS 条目数（2 的幂） | rs, cpu_top |
| `PRF_SIZE` | 64 | 物理寄存器数（2 的幂） | prf, ready_table, free_list, rat, cpu_top |
| `LSQ_SIZE` | 16 | LSQ 条目数（2 的幂） | lsq, cpu_top |
| `BHT_SIZE` | 32 | 2-bit 饱和计数器数 | bht, fetch |
| `RAS_SIZE` | 8 | 返回地址栈深度 | ras, fetch |
| `MEM_SIZE` | 65536 | **已退役**（仅 TB 的 `memory.v` 还在用）：字节寻址 RAM 容量。官方口径下内存是外部 256 MiB AXI4-Lite 从机 | memory |
| `MEM_LATENCY` | 3 | **已退役**（仅 TB）：片上 memory 的 load 倒计时。**官方口径只有 10 拍一个值**（框架 `LATENCY` 默认），由总线从机产生 | memory |
| `MEM_INFLIGHT` | 4 | **已退役**（仅 TB）：片上 memory 的飞行 load 槽数。等价物是 AXI 侧的未完成读数（`mem_subsystem` 的 `LD_INFLIGHT`），是 MLP 的结构上限 | memory |
| `INIT_FILE` | "" | **现状**：非空时仿真初始化 $readmemh（每行 8 位 hex，支持 @地址） | memory |
| 派生 | | `PW=$clog2(PRF_SIZE)=6, RW=$clog2(ROB_SIZE)=5, LW=$clog2(LSQ_SIZE)=4, BW=$clog2(BHT_SIZE), RA=$clog2(RAS_SIZE), SRW=$clog2(RS_SIZE), CSW=$clog2(RS_SIZE+1), RCW=$clog2(ROB_SIZE+1), LCW=$clog2(LSQ_SIZE+1), PCW=$clog2(PRF_SIZE+1)` | |

**`student_top` / `cpu_top` 的其余参数**（照 RTL 声明如实列出，默认值即当前基线）：

| 参数 | 默认 | 含义 | 使用模块 |
|---|---|---|---|
| `ROLLBACK_WIDTH` | 4 | 误预测回滚并行宽度（walker 每拍回滚条数） | cpu_top, rat, free_list, ready_table |
| `IC_SIZE` | 1024 | I-cache 容量（字节），`0` = 旁路直连 | icache, mem_subsystem |
| `IC_LINE_WORDS` | 8 | I-cache 行宽（字） | icache, mem_subsystem |
| `IC_BYPASS` | 0 | 取指读口直通（调试用） | icache |
| `IC_PREFETCH` | 1 | 取指预取使能（落地于 icache 的行预取，**不是**旧文档的 `PF_WIN`） | icache, mem_subsystem |
| `DC_SIZE` | 2048 | D-cache 容量（字节），`0` = 旁路 | dcache, mem_subsystem |
| `DC_LINE_WORDS` | 8 | D-cache 行宽（字） | dcache, mem_subsystem |
| `DC_WAYS` | 2 | D-cache 相联度（≥2 走 LRU，1 路零额外触发器） | dcache, mem_subsystem |
| `LD_INFLIGHT` | 8 | 在飞 load 上限（AXI 未完成读数） | mem_subsystem |
| `SQ_DEPTH` | 8 | 已提交未可见 store 队列深度 | mem_subsystem |
| `RD_DEPTH` | 16 | AXI 读事务 FIFO 深度（**约束：≥2×`IC_LINE_WORDS` 且为 2 的幂**） | mem_subsystem, axi_lite_master |
| `WR_DEPTH` | 8 | AXI 写事务 FIFO 深度（须 < 从机 AW/W FIFO 深度） | mem_subsystem, axi_lite_master |

> 合法性硬约束（参数扫描时先看这里）：`RAS_SIZE` 最小 4（0 无法展开）；`PRF_SIZE > 32`（`free_list.v` BASE=32，
> `PRF_SIZE=40` 是永久死锁点）；`RD_DEPTH ≥ 2×IC_LINE_WORDS` 且为 2 的幂；`WR_DEPTH < 从机 AW/W FIFO 深度`。
> 参数消融的实测数据见 `docs/plan.md` §二十二/§二十三；`docs/timing/results.csv` 是全部综合点的台账。

## 时序约定（全部模块）

- 端口一律**低有效复位 `rst_n`**；每个握手信号 = 1 拍脉冲、**单一写者**；输出 = 当前状态组合。
  **复位风格现存两种（新代码优先异步）**：`rob`(×2)/`rs`/`rat`/`ready_table` 与新增的
  `axi_lite_master`/`mem_subsystem` 用**异步** `always @(posedge clk or negedge rst_n)`；
  `prf`/`lsq`/`free_list`/`ras`/`bht`/`fetch` 用**同步** `always @(posedge clk)` + `if (!rst_n)`。
  新增模块里纯数据阵列（FIFO 载荷）的写口是 `always @(posedge clk)` **无复位**分支 —— 阵列内容不需要复位，
  也省面积。原因见 `docs/area_budget.md` §2 注：ASAP7 r28 库里**没有**同步复位触发器，
  同步复位会被拆成软逻辑（更贵）。
- **复位极性的内外差异**：内部一律 `rst_n`（低有效）；官方 `student_top` 的 `reset` 是**高有效**（保持 5 拍）。
  取反放在 `student_top` 包层（`wire rst_n = ~reset;`），**不给各模块加极性参数** ——
  后者会让全部 TB 与源文件改动，而包层取反只是一行。
  注意 `reset` 是**异步断言、同步释放**的用法：框架在 5 拍后直接拉低，包层不需要同步器（那 5 拍远长于一个周期）
- **CDB 无寄存器**：执行/load 结果当拍组合到达 → 当拍旁路（同拍背靠背依赖执行）+ 当拍 posedge 写 PRF/置 ready；PRF 索引读下拍可见，但旁路已覆盖同拍需求（每个 preg 恰好写一次，D1 保证正确）
- ROB ready 置位唯一写者 = CDB 槽的 `rob_wr` 标志（分支/store/load/终止全部走 CDB）
- 优先级（各模块 eval 内）：flush > commit > issue > exec 写（与参考一致，保证拍级确定性）

## 模块接口规格（Phase A 骨架定稿，代码以此为准）

端口组约定：A=状态读输出，B=握手写输入，C=旁路/组合输入，D=杂项。W=ISSUE_WIDTH，PW/RW/LW/BW/RA 见参数表。

### 已实现（不变）
- `adder32 #(WIDTH)(a, b, cin → sum, cout)`
- `mul (a, b, a_signed, b_signed → product[63:0])`

### exec/alu.v — 纯组合，无参数
| name | dir | width | 说明 |
|---|---|---|---|
| `a, b` | in | 32 | 操作数/立即数 |
| `op[4:0]` | in | 5 | 0..9 逻辑/移位、10..13 乘法。**14..17 = div/divu/rem/remu 仅占位**（返回 0）：除法走多周期 `div.v`，执行槽对 div 置 `exec_valid=0`，占位只为"别落到 default 别名成 MULHU" |
| `result[31:0]` | out | 32 | 组合结果（mul 低/高半按 op 选择） |

内部实例化 adder32（add/sub/slt 差分校准）+ mul（`a_signed=(op==mulh‖op==mulhsu)`，`b_signed=(op==mulh)`）；移位/逻辑用 `?:`。**LUI/AUIPC 由 cpu_top 映射为 add**（a=0/pc，b=imm），alu 无需 pc 输入。乘法器输入由 `sel_prod = (op>=10) && (op<=13)` 门控——不收窄到 13 的话，除法占位编码会把整棵华莱士树重新点燃，白白加长执行级路径。

### exec/div.v — 多周期（33 拍），参数 `PRF_SIZE`/`ROB_SIZE`
| name | dir | width | 说明 |
|---|---|---|---|
| `start_valid` | in | 1 | 发起请求；**上层保证 `busy` 期间不再拉起**（靠不释放 RS 条目） |
| `start_op[1:0]` | in | 2 | = func3[1:0]：0=div 1=divu 2=rem 3=remu |
| `start_a, start_b` | in | 32 | 被除数 / 除数 |
| `start_prd` | in | PW | 目的物理寄存器 |
| `start_rob_tag` | in | RW | ROB 条目号 |
| `kill` | in | 1 | 作废**在飞**的那一发（判据见 `docs/plan.md` §15.10.3） |
| `busy` | out | 1 | 忙；此间 `start_valid` 被忽略 |
| `busy_rob_tag` | out | RW | 在飞那发的 rob_tag（发起当拍其 RS 条目已释放，cpu_top 侧无别的副本） |
| `done_valid` | out | 1 | 完成脉冲（**恰好**发起后 33 拍） |
| `done_prd` / `done_rob_tag` / `done_result` | out | PW / RW / 32 | 随 `done_valid` 有效 |

radix-2 **恢复余数**迭代（32 次 + 1 拍输出）。取 `|a|/|b|` 迭代后按符号修正；恢复式 `R ∈ [0,|b|)`
⇒ `Rs = {R, A[31]}` 33 位**无符号**即可，无末尾修正步。除零（`b==0` → 商全 1 / 余 = 被除数）与
`INT_MIN/-1` 需显式 mux。**为什么不做单周期**：`mul` 自身 F2F 已 2.0879 ns（`docs/plan.md` §13.5），
32 级借位链叠上去必破 300 MHz 硬性前提。`kill` 判据写成 `kill && busy_r`——空闲时不得吞掉同拍的新
`start`（那条指令的 RS 条目已被上层清掉，漏收即永久死锁）。

### exec/branch.v — 纯组合，无参数
| name | dir | width | 说明 |
|---|---|---|---|
| `rs1, rs2` | in | 32 | 比较操作数 |
| `pc, imm` | in | 32 | 目标计算（imm 已符号扩展） |
| `mode[1:0]` | in | 2 | 0=branch 1=jal 2=jalr（决定 target 源与 taken） |
| `br_op[2:0]` | in | 3 | beq bne blt bge bltu bgeu（仅 mode=0 有意义） |
| `taken` | out | 1 | mode=1/2 时恒 1；branch 时比较结果 |
| `target[31:0]` | out | 32 | branch/jal: pc+imm；jalr: rs1+imm&~1 |
| `link[31:0]` | out | 32 | pc+4（jal/jalr 的 CDB 结果） |

内部 3 个 adder32：比较差分（beq=全0，blt=符号位，bltu=借位）、pc+imm、pc+4。

### front/bht.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `counters[2*BHT_SIZE-1:0]` | out | 2×BHT_SIZE | fetch（W 口按 pc 索引选） | 全阵列读出（便宜） |
| `upd_req[W-1:0]` | in | W | cpu_top（执行槽 i） | 更新请求（仅条件分支） |
| `upd_idx[W-1:0]` | in | W×BW | cpu_top | `(pc>>2) % BHT_SIZE` |
| `upd_taken[W-1:0]` | in | W | cpu_top | 实际方向 |

2-bit 饱和计数，复位 `2'b01`（弱不取）；W 写口按**槽序正序**应用（同索引时**高槽/更年轻者最后写 → 它赢**，与 rat 的"后槽覆盖"约定一致；各槽新值都取自旧值快照，故同批同索引别名时只体现最年轻分支的一次更新，属简化）。

### front/ras.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `top[W*32-1:0]` | out | 32×W | fetch | `top[i]` = 处理 ops[0..i-1] 后的栈顶（组合链） |
| `head_snap[W*RA-1:0]` | out | RA×W | cpu_top（误预测恢复） | `head_snap[i]` = 处理 ops[0..i-1] 后 head |
| `ops[W*2-1:0]` | in | 2×W | fetch | 每条：0=无 1=push 2=pop（call=push pc+4，ret=pop） |
| `push_val[W*32-1:0]` | in | 32×W | fetch | push 值（pc+4） |
| `restore_valid, restore_head` | in | 1/RA | cpu_top | 误预测 head 恢复（优先级 > fetch ops） |

内部：栈数组 + head 寄存器；W 路顺序链计算 `top[i]`/`head_snap[i]`；空栈 pop 忽略、满栈 push 丢弃。**每批的 RAS 操作在取指时一次性应用**（stall 保持批时不再重复应用）。

**深度与复位（实现后修正）**：head 只有 `RA = $clog2(RAS_SIZE)` 位（`head_snap` 要原样喂给恢复通路，宽度必须可表示），故满栈判定为 `head == RAS_SIZE-1` → **有效深度 RAS_SIZE-1 条**（原 `head != RAS_SIZE` 的判据在 head 截断到 0 后失效，第 9 次 push 会覆盖栈底）。栈数组随复位清零：head 被 restore 到尚未 push 过的位置时会读出未初始化值（仿真 X / 硬件垃圾目标），清零后与"空栈预测 0"一致，仅损失一次预测精度（误预测可恢复）。

### front/fetch.v（内部实例化 bht + ras）
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `f2i_valid[W-1:0]` | out | W | cpu_top→decode | 寄存器输出；stall 保持，redirect 清 0 |
| `f2i_raw[W-1:0]` | out | 32×W | 同上 | 指令字 |
| `f2i_pc[W-1:0]` | out | 32×W | 同上 | 每指令 PC |
| `f2i_pred_taken[W-1:0]` | out | W | 同上 | BHT 预测（随指令流动） |
| `f2i_pred_target[W-1:0]` | out | 32×W | 同上 | jal=pc+imm；ret=ras.top；其他 jalr=pc+4 |
| `f2i_ras_snap[W*RA-1:0]` | out | RA×W | 同上 | 取指时 ras head（仅 branch/jalr 有意义） |
| `imem_addr[W*32-1:0]` | out | 32×W | 存储 | **本拍要请求的批地址**（= 需求地址，不是"上次请求的地址"） |
| `inst_data[W*32-1:0]` | in | 32×W | 存储 | 上一拍 `imem_addr` 处的指令（可带任意延迟） |
| `imem_valid` | in | 1 | 存储 | `inst_data` 确实是取自 `imem_addr_d` 的新数据（延迟未到时为 0，此时 `inst_data` 是旧值） |
| `imem_hit` | in | 1 | 存储 | 本拍 `imem_addr` 上**整批 W 个字**都已可取（用于判断能否把请求提前一批；固定 1 拍存储恒为 1） |
| `stall` | in | 1 | cpu_top | 队列满 / walker / halt → 不发起新请求（PC 最多回退到 exp_pc） |
| `redirect_valid, redirect_pc` | in | 1/32 | cpu_top | 误预测 → 下拍从 redirect_pc 取，清空当前批 |
| `halt` | in | 1 | cpu_top | 锁存停止取指 |

内部：PC 寄存器 → imem 地址；预测：BHT 查 `(pc>>2)%BHT_SIZE`，jal 恒 taken，ret（rd=0&&rs1=1）→ ras.top+pop，call（rd=1）→ push pc+4；branch/jal 的预测目标需要 B 型/J 型 imm 符号扩展（与 decode 重复 ~6 行，注释注明保持同步——参考同款做法）。fetch 级 = 1 拍（PC 在 T 拍、指令 T+1 拍到达，含流水寄存器）。

**取指握手（变长延迟版定稿，取代"请求标签"方案）**：只用**地址比对**判到达，不用 tag/计数器。
- `imem_addr_d` = 上一拍锁存的地址 = 本拍 `inst_data` 所属地址；`imem_valid` 区分"数据真回来了"与"仍是旧值"
- `exp_pc_r` = 下一条要交付给 decode 的批地址；`arr_ok = (imem_addr_d[0] == exp_pc_r)` 才算"这一批是想要的"
- 接收条件 `cap_w = arr_ok && cap_ok && !halt && imem_valid`，`cap_ok = 批寄存器空 || 本拍批被发射`（`batch_taken = |f2i_valid && !stall`）
- **核心抽象：`imem_addr` 是"本拍要请求的批地址"（需求地址）**，不是"上一拍请求过的地址"。数据没到就把请求
  **停在 `exp_pc_r` 上重复请求它**，于是存储查找的地址恒等于期望地址，数据一到即接收。
  只有 `imem_hit`（期望批**整批 W 个字**都已可取 —— 必须与接收侧的 `imem_valid = &slot_hit` 同口径）成立时，
  才允许把请求**提前一批**：`pc_lead_w = (pc_r == exp_pc_r) && imem_hit && !stall`。
  不加 `imem_hit` 门控而"无条件落后就补发"会致命：数据未回的拍盲目超前 → 下一拍到达的不是期望批 → 退回 →
  再超前 → **请求地址每拍翻转、预取流永远重启、一条 AR 也发不出去**（实测见 `docs/plan.md` §14.3 缺陷 1）。
  **口径必须整批**：W≥2 下若只比批首（"槽 0 到了"），槽 1 未到时也会超前 → 下一拍 `arr_ok` 成立但
  `imem_valid=0` → 退回 → 又超前 → 同样每拍翻转（实测见 `docs/plan.md` §15.10.18）；W=1 时整批 ≡ 批首
- 不变量：**`pc_r ∈ { exp_pc_r, exp_pc_r + 4W }`**（相等 = 下一批请求还没发出；差一批 = 已有一条在飞）
- 好处：stall 保持 PC 造成的重复请求、预测跳转/redirect 拍的在途错路读出，全部被地址比对自动丢弃，无需任何作废信号（省 4 个寄存器与计数对齐逻辑）；反之若到达的正是期望地址（例如 redirect 目标恰在途）也照收不误
- **稳态时序**：`pc_r = exp_pc_r + 4W`（请求领先 1 批），每拍交付 1 批；一次预测跳转 = 1 拍气泡（在途的顺序批被丢弃）
- **满批丢弃回退（rewind）**：stall 期间到达的正是 `exp_pc` 批却因批寄存器满被丢弃 → 该批若不管就永久丢失。故丢弃拍把 PC **回退到 `exp_pc_r`** 重取（该分支被 `pc_next` 的默认分支覆盖，单独删掉不报错——保留为使本条自身完整）
- **`pred_ok_w` 也必须含 `imem_valid`**：它只看地址，而 `imem_valid==0` 时 `inst_data` 是旧的，用陈旧指令的预测目标改 PC 就是被垃圾指令劫持 PC
- 固定 1 拍存储（`core/memory.v`）下 `imem_hit` 恒 1 ⇒ 上述规则与旧规则**逐拍等价**（`tb_fetch` 逐拍比对过）
- **halt 冻结**：`cap_w` 含 `!halt`，halt 期不接收、`exp_pc` 不动（保持 `pc_r >= exp_pc` 不变量；halt 为终止态，无恢复语义）
- **RAS 操作只对"取指路径上的前缀"驱动**：`ras_ops_w[g] = fetch_ok && !pt_c[g] ? ... : 0`，`pt_c[g]` = 槽 g 之前已有预测跳转。截断后的槽属错误路径（稍后从跳转目标重新取），若也 push/pop 会污染 RAS（实测会把 head 弹错、并让 ret 读到未写过的栈项）
- **PC/exp 跟随"首个预测跳转"**（低槽优先，不是最后一个）：同一批内第二个预测跳转在截断之后，不能让它的目标改写 PC

### front/decode.v — 纯组合无状态
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `raw[W*32-1:0]` | in | 32×W | fetch | 指令字 |
| `d_valid[W-1:0]` | in | W | fetch | 有效 |
| `opcode, func3, func7` | out | 7×W / 3×W / 7×W | cpu_top | 原始字段 |
| `rd, rs1, rs2` | out | 5×W each | cpu_top | 寄存器号 |
| `imm[W*32-1:0]` | out | 32×W | cpu_top | 6 种类型符号扩展 |
| `is_alu, is_mul, is_load, is_store, is_branch, is_jal, is_jalr, is_lui, is_auipc` | out | 1×W each | cpu_top | 互斥单热组 |
| `writes_rd[W-1:0]` | out | W | cpu_top | rd≠0 且非 store/branch |
| `mem_width[W*2-1:0]` | out | 2×W | cpu_top→lsq | 1/2/4 字节 |
| `mem_unsigned[W-1:0]` | out | W | cpu_top→lsq | load 无符号（func3[2]） |

非法指令 → 全部类别 0（按 NOP 处理，执行/广播/无害提交）。

### core/rat.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `map_out1[W*PW-1:0], map_out2[W*PW-1:0]` | out | PW×W each | cpu_top | **含批内转发**的组合读口（最后匹配者赢） |
| `map_arch[32*PW-1:0]` | out | PW×32 | cpu_top | 全阵列（调试 / ret_val 采样 map_arch[10]） |
| `read_rs1[W*5-1:0], read_rs2[W*5-1:0]` | in | 5×W each | cpu_top | 读地址（issue 批的 rs1/rs2） |
| `rename_valid[W-1:0]` | in | W | cpu_top | 第 i 条重命名（prefix：valid[i] 蕴含 valid[i-1]） |
| `rename_rd[W*5-1:0], rename_new[W*PW-1:0]` | in | 5×W / PW×W | cpu_top | 目的/新映射 |
| `flush_valid[W-1:0], flush_rd[W*5-1:0], flush_old[W*PW-1:0]` | in | W / 5×W / PW×W | cpu_top（walker） | 回滚（写优先级 > rename） |

内部：32×PW 寄存器，复位 `map[i]=i`（恒等）；批内转发：`map_out1[i] = 前面 rename[j] (j<i) 且 rd[j]==rs1 ? new[j] : map[rs1]`。

### core/free_list.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `alloc_val[W*PW-1:0]` | out | PW×W | cpu_top | 槽 i = 栈顶起第 pc_pre[i] 个空闲 preg（组合；仅 pop_req[i] 时有效；绝不分配 preg < 32） |
| `count_out[PCW-1:0]` | out | `$clog2(PRF_SIZE+1)` | cpu_top | 本拍可分配量（= 栈内空闲数 sp；不含本拍 push） |
| `pop_req[W-1:0]` | in | W | cpu_top | 弹出（逐槽；同拍多槽按槽序取栈顶起连续项） |
| `push_valid[W-1:0], push_preg[W*PW-1:0]` | in | W / PW×W | cpu_top | 回收（commit 与 walker 复用同一端口——二者互斥：walker 期间 commit 冻结） |

复位：sp=PRF_SIZE-32，池内装入 preg 32..PRF_SIZE-1（栈顶=32）。**每个 preg 每生命周期恰好写一次**（free list 只在 producer 提交后释放）。

实现演进与**已证伪方案**（时间线见 `docs/plan.md` §1/§15.10.16/§15.10.20）：
- ~~环形池 `alloc_val[i] = head + i`（组合计算、不存值）+ `count += push 数`~~（**不成立**，两个独立缺陷）：
  ① 回收请求含恒等映射区 preg（<32），环形池表示不了却被计入 count ⇒ 计数虚高；
  ② 隐含"回收顺序 = 分配顺序"假设，而 commit 释放的 `old_pnum` 到达次序任意 ⇒ `head + i` 算出仍在用的 preg。
- 现行 = **LIFO 栈 + 真实存储**（FREE_NUM × PW 位）：回收顺序任意都正确。
  同拍 push/pop：pop 读 `pool[sp-1-pc_pre]`、push 写 `pool[sp-pop_cnt+ps_pre]`（落在本拍 pop 腾出的槽位）。
  **易错点**：写成 `pool[sp+ps_pre]`（栈顶之上）会让腾出的槽位残留旧值，下拍 pop 读到已分配的 preg（实际踩到）。
  `count_out = sp`（不含本拍 push，无同拍旁路）⇒ 池空时多 1 拍气泡，换 pop 读索引恒在 `[0, sp)` 内。
- `push_ok[c] = push_valid[c] && (push_preg[c] != 0)`：**只挡 preg 0**（x0 恒等映射，永不复用）。
  早期写作 `push_preg >= 32` 是错的：恒等映射区被永久排除在回收之外 ⇒ 可用池 = 32 − #映射在池区
  ⇒ 一条全写指令的批在池不足 W 项时永久发不出（W=4 `correctness_hanoi` 实测死锁；W≤3 恰好不越界，
  是幸存者偏差）。**此条对 W=1 同样生效**。
- **PRF_SIZE 下限 = 63（精确值），工程取 64**：一条指令分配的 preg 要等它写的架构寄存器**被再次写**
  才随下一个写者的 `old_pnum` 回池 ⇒ "被架构映射占住的 preg 数"单调不减，静默时恒有
  `sp = FREE_NUM − #{x : map_arch[x] >= 32}`，故**永久死锁 ⇔ 该计数 == FREE_NUM**；x0 只读不写
  ⇒ 计数上界 31。实测 `PRF_SIZE=40` 在写 ≥6 个目的寄存器的程序上挂死，**与 `ROB_SIZE` 无关**。
  ⇒ PRF_SIZE 消融只能向上（64/96/128），`PRF=40` 是**参数不可行点，不是缺陷**。
- 代价：FREE_NUM×PW 触发器（32×6 ≈ 56 µm²）+ 读 mux/写译码；面积阶段可再评估（位图 + 优先编码器）。

### core/rob.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `head, last` | out | RW/RW | cpu_top | 环形指针 |
| `empty, full` | out | 1/1 | cpu_top | 空/满 |
| `free_count[RCW-1:0]` | out | `$clog2(ROB_SIZE+1)` | cpu_top | 当前空闲（本拍提交数由 cpu_top 相加） |
| `ready[ROB_SIZE]`, `opcode[ROB_SIZE]`, `rd[ROB_SIZE]` | out | 1/7/5 ×ROB_SIZE | cpu_top | 完成位/类别/目的 |
| `new_pnum[ROB_SIZE]`, `old_pnum[ROB_SIZE]` | out | PW×ROB_SIZE | cpu_top | 新旧物理号（walker 与 commit 用） |
| `lsq_tag[ROB_SIZE]`, `ins_raw[ROB_SIZE]` | out | LW/32 ×ROB_SIZE | cpu_top | 提交时取 store 条目/终止检测 |
| `push_valid[W-1:0]` + `push_*`（opcode/rd/new/old/lsq/ins_raw） | in | (7+5+PW+PW+LW+32)×W | cpu_top | 发射（push 时清该条目 ready） |
| `set_head_valid, set_head_val` | in | 1/RW | cpu_top | 提交推进 |
| `set_last_valid, set_last_val` | in | 1/RW | cpu_top | flush 截断（优先级最高；head 若在窗口内收敛） |
| `set_ready_req[ROB_SIZE]` | in | ROB_SIZE | cpu_top（CDB 汇出） | 完成置位（唯一写者） |

写优先级：set_last > set_head > set_ready > push。

### core/rs.v（选择器在内部，无外部 clear 口——选中自清）
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `sel_valid[W-1:0], sel_idx[W*SRW-1:0]` | out | W / SRW×W | cpu_top | 年龄优先仲裁（槽 0 最老；就绪 = prs==0‖CDB 命中‖rt_ready；槽间互斥，同年龄低槽赢） |
| `free_count[CSW-1:0]` | out | `$clog2(RS_SIZE+1)` | cpu_top | 当前空槽（本拍选中数由 cpu_top 相加） |
| `entry_*[RS_SIZE]`（valid/opcode/func3/func7/prs1/prs2/prd/pc/imm/lsq_tag/rob_tag/pred_taken/pred_target/ras_snap） | out | 全宽×RS_SIZE | cpu_top | 按 sel_idx 取字段 |
| `rt_ready[PRF_SIZE]` | in | PRF_SIZE | ready_table | 就绪位全阵列 |
| `cdb_tag[(W+1)*PW-1:0], cdb_slot_valid[W:0]` | in | PW×(W+1) / (W+1) | cpu_top（CDB 槽标签） | 旁路就绪判断（**load 槽 valid = load 完成，执行槽 valid = sel_valid && !is_load**——load 执行槽的 prd 是"地址"，依赖者不得匹配） |
| `rob_head` | in | RW | cpu_top | 年龄计算 |
| `push_valid[W-1:0]` + `push_*`（同 entry 字段） | in | 全宽×W | cpu_top | 发射（扫描分配空闲槽） |
| `flush_mask[RS_SIZE]` | in | RS_SIZE | cpu_top | 窗口内条目失效 |

写优先级：flush_mask > 自清（选中）> push。

### core/ready_table.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `ready[PRF_SIZE]` | out | PRF_SIZE | rs.v | 就绪向量 |
| `set_req[PRF_SIZE]` | in | PRF_SIZE | cpu_top（CDB 汇出） | 置位 |
| `clear_req[PRF_SIZE]` | in | PRF_SIZE | cpu_top（rename） | 清零（新映射未就绪） |
| `flush_clear_req[PRF_SIZE]` | in | PRF_SIZE | cpu_top（walker） | 回滚清零 |

优先级：flush_clear > clear > set（同 preg 同拍 set+clear 时 clear 赢——刚被重新命名的 preg 新值未就绪）。复位：0..31 置 1（恒等映射），其余 0；preg 0 常就绪。

### core/prf.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `data_out1[W*32-1:0], data_out2[W*32-1:0]` | out | 32×W each | cpu_top | **索引读** 2W 口 |
| `rd1_preg[W*PW-1:0], rd2_preg[W*PW-1:0]` | in | PW×W each | cpu_top | 读地址（执行槽操作数；槽 0 读口复用为 ret_val 采样） |
| `wr_valid[W:0], wr_preg[(W+1)*PW-1:0], wr_data[(W+1)*32-1:0]` | in | (W+1)/PW/32 ×(W+1) | cpu_top（CDB 汇出） | 写回（W+1 口） |

复位全 0；**读口 preg==0 短路输出 0**（x0 硬连线，模块内部实现）。写回仅 CDB 单一来源（load 完成也经 CDB 槽 W）。

### core/cdb.v — 纯组合（写回扇出逻辑）
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `exec_valid[W-1:0], exec_prd[W*PW-1:0], exec_result[W*32-1:0], exec_rob_tag[W*RW-1:0], exec_rob_wr[W-1:0]` | in | (1+PW+32+RW+1)×W | cpu_top（执行槽） | 生产者 A |
| `load_valid, load_prd, load_result, load_rob_tag, load_rob_wr` | in | 1+PW+32+RW+1 | lsq.v（load 完成） | 生产者 B（每周期 ≤1 个） |
| `div_valid, div_prd, div_result, div_rob_tag` | in | 1+PW+32+RW | div.v（除法完成） | 生产者 C（每周期 ≤1 个；隐含 `rob_wr=1`，除法必写 rd） |
| `prf_valid[W+1:0], prf_preg[(W+2)*PW-1:0], prf_data[(W+2)*32-1:0]` | out | (W+2)/PW/32 ×(W+2) | prf.v | 写回口 |
| `rt_set_req[PRF_SIZE]` | out | PRF_SIZE | ready_table.v | 置位掩码 |
| `rob_ready_req[ROB_SIZE]` | out | ROB_SIZE | rob.v | ROB ready 掩码（`rob_wr` 槽按 tag 置位） |

内部全部 `assign`（prd==0 的槽不写 PRF 不置 ready；rob_wr 槽置 ROB）。槽 `0..W-1` = 执行，槽 `W` = load，槽 `W+1` = 除法完成。

> 槽 `W`/`W+1` **不参与同拍旁路**：`ready_table` 是寄存器，被唤醒的依赖者最早下拍才被选中，那时 PRF 已写入 ⇒ 除法结果经 PRF 消费即可，`rs.v`/`execute_slot.v` 的 `cdb_slot_valid`/`cdb_tag` 宽度**不变**。
> 除法**不与 load 共用**槽 `W`：load 完成是组合脉冲、不可延迟 ⇒ 只能 load 优先 ⇒ 除法在 load 密集循环里会被长期饿死。

### core/lsq.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `head, last` | out | LW/LW | cpu_top | 环形指针（head 内部推进跳过失效项） |
| `full` | out | 1 | cpu_top | 满 |
| `free_count[LCW-1:0]` | out | `$clog2(LSQ_SIZE+1)` | cpu_top | 当前空闲（本拍失效数由 cpu_top 相加） |
| `valid[LSQ_SIZE], is_load[LSQ_SIZE], addr_ready[LSQ_SIZE], data_ready[LSQ_SIZE]` | out | 1×LSQ_SIZE | cpu_top（发起判断） | 状态 |
| `addr/data[LSQ_SIZE]`, `rob_tag[LSQ_SIZE]`, `prs2_or_prd[LSQ_SIZE]`, `width[LSQ_SIZE]`, `is_unsigned[LSQ_SIZE]` | out | (32+32+RW+PW+2+1)×LSQ_SIZE | cpu_top（提交读 store 数据） | 内容（store 存 rs2 的 preg；load 存目的 preg） |
| `rob_head` | in | RW | cpu_top | 年龄比较 |
| `push_valid[W-1:0]` + `push_*`（rob_tag/prs2_or_prd/width/is_unsigned/is_load） | in | (RW+PW+2+1+1)×W | cpu_top | 发射 memop |
| `set_addr_req[W-1:0], set_addr_idx[W*LW-1:0], set_addr_val[W*32-1:0]` | in | (1+LW+32)×W | cpu_top（执行槽） | 地址就绪（地址 = alu 结果） |
| `set_data_req[W-1:0], set_data_idx[W*LW-1:0], set_data_val[W*32-1:0]` | in | (1+LW+32)×W | cpu_top（执行槽） | store 数据就绪（仅 store） |
| `flush_mask[LSQ_SIZE]` | in | LSQ_SIZE | cpu_top | 窗口失效 |
| `invalidate[LSQ_SIZE]` | in | LSQ_SIZE | cpu_top（commit，**延迟一拍**寄存） | store/load 提交后失效；延迟一拍的原因见 `docs/plan.md` §二十四（load 完成数据在沿前采样，条目须在那一拍仍可供前向） |
| `mem_done_valid, mem_done_idx, mem_done_data` | in | 1/LW/32 | memory | load 完成 |
| `ld_start_valid, ld_start_addr, ld_start_width, ld_start_idx` | out | 1/32/2/LW | memory | 发起（**内部组合**：最老未完成 load + 所有更老 store 已执行 + memory 有空槽） |
| `ld_busy` | in | 1 | memory | 飞行槽满 |
| `load_cdb_valid, load_cdb_prd, load_cdb_result, load_cdb_rob_tag, load_cdb_rob_wr` | out | 1+PW+32+RW+1 | cdb.v | load 完成 → CDB 槽 W |

**lsq.v 内部**：完成合并（mem_done → 检查更老 store 全部 data_ready[发起时已保证] → 字节合并覆盖 → 符号扩展 → 输出 load_cdb_*）；load 完成后条目保留到提交。写优先级：flush > invalidate(commit) > push > set_*。

**发起/在飞语义（§8.2 修复后定稿，`issued_r` 为新增状态）**：
- 每槽一位 `issued_r`，**发起被 `memory` 接受即置位，完成脉冲回来才清** —— 这是"不重复发起"的唯一依据。
  只靠 `done_r[idx]` 不够：从发起到完成之间有整个 `MEM_LATENCY` 窗口，同一条 load 会被反复发起、
  灌满全部 `MEM_INFLIGHT` 个飞行槽（缺陷 A，§8.2）。
- **在飞条目不可被判 `dead`**：`dead = ~valid_r | flush_mask | invalidate` 再排除在飞项
  ⇒ 槽位在完成回来前不可复用，完成当拍读到的 `prs2_or_prd_r`/`addr_r`/`width_r`/`rob_tag_r`
  必然还属于原请求（灭缺陷 B：槽位复用导致陈旧完成写坏目的寄存器）。
  代价：flush 时若恰有在飞 load，head 最多阻塞 `MEM_LATENCY` 拍（飞行槽必定倒计时到期，不会死锁）。
- `cand` 额外加 `!kill`（本拍就被 flush/失效的条目不发起）：否则 `issued` 与 `valid` 同拍翻转，
  而 head 的 `skip` 用的仍是边沿前的 `issued=0` ⇒ 条目照样被跳过、槽位照样被复用。
- 端口无变化；新增 `LSQ_SIZE` 个触发器（默认 16）。

### core/memory.v
> **现状（2026-09-24）**：**仅 TB 使用**。`student_top` 不例化它（存储换成 `core/mem_subsystem.v` + AXI），
> 它留在 `verilog/filelist.f` 里只为让单元/整机 TB 共用一份源清单（综合时被 `hierarchy -top` 剪掉）。
> 它的取指口是"固定 1 拍"，对应 `imem_valid=1` / `imem_hit=1` 的退化情形。

| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `inst_data[W*32-1:0]` | out | 32×W | fetch | **同步读**（imem_addr 内部寄存一拍） |
| `imem_addr[W*32-1:0]` | in | 32×W | fetch | 取指地址（pc 基址 + 4i） |
| `ld_start_valid/addr/width/idx` | in | 1/32/2/LW | lsq.v | 发起（每周期 ≤1） |
| `ld_done_valid, ld_done_idx, ld_done_data` | out | 1/LW/32 | lsq.v | 倒计时到期（每周期 ≤1） |
| `ld_busy` | out | 1 | lsq.v | 飞行槽满 |
| `sw_valid/addr/data/width` | in | 1/32/32/2 | cpu_top（commit） | store 直写（每周期 ≤1，posedge 按字节写） |
| `init_valid/addr/data` | in | 1/32/8 | TB | $readmemh 加载（逐字节） |

内部：`reg [7:0] mem[MEM_SIZE]`（仿真直读、可标注 ram 风格）；飞行槽（MEM_INFLIGHT 个）存 {addr, width, lsq_idx, 倒计时=MEM_LATENCY}，到期 `ld_done` 脉冲 + 同步读打包数据；被 flush 的 load 完成脉冲由 lsq.v 按条目有效性丢弃（飞行槽不取消）。

### core/axi_lite_master.v（新增，纯协议层）
只做 5 通道握手与 VALID 稳定性，不含任何语义（子字抽取/MMIO 分流都在上层）：
`{ar,r,aw,w,b}valid/ready` + `araddr/rdata/rresp/awaddr/wdata/wstrb/bresp` + 内部两对 FIFO
（读：待发 AR 指针 + 待收 R 指针，**R 严格按 AR 顺序**；写：`{addr,data,strb}` 同序）。
- **`rready`/`bready` 恒 `1'b1`**（不得被复位或状态门控）：`bready` 不驱动 ⇒ 停机 store 的 B 永不握手
  ⇒ `done` 永假 ⇒ 每条 case 都超时（最容易"功能全对却零分"的一处）。
- `araddr` 取自 FIFO 条目，而条目只在握手时才动 ⇒ **VALID 稳定性结构上免费获得**（不可能组合依赖 `ready`）。
- AW 与 W 由**同一指针**驱动、两通道都握手才推进 ⇒ **AW 序 == W 序 == 提交序**，
  满足从机"`aw.front()` 配 `w.front()`"的位置配对（`sim.cpp:85-88`）。
- 异步低有效复位（ASAP7 库只有异步复位触发器）。

### core/mem_subsystem.v（新增，CPU 侧端口与 `memory.v:10-38` 逐一对位）
内部：**I-cache**（`core/icache.v`：IC_SIZE 字节直接映射行缓存 + 行预取；取指口对外仍是"本拍批地址"语义）、
**D-cache**（`core/dcache.v`：DC_SIZE 字节 / DC_LINE_WORDS 字行 / DC_WAYS 路组相联，写回 + 脏位）、
**load 适配**（子字抽取 + miss 队列，推送时写、回包时读 + 按序记账）、
**已提交 store 队列**（`SQ_DEPTH`，补 `commit → B 握手` 之间的可见性空洞）、
**三路 AR 仲裁**（需求 load > 取指填充 > D 填充，AXI 读只有 1 AR/拍）。关键契约：

| 契约 | 内容 |
|---|---|
| 取指 | `imem_hit` / `imem_valid` 的口径是**整批 W 个字**（见 fetch 一节）；I-cache 命中 1 拍，未命中走填充 |
| `imem_valid` | 仅当"本拍 `inst_data` 对应的地址"与回包地址相等时才拉高 |
| `ld_busy==0` | **必须当场兑现**：`lsq.v` 的 `ld_start_valid` 组合自 `!ld_busy` 且收到即置 `issued_r`；反悔 ⇒ 该条目永久在飞 ⇒ head 卡死 ⇒ 全机死锁 |
| 完成脉冲 | 每个被接受的 load **恰好**一个 `ld_done_valid`（`rresp` **不参与门控** —— LSQ 没有错误口） |
| 子字 | `araddr` 强制 4 字节对齐；回包右移 `8*addr[1:0]` 后**零扩展**（符号扩展由 `lsq.v` 做）；⚠ 不支持跨 4 字节边界的非对齐访问 |
| store 可见性 | 合并层次 **`memory` < `store_queue` < `LSQ`**；队列条目退休条件 = **B 已握手 _且_ 该 B 到达时在飞的读都已返回**（只等 B 不够：那些读可能在该 store 落盘前就被服务）。提交与完成同拍的那条 store 由**上层 LSQ** 兜（它在 posedge 才失效，且必然更老）—— 本模块**不**重复并入，并入即组合环（`docs/plan.md` §14.3 缺陷 2） |
| 背压 | 队列满 ⇒ `sw_ready=0` ⇒ `cpu_top` 压住该拍提交（提交路径唯一的背压点） |

### top/cpu_top.v — 调试输出 + 存储接口（原内部 `u_mem` 已提为端口）
| name | dir | width | 说明 |
|---|---|---|---|
| `clk, rst_n` | in | 1/1 | 时钟/异步低有效复位 |
| `halt` | out | 1 | 终止已提交（TERM marker **或** MMIO 停机） |
| `ret_val[7:0]` | out | 8 | rob 排空后 `prf[rat.map_arch[10]] & 0xFF` |
| `commit_count[31:0], flush_count[31:0], branch_count[31:0]` | out | 32×3 | 性能/消融统计 |
| `rob_head[RW-1:0], rob_ready_head` | out | RW/1 | 调试 |
| `imem_addr / inst_data / imem_valid / imem_hit` | out/in | 32W / 32W / 1 / 1 | 取指存储口（见 fetch 一节） |
| `ld_start_valid/addr/width/idx`、`ld_done_valid/idx/data`、`ld_busy` | out/in | — | load 口（发起 ≤1/周期、完成 ≤1/周期） |
| `sw_valid/addr/data/width`、`sw_ready` | out/in | — | store 口（提交级 ≤1/周期；`sw_ready=0` ⇒ 本拍不提交该 store） |

**内部组合块**（assign/generate，无新增模块）：
- **B3-D 执行槽字段取**（D 级）：按 `rs.sel_idx` 做 one-hot → 对 144 位打包条目做 AND-OR 取字段（opcode/func3/func7/prs/prd/pc/imm/pred/rob_tag/lsq_tag/ras_snap）
- **B1+B3-Q 操作数获取与执行**（Q 级，晚 D 级一拍）：`op = (prs==0)?0 : (cdb 槽标签匹配 ? 槽结果 : (rt_ready[prs] ? prf 索引读 : 0))`——读口地址由 D 级**锁存**的 `sel_all_q` 驱动 → 槽内 alu/branch。
  切点寄存器 144+1 位（≈80 µm²）；D→Q 移交的扣住规则见 `execute_slot.v` 文件头四条不变量（RS 条目在入选当拍即被清 ⇒ 只能扣流水寄存器；`q_freeze` 与门控 `rs_clear` 的 `pipe_stall` 必须同条件；误预测当拍**清空**而非冻结）
- **B3-W 写回登记**（W 级，晚 Q 级一拍，114 位）：只登记**消费者侧产物** —— 推 CDB 的 `result`/`prd`/`rob_tag`、推 LSQ 的 `addr`/`data`/`lsq_tag`，以及 valid/addr_req/data_req 三个 strobe（`q_freeze ? 0 : in` 的普通 mux，其余 111 位使能恰为 `!q_freeze`）。
  加它的**目的**是把"操作数获取+执行"与"写回驱动"拆开，把关键路径的**健康逻辑**压进 300 MHz 预算（实测 healthy_ns 4.0173 → 3.2339 ns < 3.333 ns，上限 A = 309 MHz）；
  但实测**总长反而翻倍**（11.7275 → 25.0176 ns），因为 ABC 把 `rs.v` 的写使能 CSE 成扇出 1088 的共享节点 —— 归因见 `docs/plan.md` §15.10.14
- B2 发射组合：W 条 prefix 门控（条件：rob/rs 有空间 && (!writes_rd ‖ free_list 够) && (!memop ‖ lsq 有空间)）；rat rename W + free_list pop W + ready_table clear W + rob/rs/lsq push W
- B4 误预测检测（Q 级）：branch: `taken != pred_taken`；jalr: `target != pred_target`；**多槽同拍误预测 → 取最老 tag**；同时驱动 fetch 重定向 + bht 更新 + ras 恢复 + rs/lsq flush_mask + rob set_last；**misp 周期抑制 issue**（见陷阱 #11）
- B5 walker FSM（flushing/walk_ptr/flush_fs）：每周期 W 条从 last 向 fs 回滚（rat.flush + free_list push new_pnum + ready_table flush_clear）；中途新误预测（更老）→ 扩展范围；walker 期间：issue 全抑制 + fetch stall + **commit 冻结**
- B6 提交组合：ROB head 连续就绪，每周期 ≤W 条、**store ≤1**（第一个 store 之后截断本批）；free_list push（`new_pnum!=0` 的条目 push old_pnum）；store → memory.sw + lsq.invalidate；load → lsq.invalidate；标记指令（raw==TERM_RAW）提交 → halt 锁存
- B7 无（lsq.v 内部）；B8 load 完成 → lsq.v 内部推 cdb 槽 W

## 关键握手协议要点

- **发射**：fetch 批（W 条）**全批 or 不批**（f2i_valid 全 0 或全 1）；保持至全部发射或重定向；RAS 操作在取指时一次性应用；批内 rename 经 RAT 组合前递
- **执行**：rs.v 每周期选 W 条（年龄优先、操作数可获取）；同拍背靠背依赖经 CDB 旁路（组合无环——执行槽 j 的操作数只可能依赖更老槽 i<j 的结果，按年龄构成 DAG）
- **提交**：walk 期间冻结；store 提交 1/周期上限（头阻塞；W=2 双 store 在头时第 2 个下拍提交）
- **flush**：误预测同拍完成取指重定向 + ROB 截断 + RS/LSQ 窗口失效 + RAS head 恢复 + 抑制 issue；walker 随后 W 条/周期回滚重命名状态
- **load**：执行算地址 → lsq 发起（排序条件）→ memory 倒计时 → lsq 合并前向 → CDB 槽 W → 提交时失效

## 正确性陷阱清单（实现时对照）

1. 批内 rename 前递（rat 组合读口）——漏则同批后条读到旧映射
2. `writes_rd` 抑制（rd=0/store/branch/标记）——漏则 x0 被重命名
3. 同 preg 同拍 set+clear → clear 赢（ready_table 优先级）
4. flush 时 head 可能已在窗口内 → rob 内部收敛
5. load 完成脉冲与 flush 竞争 → 见 `lsq.v` 的"发起/在飞语义"（§8.2 定稿）：**在飞条目不被判失效、head 不跳过它**（槽位与身份保留到完成回来），故完成当拍读到的地址/宽度/目的寄存器必然还属于原请求；陈旧完成由条目有效性筛掉，不写 CDB。只做"无效丢弃"不够 —— 槽位若在完成前被复用，新请求的元数据会被旧完成当成本次结果写走
6. 同拍多误预测 → 最老 tag；walker 中途扩展不重复回滚（walk_ptr 只递减）
7. 执行槽选择互斥（同年龄低槽赢）、两槽不选同一 RS 条目
8. 同批 2 store 提交 → 第 2 个下拍；同批 2 call → RAS 链保证 top[i] 正确
9. fetch 半批处理：stall 在批边界、redirect 丢弃整批
10. store 前向只覆盖已执行 store；load 发起排序条件（所有更老 store 已执行）不可省
11. **misp 周期抑制 issue**：walker 触发时 walk_ptr 按旧 rob_last 捕获，若 misp 当拍仍发射，错路批会落在 flush 窗口尾部之外 → RAT/preg 泄漏。故 `issue_en` 必须含 `!misp_valid`（fetch 批同时被 redirect 丢弃，无吞吐损失）
12. 陈旧 ready 位（伪竞态）：rename-clear 与 RS push 同 posedge，被推条目下拍才对选择可见，此时 ready 已是 0；free list 中 preg 恒 ready=1 的场景由"老 producer 已提交"保证读旧值正确——无需额外端口，实现时注释说明
13. load 执行槽的 CDB 标签竞态：依赖者会匹配 load 槽 prd（地址）→ `cdb_slot_valid[g] = sel_valid[g] && !is_load`（RS 就绪判断与 exec_valid 同源）

## 目标架构：官方框架对接（Phase C 规格）

> 本节原是 Phase C 的目标规格，**现已全部落地**：C2/C3/C4（`student_top` + AXI4-Lite + MMIO 停机，
> `docs/plan.md` §14）、C1（DIV/DIVU/REM/REMU，§15.10）、C6（I-cache §15.14 / D-cache §15.15）。
> `core/memory.v` 仍留在 `filelist.f` 里**供 TB 复用**（综合被 `hierarchy -top` 剪掉）——这是有意为之，不再计划摘除。
> 面积/频率实测基线见 `docs/plan.md` §二十一/§二十三 与 `docs/timing/results.csv`。
> 凡标「**已验证**」的条目都出自对官方框架源码/文档的实读（`scripts/sim.cpp`、`fakeram.py`、
> `synth.py`、`docs/{axi4-lite,sram}.md`，快照 `/tmp/cpu2026-fw`，上游 main `54fc150`）。
> **本节保留的价值是"为什么这么接"的推理链**；实现细节以 RTL 与 `plan.md` 为准。

### C.1 官方要求 → 落地情况

| 维度 | 官方要求 | 落地 |
|---|---|---|
| 顶层 | **`student_top`**，AXI4-Lite 端口模板固定 | `verilog/top/student_top.v`；`cpu_top` 在其内部，端口与官方模板**无一重合** ⇒ 纯包层 |
| 复位 | 高有效 `reset`，初始化保持 5 拍 | 包层取反为内部 `rst_n`（`wire rst_n = ~reset;`），不给各模块加极性参数 |
| 内存 | 外部 256 MiB AXI4-Lite 从机（`0x00000000`–`0x0fffffff`） | `mem_subsystem` + `axi_lite_master`；`core/memory.v` 仅供 TB（综合时被剪） |
| 延迟 | 从机：最快"握手后下一拍被服务"，服务到响应 **10 拍**（`LATENCY` 默认值） | 未做假设，按变长延迟设计（`imem_hit`/`imem_valid` 真实实现） |
| 终止 | 向 MMIO `0x80000000` 做 32 位 store，退出值 = `WDATA[31:0]` | `cpu_top` 提交级判地址+宽度锁存 `halt`；写照常发到总线（从机自己认地址） |
| ISA | **全 RV32IM**（免除只有 CSR*/ECALL/EBREAK/FENCE/FENCE.I） | 已补齐（DIV/DIVU/REM/REMU 见 `plan.md` §15.10；LB/LBU/LH/LHU 更早） |
| 参数化 | 发射宽度 / ROB / PRF / RS / LSQ / **Cache 容量与相联度** | 全部参数化，见「参数表」；Cache 已落地（`icache.v`/`dcache.v`） |
| 面积/频率 | Yosys+ABC+OpenSTA 到 ASAP7，**SRAM 估算面积计入** | 容器链路 `cpu2026:local`（ASAP7 r28），台账 `docs/timing/results.csv` |

### C.2 层次结构

```
student_top                      ← 官方要求的顶层；复位取反 + 例化 + 端口对接   【已实现】
├── cpu_top                      ← 乱序核（存储侧端口已外露，其余不动）
│   └── 核内各模块                ← front/exec/core（div.v 为 C1 新增，execute_slot 含 D/Q/W 三级）
└── mem_subsystem                ← 存储子系统                              【已实现】
    ├── icache                   ← I 侧直接映射行缓存（IC_SIZE/IC_LINE_WORDS/IC_BYPASS/IC_PREFETCH）【已实现】
    ├── dcache                   ← D 侧组相联行缓存（DC_SIZE/DC_LINE_WORDS/DC_WAYS）           【已实现】
    ├── load 适配                ← 子字抽取 + miss 队列（在推送时写、回包时读）+ 按序记账
    ├── store_queue              ← 已提交未生效的 store（同时是 AXI 写队列）
    ├── AR 仲裁                  ← 需求 load > 取指填充 > D 填充（AXI 读只有 1 AR/拍）
    └── axi_lite_master          ← 纯协议层（5 通道握手 / VALID 稳定性 / 同序 AW-W）
```
（~~原规格里的 `icache / dcache` 与"MMIO 分流在 master 内"两处未按原样落地：本轮不做 Cache~~ ——
**Cache 两处现已落地**（`core/icache.v`、`core/dcache.v`，见 `plan.md` §15.14/§15.15）。
"MMIO 分流"仍未按原样落地且**不打算改**：MMIO 判定放在 `cpu_top` 提交级（只判地址与宽度），
`0x80000000` 的写照常经 store_queue 发到总线 —— 从机自己认这个地址并置 `exit`，CPU 侧不做任何分流。）

### C.3 `student_top` 包层规格（**已验证**）

- 端口**照抄** description.md §顶层模块与 AXI4-Lite 协议 的模板，**一个都不改名**：
  框架的 C++ 驱动直接按名引用 `top.araddr`/`top.rvalid`/…（`scripts/sim.cpp:99-136`）。
- `clock` 端口名固定：综合流程按名取时钟（`synth.py` 用 `--clock-port`，默认 `clock`），
  取不到就报 "must have a one-bit clock input"。
- 包层内容：`wire rst_n = ~reset;` + 例化 `cpu_top` + 例化 `mem_subsystem` + 端口对接。
  `halt` / `exit_value` 只作调试，**不导出到端口**（退出值由从机从 `WDATA` 取，不需要 CPU 提供）。
- **`filelist.f` 的顶层是 `student_top`**；`cpu_top` 仍在列表里（它是子模块）。

**驱动时序与两条入口协议**（**已验证**，`scripts/sim.cpp` + `scripts/{run,testcase,oj_io}.py`）：

| 项 | 事实 |
|---|---|
| 时基 | 驱动**手工翻转** `top.clock`：每 tick `clock=0 → memory.drive(top) → eval → clock=1 → eval`，`memory.step(top, latency)` 在中间调一次；`memory.cycle` 逐 tick 计数 |
| 复位 | `top.reset = 1` 保持 **5 个 tick**，之后置 0（包层里 `~reset` 即可，无需复位同步器） |
| 主循环 | `while (!memory.done && memory.cycle < limit && !context.gotFinish())` ⇒ **RTL 里调 `$finish` 会提前中止且 `done` 未置位，OJ 模式判超时失败**（仿真代码不得进综合路径） |
| 周期上限 | `limit` 默认 **1 000 000**（`--max-cycles`）⇒ 任何 `correctness_*` 必须在 1e6 拍内跑到终止写，否则判 `FAIL: timeout` |
| 入口 A（`make run`） | argv：`sim IMAGE EXPECTED MAX_CYCLES LATENCY [WAVE]`；stdout 打 `PASS/FAIL cycles=… result=… expected=…`，退出码即判据 |
| 入口 B（`make test`/`make perf`，即 **OJ 协议**） | `argc == 1`：stdin = `CPU2026-OJ 1\n{max_cycles} {latency}\n{镜像}\n`；stdout **只许一行** `{退出值}\n`（`compare_output` **不容忍多余输出**，只忽略行尾空白与空行）；`stderr` 打 `CPU2026 cycles=N` —— **`make perf` 的 IPC 分母就是这一行**（取不到直接 `SystemExit`） |
| 判分 | `metrics.json["dynamic_instructions"] ÷ cycles`，对 `perf_*` 取**几何平均**；`expected.txt` 只被 `oj_io.prepare_case` 用来生成 `.ans`，**不进仿真器** |

### C.4 AXI4-Lite master 适配层规格

**从机语义**（**已验证**，`scripts/sim.cpp`）：

| 项 | 语义 |
|---|---|
| 队列 | AR/AW/W/R/B 各 **16 项**；`*ready = !reset && size < 16` |
| 服务时机 | 握手当拍入队，**下一拍起**才可能被服务 ⇒ 最快"握手后下一拍" |
| 服务速率 | 每拍**最多 1 读 + 1 写**；两者同时就绪时**顺序由 LFSR 随机决定**（`:126-129`）⇒ **跨通道顺序无任何保证** |
| 响应延迟 | `due = 服务拍 + latency`（`latency` 默认 10，`--latency` 可调） |
| 读数据 | 总是返回**4 字节对齐整字**（小端零扩展）；**没有子字读**，选字节/半字是 CPU 侧的事 |
| 读错误 | 未对齐 → `rresp=2`(SLVERR) 且 `rdata=0`；越界 → `rresp=3`(DECERR) |
| 写数据 | `wstrb` 逐字节掩码生效；未对齐 → `bresp=2` 且**一个字节都不写**；越界 → `bresp=3` |
| 退出 | `awaddr==0x80000000 && wstrb==4'hf` → `bresp=0` 且 `exit=1`；**`done` 在 B 通道握手那一拍才置位**（`:119-121`） |
| 无 ID | 没有 transaction ID ⇒ R 严格按 AR 的 FIFO 顺序返回，B 按 AW 的 FIFO 顺序返回 |
| `$finish` | 仿真循环的停止条件是 `done \|\| cycle >= limit \|\| gotFinish()`（`:199`） |

> ⚠ **`bready` 必须驱动**（建议恒 1）：`done` 依赖 B 握手，若 `bready` 恒 0，退出 store 的响应永远送不出去 ⇒
> **仿真跑到 `MAX_CYCLES` 超时**，成绩判 FAIL。这是最容易"功能全对却零分"的一处。

**适配层职责**（`cpu_top` 的存储侧端口与 `memory.v` 逐一对位，改动被隔离在包层）：**【已实现】**

1. **子字访问**：load 按 `addr[1:0]` 从 `rdata` 选字节/半字、**零扩展**后回传 ——
   符号扩展由 `lsq.v` 自己做（它知道 `is_unsigned_r`）；store 按 `addr[1:0]` + 宽度生成 `wstrb`
   并左移 `wdata << 8*addr[1:0]`（**不可**直用 `sw_data`）。地址须自然对齐（不满足则是程序 bug）。
2. **按序记账**：读请求用 FIFO 记录 `{lsq_idx, addr}`，R 到达时按 FIFO 出队 demux 回 LSQ ——
   一笔 AR 对应**恰好一个** R，**丢响应或重发都会写坏目的寄存器**（`lsq.v` 的 `issued_r` 身份依赖这条）。
3. **不阻塞**：`rready`/`bready` 必须恒可接收（数据有专属缓冲），否则一个慢消费者会队头阻塞整条通道。
4. **MMIO 分流**：**未按原规格做**——`0x80000000` 不特判、照常经写队列发上总线，由从机自己置 `exit`；
   CPU 侧只在提交级用"地址 + 宽度"判定停机（见 C.5）。

> **实现后记（与原规格的差异 + 一条教训）**：取指侧原计划用"`inst_valid`/`imem_stall` 接进 fetch"，
> 实际落地的是 **`imem_valid`（数据真回来了）+ `imem_hit`（本拍请求地址已可取）** 两个输入，
> 配合"请求地址即需求地址"的语义（见 fetch 一节）—— 这是唯一能在变长延迟下既不停错 PC 也不让
> 预取流自我重启的写法。另外 store→load 的合并**不要**画蛇添足并入"本拍正在提交"的那条 store：
> 它必然更老、又还在 LSQ 里，由 LSQ 兜住即可；硬并入会造出
> `sw_valid → load 回包 → 分支目标 → misp_det → ce_w → sw_valid` 的**零延迟组合环**（Verilator
> UNOPTFLAT 报出，综合/STA 无解），详见 `docs/plan.md` §14.3 缺陷 2。

### C.5 MMIO 终止与 `cpu_top` 改动清单

| 项 | 内容 |
|---|---|
| 解码位置 | `cpu_top` 提交级（B6）：`is_store_w && lsq_addr_w == 32'h8000_0000 && lsq_width_w == 2'b10`（⇒ `wstrb == 4'hf`，与官方判据一致） |
| 出口值 | `exit_value = sw_data`（整 32 位）；仅调试，不导出端口 |
| 缓存性 | **不可缓存**：`{IC,DC}` 只覆盖 `0x0000_0000–0x0fff_ffff`，`0x8000_0000` 直通写队列 |
| 子字 store 到该地址 | **不终止**（`wstrb≠4'hf`，从机也不认，返回 SLVERR）；仍正常发到总线 |
| 删 | ~~`TERM_RAW`/`TERM_RAW2`、`marker_acc`/`marker_commit`、`ret_val`/`ret_sample`/`ret_latched_r`~~ —— **实际未删**：TB 仍靠 marker 判停机，`ret_val` 是 TB 的判据，两者与 MMIO **OR 并存**（`0x80000000` 远超 TB 的 `MEM_SIZE`，不可能误命中）⇒ 不必加参数、不必改 TB |
| 加 | `sw_ready` 背压（**提交路径唯一的背压点，必须加 TB**）；`inst_valid`/`imem_hit` 接进 fetch；`mmio_exit = sw_valid && sw_ready && (sw_addr == 32'h8000_0000) && (sw_width == 2'b10)` |
| 判据不过松的证明 | 半字 store 到 `0x80000000` 必须**超时而非假 PASS**：手写 4 条指令的镜像 + `EXPECTED=7` 实跑得 `FAIL cycles=1000000`（`docs/plan.md` §14.5） |
| halt 语义 | 只冻结取指/统计/新 store，**不停提交、不排空 ROB**（沿用现状，最小行为改动） |

### C.6 Cache 层规格

> **实现状态（2026-10-01）**：**I/D 两侧均已实现并实测** —— I 侧 `verilog/core/icache.v`、
> D 侧 `verilog/core/dcache.v`，都接在 `mem_subsystem.v` 里。下表 D 相关两行的**目标规格与最终实现不同**
> （写策略该做 idxinv 而非"不写分配"、缺失处理该做单 MSHR + 1 条排队），差异与实测见 `plan.md` §15.15。
>
> **D 侧实测：五条写进规格的结论**（过程与逐点数据见 `plan.md` §十五~§二十；下面是结论，不是推导）
> 1. **D-cache 不是全面加速，是再分配**：同配置对照 geo 0.4428 → 0.4732（+6.87%），但
>    vvadd +42.0% / median +35.8% 与 qsort −7.0% / towers −15.4% 并存 —— 倒退全在 store 密集用例。
> 2. **AR 带宽收支判据 `h/m > L`**（一次 L 字填充 = L 笔 AR，1 AR/拍、每 AR 4 B）：L=8 要求命中率 **88.9%**，
>    实测只有 **0.46~0.68** ⇒ 当前 D-cache 是**读带宽的净消耗者**，**净赢靠延迟掩盖而非带宽**。
>    这是后续一切 D 侧取舍的基准判据（优化方针第 3 步）。
> 3. **污染填充必须中止**（污染后回包必被丢弃，再发就是白占读通道）：`fill_req_valid` 加 `!fill_abort_w`，
>    但**已发出的要收完**且"无在飞时当拍收尾"，实测 **+3.48%**，增益精确落在高污染用例上。
> 4. **store 的失效点在"退休"而不是"提交"**（+2.05%，geo 0.4732 → 0.4829）：提交只拦安装、不下架行，
>    提交→退休之间的字节由 `sq_merge_byte_f` 合并链兜。**两条窗口必须在同一个 posedge 结束**
>    （`sq_ret_p++` 与 `valid_r<=0` 同拍）——valid 早清只是白清，晚清就是"合并链没了而行还在 ⇒ 读旧值静默算错"。
>    增益精确落在 store 打中驻留行的用例上（qsort +8.5% / towers +3.2% / rsort +0.8%），
>    零驻留的 median/multiply/vvadd **逐比特不变**。
>    ⇒ 教训：早期"`idxinv` 提交即整组失效"之所以看着够用，是因为没试过更好的时点。
> 5. **容量轴没牙、相联度轴几乎免费 ⇒ 默认 2 路**（+2.18%，geo 0.4829 → 0.4934）：
>    容量：SRAM ×4 只值 **+0.35%**；相联度：预测（towers 涨 / qsort·rsort 不动）**被双向证伪** ——
>    实测 towers **逐比特不动**、qsort **+8.1%** / rsort **+5.3%**。
>    ⇒ **qsort/rsort 的缺失是冲突缺失不是容量缺失；towers 的缺失对缓存几何整体不敏感**（六个计数器在五个配置下逐比特相同），
>    只能从 store 侧解。**2 路用 0 额外 SRAM bit**（`64×288` 与 `32×576` 同为 18432 bit）拿到 1 路 16K 收益的 80.4%，面积代价约 1/433。
>    （替换策略 RR→LRU 的首轮结论"是死代码"**已被证伪并划线**，重测见 `plan.md` §十七/§二十：rsort 0.7229 → 0.7647。）

| 决策 | 选择 | 理由 | 现状 |
|---|---|---|---|
| I/D 划分 | **分离（哈佛式 L1）** | 每侧 1 读口即可用单口 `sram_fakeram`；统一 L1 需 fetch 与 load 同拍读 ⇒ 要么阵列复制（面积 ×2）要么分 bank 仲裁 | **I/D 两侧均已实现** |
| L2 | **不做** | 档 1 面积上限仅 9000 µm²；10 拍外部延迟已由 L1 + MLP 覆盖 | — |
| 缺失处理 | **非阻塞（MSHR + 次级未命中合并）** | 10 拍延迟下 IPC 的最大杠杆；同行的多个 load 必须并入同一 MSHR，否则退化成 10 拍/行 | **D 侧已做**（1 个在填 + 1 条排队 + 在填行合并）；I 侧仍用下一行预取，见下注 |
| D 写策略 | ~~**写直达 + 不写分配**~~ → **写直达 + 按索引失效（`idxinv`）**，失效时点 = **SQ 退休** | 原判据"不写分配避免 store 未命中先取行"仍成立；但**命中时**必须让行失效，否则读到旧值。`idxinv` = 清该**组**全部 valid，不看 tag：零 SRAM 访问、零 tag 比较、零写口仲裁，与"命中才失效"逐配置同值（离线实测）。**失效时点必须在退休**（上注 4）：提交即失效会让行活不过一条 store，实测差 2.05% | **D 侧已实现** |
| I 预取 | `IC_PREFETCH`（默认开） | AXI4-Lite **无 burst**，16 B 行 = 4 笔事务，顺序取全靠预取分摊 | 已实现（下一行预取，非多 MSHR） |
| 阵列实现 | **一律 `sram_fakeram`** | 只有它会被框架估算面积并计入总面积；寄存器组按标准单元 DFF 计，贵 ~7×（0.2916 vs 0.042 µm²/bit） | **I/D 两侧均已实现** |

> **注（v1 的实际取舍）**：上表"非阻塞 MSHR + 次级未命中合并"**未在 I 侧 v1 实现** ——
> 用的是"**下一行预取**"（一次填充完成后顺带填 `line+1`）。理由：AXI4-Lite 无 burst，
> 顺序码流的收益几乎全在"把下一行提前拉进来"，而它只要 ~10 行 RTL，不必引入多 MSHR 的
> 分配/合并/唤醒。**是否升级由实测收益决定，不投机**（CLAUDE.md §2）。
> 同理 D 侧若实现，v1 也取单 MSHR。

**`sram_fakeram` 的使用约束**（**已验证**，来源 `docs/sram.md` + `scripts/fakeram.py`）：
参数 `DEPTH` / `WIDTH` / `WRITE_GRANULARITY`，端口 `clk/en/we/wmask/addr/wdata/rdata`；
**单端口 1RW**（一拍只能读**或**写，不能同时）、**同步 1 周期读延迟**、**无复位引脚**（复位后内容不保证为 0）、
越界地址会报错终止仿真；单实例上限 `DEPTH×WIDTH ≤ 2^24` 位（2 MiB）。
**绝不能加进 `verilog/filelist.f`**（框架自动引入），**绝不能自写 stub**（`sram_fakeram` 及
`sram_fakeram_`/`fakeram_asap7_` 前缀是框架保留名）。
> 参数可以是 `localparam` **表达式**（如 `IC_SIZE/4`）：框架读的是 Yosys **elaborate 之后**的 JSON，
> 常量已折叠（`synth.py:89-93`）—— 故"容量/相联度参数化"不需要生成脚本。

**面积记账**（官方成本模型，**已在容器实测验证**）：单实例面积 ≈ `DEPTH × WIDTH × 0.0419904 µm²`
（按写掩码 lane 分别取整后求和），另有输出延迟
`0.071262 + 1.67155e-5×DEPTH + 1.243254e-3×GRANULARITY` ns。

> ⚠ **单位陷阱（原文在这里差了 4×）**：`DEPTH` 是**条目数（字）**，不是字节数。
> "1024×32 阵列" = 1024 **字** = **4 KiB 数据** = 32768 bit ≈ 1376 µm²；
> 而本设计的 `IC_SIZE` 是**字节**容量 ⇒ `IC_SIZE=1024` 只对应 **256 字**。

**I 侧实测（`IC_SIZE=1024 B` / `IC_LINE_WORDS=8` / 直接映射，`filelist_ic.f`，容器 r28）**：
32 行 × (8×32 数据 + 32 tag) = **9216 bit**，被框架拆成 `fakeram_asap7_32x32` 共 **9 个 lane**
（8 数据 + 1 tag，`WRITE_GRANULARITY=32` 逐字写）⇒ `sram_area_um2 = 386.984`，
与 `9216 × 0.0419904 = 386.98` **逐位吻合** ⇒ 该成本模型可直接用于预算推算。

**面积/容量的换算率**：`1 µm² ≈ 23.8 bit`（= 1/0.0419904）—— 加 SRAM 前先用它把 bit 数折成 µm²。
**cache 容量是最贵的旋钮**，必须逐点实测而非估算（实测：容量 ×4 只值 +0.35% IPC，见上文 D 侧结论 5）。

**D 侧 load 可见性合约**（本节最深的坑；**已实现并验证**，是 `store_queue` 退役判据的来源）：
`0x80000000` 之外，从机对 AR/AW 是**两条独立队列**，跨通道顺序**无保证**（C.4 已实证 LFSR 随机）。
旧 `memory.v` 靠"load 在读**完成当拍**才读存储阵列"规避了这个问题（**但并非全部**：快照取的是
时钟沿**前**的内容，而提交 store 的落盘与 LSQ 失效都在那个沿上 ⇒ 仍有 1 拍空洞，
见 `docs/plan.md` §二十四；该空洞现由 LSQ 侧兜住）；换成 AXI 后，
读数据是 **AR 被服务那一刻的快照**，而捕获在 **R 到达那一刻**，中间出现空洞：

```
t1: load 发 AR（快照在此刻）
tc: 更老 store S 提交 → LSQ 条目失效（合并源消失）
tw: S 的写被服务（才真正落到内存）
tr: R 到达并捕获（= t1 的快照，不含 S）
若 t1 < tw < tr 且 tc < tr ⇒ 既不在 LSQ、也不在内存 ⇒ 读到旧值【错】
```

⇒ **合约**：返回给 LSQ 的 load 数据必须合并**所有更老 store**，来源三级（优先级由低到高）：
`内存/缓存数据` < `store_queue（已提交未生效）` < `LSQ 未提交已执行 store`（后者由 `lsq.v` 的
`merge_byte_f` 原样完成，**`lsq.v` 零改动**；`store_queue` 那一级在内存侧完成）。
因提交按序 ⇒ `store_queue` 的每一条都比任何未提交指令更老 ⇒ 该级合并**永远不会过度合并**。
逐条退役条件**不能**是"B 一到就退役"，正确判据是
**「该条 B 已到达 ∧ 在它 B 到达之前发出的所有 AR 都已返回」**（B 到达时快照"已发出读计数"，退役时比较）。
实现与证明骨架见 plan.md Phase C。

### C.7 陷阱清单（总线/cache 侧，实现时对照）

1. **`bready` 恒 0 ⇒ 仿真超时**（`done` 依赖 B 握手）——最容易"功能全对却零分"。
2. **一笔 AR 恰好一个 R**：丢响应/重发 = 写坏目的寄存器（`lsq.v` 的 `issued_r` 身份）。
3. **装行（fill）必须过 store_queue 合并**：否则"装行期间提交的 store"会变成行里的陈旧字节。
4. **命中路径也必须过 store_queue 合并**：否则刚提交的 store 对一个已装行的 load 不可见。
5. **MSHR 同行合并**：两个 MSHR 抓同一行 ⇒ 装行两次，后到者可能覆盖回陈旧数据。
6. **store_queue 退役判据**不能退化为"B 到达即退役"（见 C.6 合约）。
7. **`arvalid`/`awvalid`/`wvalid` 必须保持到 ready**，地址/数据在握手拍之前不得变（AXI 基本要求）。
8. **I 侧跨行批**（批起点非 `4W` 对齐，跳转后首拍常见）与 **D 侧子字访问**两条 case 必须显式列举，
   不能靠 don't-care（CLAUDE.md：避免漏情况）。
9. **自修改代码**：ISA 豁免 `FENCE.I`，I 侧无一致性硬件。官方测试集是静态编译二进制（**待验证**的假设，非定理）。
10. **测试回退**：任何 cache 缺陷都应能通过 `IC_SIZE=0/DC_SIZE=0`（旁路）复现"是否 cache 引入"。

### C.8 残留假设（**不阻塞**，实现时按"最坏情况"留余量）

| # | 假设 | 依据 / 若假设不成立怎么办 |
|---|---|---|
| 1 | 官方 `correctness_*` **无自修改代码**（故 I 侧不需要一致性硬件，C.7-9 成立） | 依据（**部分已验证**）：19 个 `correctness_*` 的 `program.S` 是 `objdump` 反汇编，代码段全部落在 `0x0–0xfc`（naive 更短），所有**可静态解析**的 store 目标只有三类——`0x80000000`（MMIO 终止，18 个程序都有）、`# 2d0 <N>`/`# 5c4 <seed>` 这类**数据符号**（地址在代码段之上）、以及 `sp=0x40000` 栈/gp 相对；无一条 store 落在代码段。**非形式化证明**：不能排除运行期构造指向代码段的指针。若假设不成立 → 需要 I 侧失效/invalidate 机制（或退化为不缓存指令） |
| 2 | `docs/axi4-lite.md` 不附加协议之外的时序要求 | **已验证**：该文只要求 §3 的标准 VALID/READY 稳定性规则；AW 与 W **顺序自由**（三种先后皆可接受，从机等两者都握手才入队），仅有一句**建议**"你最好保持 `awvalid` 和 `wvalid` 信号永远一致"。故 adapter 的 FIFO/背压写法不受额外约束 |

> 原先记为"未知"的其他条目**均已实测消除**：从机队列语义/延迟起点、`sram_fakeram` 参数与面积模型、
> SRAM 面积是否计入、顶层端口模板、仿真结束条件（B 握手）、`filelist.f` 相对路径、终止序列、
> `arready` 时机与 AW/W 配对、判分与 IPC 口径 —— 结论分别写在 C.3–C.7。

## 代码布局与官方边界

- **目录约定**：`verilog/<域>/<模块>.v`（域 = top/front/core/exec），`tb/<域>/tb_<模块>.v`，脚本在 `tools/`。
  本机单元/整机 TB 流程 = **`Makefile.tb`**（`make -f Makefile.tb run/wave/bench tb=...`）。
- **RTL 清单（25 个，以 `verilog/filelist.f` 为准）**：
  - `exec/`：adder32, mul, div, alu, branch, execute_slot
  - `front/`：fetch, decode, bht, ras
  - `core/`：rat, free_list, rob, rs, ready_table, prf, lsq, cdb, memory, axi_lite_master, icache, dcache, mem_subsystem
  - `top/`：cpu_top, student_top
  - `core/memory.v` **仅供 TB**（固定 1 拍存储，综合时被 `hierarchy -top` 剪掉），不再计划摘除。
- **官方、勿改**：根 `Makefile`、`config.mk`、`scripts/`、`docs/{axi4-lite,sram}.md`、`testcases/`（submodule）。
  本机工具链路径写进 gitignore 的 `config.local.mk`，用 `make CONFIG=config.local.mk <target>` 生效。
- **参考语义源**：`/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`（C++ Tomasulo）的
  `src/core/cpu_top.cpp`、`include/ports/*.hpp`。
- 文件的增删改历史看 `git log` —— 本节不再维护变更清单。
