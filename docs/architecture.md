# RV32IM 乱序多发射 CPU — 架构设计文档

> 本文件是**设计规格**：设计决策、参数表、时序约定、模块接口、握手协议、正确性陷阱清单，
> 以及**面向官方框架的目标架构**（`student_top` / AXI4-Lite / Cache / MMIO 终止，Phase C 待实现）。
> 改 RTL 前先对照本文；RTL 与本文不一致时以本文为基准并同步更新。
> 过程记录 / 阶段计划 / debug 台账 / 消融矩阵在 `docs/plan.md`；
> 评测口径一律以 `docs/description.md` 为准（该文件只由用户手动修改）。

## 背景 (Context)

verilog-cpu-simulator 是 PPCA 大作业：一个**可参数化的乱序多发射 RV32IM CPU**（Verilog-2005，可仿真可综合）。**19 个模块已全部实现**（单发射 `ISSUE_WIDTH=1` 配置下 18 个编译程序 + 12 个单元 TB 全绿，见 `docs/plan.md`）。本文定义**全部模块的 input/output 接口**、cpu_top 布线、握手协议，以及**面向官方框架的目标架构规格**（见「目标架构」一节）。参考工程 `/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`（C++ 版 Tomasulo，单发射）的接线已全部分析，本设计**借用其验证过的机制、修正其不合理处**。

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
| `MEM_SIZE` | 65536 | **现状**（片上 `memory.v`）：字节寻址 RAM 容量。**官方口径下不存在** —— 内存是外部 256 MiB AXI4-Lite 从机，本参数随 `memory.v` 一起在 Phase C 退役 | memory |
| `MEM_LATENCY` | 3 | **现状**：片上 memory 的 load 倒计时。**官方口径只有 10 拍一个值**（框架 `LATENCY` 默认），Phase C 后由总线从机产生，不再由本设计参数化 | memory |
| `MEM_INFLIGHT` | 4 | **现状**：片上 memory 的飞行 load 槽数。Phase C 后等价物是 AXI 侧的未完成读槽/MSHR 数，是 MLP 的结构上限 | memory |
| `INIT_FILE` | "" | **现状**：非空时仿真初始化 $readmemh（每行 8 位 hex，支持 @地址） | memory |
| 派生 | | `PW=$clog2(PRF_SIZE)=6, RW=$clog2(ROB_SIZE)=5, LW=$clog2(LSQ_SIZE)=4, BW=$clog2(BHT_SIZE), RA=$clog2(RAS_SIZE), SRW=$clog2(RS_SIZE), CSW=$clog2(RS_SIZE+1), RCW=$clog2(ROB_SIZE+1), LCW=$clog2(LSQ_SIZE+1), PCW=$clog2(PRF_SIZE+1)` | |

**Phase C 新增参数**（详见下文「目标架构」的 C.6）：`IC_SIZE` / `IC_WAYS` / `IC_BLOCK` / `IC_MSHR` /
`IC_PREFETCH` / `DC_SIZE` / `DC_WAYS` / `DC_BLOCK` / `DC_MSHR` / `SB_DEPTH` / `RD_SLOTS` / `USE_FAKERAM`。
其中 `IC_SIZE` / `DC_SIZE` / `IC_WAYS` / `DC_WAYS` 是**官方明列的参数化项**（§架构要求与设计规范 · 2），
消融矩阵必须覆盖；`IC_SIZE = DC_SIZE = 0`（旁路直连总线）是合法的退化档，也是把"IPC 不达标"与
"功能不过"解耦的保险。

## 时序约定（全部模块）

- 全部模块 `always @(posedge clk)`，**同步低有效复位 `rst_n`**；每个握手信号 = 1 拍脉冲、**单一写者**；输出 = 当前状态组合
- **复位极性的内外差异**：内部一律 `rst_n`（低有效）；官方 `student_top` 的 `reset` 是**高有效**（保持 5 拍）。
  取反放在 `student_top` 包层（`wire rst_n = ~reset;`），**不给各模块加极性参数** ——
  后者会让 12 个 TB 与 19 个源文件全部改动，而包层取反只是一行。
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
| `op[4:0]` | in | 5 | 14 种：add sub sll slt sltu xor srl sra or and mul mulh mulhsu mulhu |
| `result[31:0]` | out | 32 | 组合结果（mul 低/高半按 op 选择） |

内部实例化 adder32（add/sub/slt 差分校准）+ mul（`a_signed=(op==mulh‖op==mulhsu)`，`b_signed=(op==mulh)`）；移位/逻辑用 `?:`。**LUI/AUIPC 由 cpu_top 映射为 add**（a=0/pc，b=imm），alu 无需 pc 输入。

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
| `imem_addr[W*32-1:0]` | out | 32×W | memory | 取指地址（pc 基址 + 4i） |
| `inst_data[W*32-1:0]` | in | 32×W | memory | 同步读（1 拍延迟） |
| `stall` | in | 1 | cpu_top | 队列满 / walker / halt → 不发起新请求（PC 最多回退到 exp_pc） |
| `redirect_valid, redirect_pc` | in | 1/32 | cpu_top | 误预测 → 下拍从 redirect_pc 取，清空当前批 |
| `halt` | in | 1 | cpu_top | 锁存停止取指 |

内部：PC 寄存器 → imem 地址；预测：BHT 查 `(pc>>2)%BHT_SIZE`，jal 恒 taken，ret（rd=0&&rs1=1）→ ras.top+pop，call（rd=1）→ push pc+4；branch/jal 的预测目标需要 B 型/J 型 imm 符号扩展（与 decode 重复 ~6 行，注释注明保持同步——参考同款做法）。fetch 级 = 1 拍（PC 在 T 拍、指令 T+1 拍到达，含流水寄存器）。

**取指握手（实现后定稿，取代"请求标签"方案）**：只用**地址比对**判到达，不用 tag/计数器。
- `imem_addr_d` = 上一拍锁存的地址 = 本拍 `inst_data` 所属地址（memory 同步读 1 拍，两者天然同址）
- `exp_pc_r` = 下一条要交付给 decode 的批地址；`arr_ok = (imem_addr_d[0] == exp_pc_r)` 才算"这一批是想要的"
- 接收条件 `cap_w = arr_ok && cap_ok && !halt`，`cap_ok = 批寄存器空 || 本拍批被发射`（`batch_taken = |f2i_valid && !stall`）
- PC 只在"写 pc"的拍推进：`pc_wr_w = rst_n && (redirect || rewind || (!stall && !halt))`
- 好处：stall 保持 PC 造成的重复读出、预测跳转/redirect 拍的在途错路读出，全部被地址比对自动丢弃，无需任何作废信号（省 4 个寄存器与计数对齐逻辑）；反之若到达的正是期望地址（例如 redirect 目标恰在途）也照收不误
- **稳态时序**：`pc_r = exp_pc_r + 4W`（请求领先 1 批），每拍交付 1 批；一次预测跳转 = 1 拍气泡（在途的顺序批被丢弃）
- **满批丢弃回退（rewind）**：stall 期间到达的正是 `exp_pc` 批却因批寄存器满被丢弃 → 该批若不管就永久丢失（PC 已越过它）。故丢弃拍把 PC **回退到 `exp_pc_r`** 重取；回退后 memory 每拍重复读出 `exp_pc`，`exp_pc` 不变，stall 一解除即接收（无额外气泡，代价只是 stall 期间不预取）
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

实现演进（**仿真调试记录，见 git 提交的根因分析**）：
- 原方案 `alloc_val[i] = head + i`（环形组合计算、不存值）+ `count += push 数`。**该方案不成立**，两个独立缺陷：
  1. 回收请求里包含恒等映射区 preg（<32，如首次被覆盖的 x5/x6/x7）；环形池无法表示它们，但被计入了 count → 计数虚高；
  2. 隐含"回收顺序 = 分配顺序"假设。实际上 commit 释放的是各 rd 的 `old_pnum`，同批内不同 rd 的到达次序任意（实测先放 34 后放 32），空闲集不再是环形连续区间，`head + i` 会算出仍在使用的 preg。症状：`add t2,t2,t0` 拿到的 preg 同时仍被 `t1` 引用 → 分支读到被覆盖的值 → 循环不退出。
- 改为 **LIFO 栈 + 真实存储**（FREE_NUM × PW 位）：回收顺序任意都正确；`push_preg < 32` 的回收直接丢弃（恒等映射区永久退休，池只含 >= 32 的项），同时顺带过滤 walker 对 `new_pnum==0` 条目压入的 preg 0。
- 同拍 push/pop：pop 读 `pool[sp-1-pc_pre]`，push 写 `pool[sp-pop_cnt+ps_pre]`（落在本拍 pop 腾出的槽位；组合读先于边沿写）。**易错点**：写成 `pool[sp+ps_pre]`（栈顶之上）会导致同拍 pop 腾出的槽位残留旧值，下拍 pop 读到已分配的 preg（本次调试中实际踩到）。
- `count_out = sp`（不含本拍 push）：无同拍旁路，本拍回收的项本拍不可分配 → 池空时多 1 拍气泡；换来 pop 读索引恒在 `[0, sp)` 内。
- 代价：FREE_NUM×PW 触发器（32×6 ≈ 56 µm²）+ 读 mux/写译码。面积阶段可再评估（如位图 + 优先编码器）。
- 约束：需 PRF_SIZE >= 64（32 个恒等映射 + 池），PRF_SIZE 消融应向上扫描（64/96/128）而非向下。

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
| `prf_valid[W:0], prf_preg[(W+1)*PW-1:0], prf_data[(W+1)*32-1:0]` | out | (W+1)/PW/32 ×(W+1) | prf.v | 写回口 |
| `rt_set_req[PRF_SIZE]` | out | PRF_SIZE | ready_table.v | 置位掩码 |
| `rob_ready_req[ROB_SIZE]` | out | ROB_SIZE | rob.v | ROB ready 掩码（`rob_wr` 槽按 tag 置位） |

内部全部 `assign`（prd==0 的槽不写 PRF 不置 ready；rob_wr 槽置 ROB）。槽 0..W-1 = 执行，槽 W = load。

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
| `invalidate[LSQ_SIZE]` | in | LSQ_SIZE | cpu_top（commit） | store/load 提交后失效 |
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

### top/cpu_top.v — 仅 clk/rst + 调试输出，胶水全部内部
| name | dir | width | 说明 |
|---|---|---|---|
| `clk, rst_n` | in | 1/1 | 时钟/同步复位 |
| `halt` | out | 1 | 终止标记已提交 |
| `ret_val[7:0]` | out | 8 | rob 排空后 `prf[rat.map_arch[10]] & 0xFF` |
| `commit_count[31:0], flush_count[31:0], branch_count[31:0]` | out | 32×3 | 性能/消融统计 |
| `rob_head[RW-1:0], rob_ready_head` | out | RW/1 | 调试 |

**内部组合块**（assign/generate，无新增模块）：
- B1 操作数获取：`op = (prs==0)?0 : (cdb 槽标签匹配 ? 槽结果 : (rt_ready[prs] ? prf 索引读 : 0))`——读口地址由槽选择结果驱动
- B2 发射组合：W 条 prefix 门控（条件：rob/rs 有空间 && (!writes_rd ‖ free_list 够) && (!memop ‖ lsq 有空间)）；rat rename W + free_list pop W + ready_table clear W + rob/rs/lsq push W
- B3 执行槽分发：按 rs.sel_idx 取字段 → 槽内 alu/branch 操作数/操作码
- B4 误预测检测：branch: `taken != pred_taken`；jalr: `target != pred_target`；**多槽同拍误预测 → 取最老 tag**；同时驱动 fetch 重定向 + bht 更新 + ras 恢复 + rs/lsq flush_mask + rob set_last；**misp 周期抑制 issue**（见陷阱 #11）
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

> 本节是**待实现的目标规格**（本次只写规格、不写 RTL）。实施顺序与验收判据见 `docs/plan.md` 的 Phase C。
> 凡标「**已验证**」的条目都出自对官方框架源码/文档的实读（`scripts/sim.cpp`、`fakeram.py`、
> `synth.py`、`docs/{axi4-lite,sram}.md`，快照 `/tmp/cpu2026-fw`，上游 main `54fc150`）；
> 标「**待验证**」的仍是推断。

### C.1 现状 → 目标：差距总表

| 维度 | 现状（已实现并测过） | 目标（官方） |
|---|---|---|
| 顶层 | `cpu_top`（`clk/rst_n/halt/ret_val[7:0]/commit_count/...`） | **`student_top`**，端口模板固定，**与 `cpu_top` 无一重合** ⇒ 纯新增包层 |
| 复位 | 同步低有效 `rst_n` | 高有效 `reset`，初始化保持 5 拍 |
| 内存 | 片上 `core/memory.v`，`MEM_SIZE=65536`、`$readmemh` 装载 | 外部 256 MiB AXI4-Lite 从机，**`memory.v` 退役**（不进 `verilog/filelist.f`） |
| 延迟 | `MEM_LATENCY=3`（参数化倒计时） | 从机固定语义：最快"握手后下一拍被服务"，服务到响应 **10 拍**（`LATENCY` 默认值） |
| 终止 | `ori x0,x0,255` + `ret_val = a0[7:0]` | 向 MMIO `0x80000000` 做 32 位 store，退出值 = `WDATA[31:0]`（由总线侧读取） |
| ISA | 缺 DIV/DIVU/REM/REMU（静默 NOP）；无 LB/LBU/LH/LHU | **全 RV32IM**；LB/LBU/LH/LHU 必须实现 |
| 参数化 | W / ROB / RS / PRF / LSQ / BHT / RAS | 追加 **Cache 容量与相联度**（官方明列） |
| 面积 | `synth/cpu.ys` 直跑 Yosys，内存当黑盒 | `make synth`（Yosys+ABC+OpenSTA，`CLOCK_PERIOD_NS=2.0`），**SRAM 估算面积计入** |

### C.2 层次结构

```
student_top                      ← 官方要求的顶层；只做复位取反 + 例化 + 端口对接
├── cpu_top                      ← 现有乱序核（内存侧端口扩 4 根，其余不动）
│   └── 现有 19 个模块            ← 除 decode.v（补 div/rem 与子字访存）外不改
└── mem_subsystem                ← 新增
    ├── icache / dcache          ← 阵列一律用 sram_fakeram
    ├── store_queue              ← 已提交未生效的 store（同时是 AXI 写队列）
    └── axi_lite_master          ← 协议 FSM + 子字选择 + MMIO 分流
```

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

**适配层职责**（保持 `cpu_top` 的内存侧接口不变以隔离改动）：

1. **子字访问**：load 按 `addr[1:0]` 从 `rdata` 选字节/半字，按 `func3[2]` 决定是否符号扩展；
   store 按 `addr[1:0]` + 宽度生成 `wstrb`。地址须自然对齐（不满足则是程序 bug，不是本层职责）。
2. **按序记账**：读请求用 FIFO 记录 `{lsq_idx}`，R 到达时按 FIFO 出队 demux 回 LSQ ——
   一笔 AR 对应**恰好一个** R，**丢响应或重发都会写坏目的寄存器**（`lsq.v` 的 `issued_r` 身份依赖这条）。
3. **不阻塞**：`rready`/`bready` 必须恒可接收（数据有专属缓冲），否则一个慢消费者会队头阻塞整条通道。
4. **MMIO 分流**：见 C.5。

### C.5 MMIO 终止与 `cpu_top` 改动清单

| 项 | 内容 |
|---|---|
| 解码位置 | `cpu_top` 提交级（B6）：`is_store_w && lsq_addr_w == 32'h8000_0000 && lsq_width_w == 2'b10`（⇒ `wstrb == 4'hf`，与官方判据一致） |
| 出口值 | `exit_value = sw_data`（整 32 位）；仅调试，不导出端口 |
| 缓存性 | **不可缓存**：`{IC,DC}` 只覆盖 `0x0000_0000–0x0fff_ffff`，`0x8000_0000` 直通写队列 |
| 子字 store 到该地址 | **不终止**（`wstrb≠4'hf`，从机也不认，返回 SLVERR）；仍正常发到总线 |
| 删 | `TERM_RAW`/`TERM_RAW2`、`marker_acc`/`marker_commit`、`ret_val`/`ret_sample`/`ret_latched_r` 与 `rd1mux`（槽 0 读口复用采样） |
| 加 | `sw_ready` 背压（`ce_w[0] &= (is_store_w[0] ? sw_ready : 1'b1)`，**提交路径唯一的背压点，必须加 TB**）；`sw_valid` 门控 `!halt_q_r`（halt 后不再发新 store，但写队列**继续排空**）；`inst_valid`/`imem_stall` 接进 fetch |
| halt 语义 | 只冻结取指/统计/新 store，**不停提交、不排空 ROB**（沿用现状，最小行为改动） |

### C.6 Cache 层规格

| 决策 | 选择 | 理由 |
|---|---|---|
| I/D 划分 | **分离（哈佛式 L1）** | 每侧 1 读口即可用单口 `sram_fakeram`；统一 L1 需 fetch 与 load 同拍读 ⇒ 要么阵列复制（面积 ×2）要么分 bank 仲裁 |
| L2 | **不做** | 档 1 面积上限仅 9000 µm²；10 拍外部延迟已由 L1 + MLP 覆盖 |
| 缺失处理 | **非阻塞（MSHR + 次级未命中合并）** | 10 拍延迟下 IPC 的最大杠杆；同行的多个 load 必须并入同一 MSHR，否则退化成 10 拍/行 |
| D 写策略 | **写直达 + 不写分配** | 不写分配避免"store 未命中先花 13 拍取行"；`store_queue` 同时就是 AXI 写队列 |
| I 预取 | `IC_PREFETCH`（默认开） | AXI4-Lite **无 burst**，16 B 行 = 4 笔事务，顺序取全靠预取分摊 |
| 阵列实现 | **一律 `sram_fakeram`** | 只有它会被框架估算面积并计入总面积；寄存器组按标准单元 DFF 计，贵 ~7×（0.2916 vs 0.042 µm²/bit） |

**`sram_fakeram` 的使用约束**（**已验证**，来源 `docs/sram.md` + `scripts/fakeram.py`）：
参数 `DEPTH` / `WIDTH` / `WRITE_GRANULARITY`，端口 `clk/en/we/wmask/addr/wdata/rdata`；
**单端口 1RW**（一拍只能读**或**写，不能同时）、**同步 1 周期读延迟**、**无复位引脚**（复位后内容不保证为 0）、
越界地址会报错终止仿真；单实例上限 `DEPTH×WIDTH ≤ 2^24` 位（2 MiB）。
**绝不能加进 `verilog/filelist.f`**（框架自动引入），**绝不能自写 stub**（`sram_fakeram` 及
`sram_fakeram_`/`fakeram_asap7_` 前缀是框架保留名）。
> 参数可以是 `localparam` **表达式**（如 `IC_SIZE/4`）：框架读的是 Yosys **elaborate 之后**的 JSON，
> 常量已折叠（`synth.py:89-93`）—— 故"容量/相联度参数化"不需要生成脚本。

**面积记账**（官方成本模型，**已验证**）：单实例面积 ≈ `DEPTH × WIDTH × 0.0419904 µm²`（按写掩码 lane 分别取整后求和），
另有输出延迟 `0.071262 + 1.67155e-5×DEPTH + 1.243254e-3×GRANULARITY` ns。
故 **1 KiB / 32 位数据阵列 ≈ 32768 bit ≈ 1376 µm²**，标签/状态阵列同理按位计 ——
**cache 是"面积换 IPC"的主旋钮，也是档 1 面积预算里最大的一块**，必须在消融矩阵里量化。

**D 侧 load 可见性合约**（本节最深的坑，**待验证**的设计推断）：
`0x80000000` 之外，从机对 AR/AW 是**两条独立队列**，跨通道顺序**无保证**（C.4 已实证 LFSR 随机）。
旧 `memory.v` 靠"load 在读**完成当拍**才读存储阵列"规避了这个问题；换成 AXI 后，
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

## 关键文件

> 目录已迁移到官方布局：`rtl/` → **`verilog/`**；根 `Makefile`/`scripts/` 属官方（勿改），
> 自建 TB 流程在 **`Makefile.tb`**（`make -f Makefile.tb run/wave/bench`）。

- 修改：verilog/front/{fetch,decode,bht,ras}.v、verilog/core/{rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory}.v、verilog/exec/{alu,branch}.v、verilog/top/cpu_top.v（Phase A 先写接口骨架 + cpu_top 全部布线，Phase B 逐模块填充内部；**Phase A 新增 TB 9 个**：tb_rat/tb_rs/tb_lsq/tb_memory/tb_fetch/tb_alu/tb_branch/tb_rob/tb_cpu_top）
- 修改（实现期新增）：verilog/exec/execute_slot.v（B1/B3/B4 的操作数获取、执行分发、误预测检测汇出）
- 新增（§5）：tb/top/tb_cpu_prog.v（编译程序整机验证）；当前 `tb/` 共 **12** 个 = Phase A 的 9 个 + 既有 tb_mul/tb_adder32 + tb_cpu_prog
- 修改（§6 性能修复）：verilog/exec/mul.v（tree_level 改词级运算 + 校正位行整行单驱动）、verilog/exec/alu.v（非乘法 op 门控乘法器输入）
- 不动：verilog/exec/adder32.v、`Makefile.tb`（自动发现新文件）
- **新增（Phase C，见上文「目标架构」）**：verilog/top/student_top.v、verilog/core/{icache,dcache,store_queue,axi_lite_master,mem_subsystem}.v；
  修改：cpu_top.v（内存侧端口 + MMIO 终止）、decode.v（div/rem + LB/LBU/LH/LHU 解码）、lsq.v（只改接口对接，合并语义不动）；
  退役：core/memory.v（移出 `verilog/filelist.f`，留作本地回归后端）
- 官方框架（根目录，**勿改**）：Makefile、config.mk、scripts/、docs/{axi4-lite,sram}.md、testcases/（submodule）；
  本机工具链路径写 `config.local.mk`（已 gitignore），用 `make CONFIG=config.local.mk <target>`
- 参考语义源：RISC-V-Tomasulo-CPU-Simulator/src/core/cpu_top.cpp、include/ports/*.hpp
