# RV32IM 乱序多发射 CPU — 架构与实现计划

## 背景 (Context)

verilog-cpu-simulator 是 PPCA 大作业：一个**可参数化的乱序多发射 RV32IM CPU**（Verilog-2005，可仿真可综合）。`adder32` 与 `mul`（2位Booth+华莱士树）已实现，其余 15 个模块是空壳占位。本计划定义**全部模块的 input/output 接口**、cpu_top 布线、握手协议与实现/TB 顺序，供实现阶段直接照做。参考工程 `/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`（C++ 版 Tomasulo，单发射）的接线已全部分析，本设计**借用其验证过的机制、修正其不合理处**。

需求（**以 `docs/description.md` 为准**，该文件只由用户手动修改；本节及全文的指标口径随其更新）：RV32IM（去掉 CSR*/ECALL/EBREAK/FENCE(.I) 与 LH/LHU/LB/LBU）、参数化 W∈{1,2,4} × PRF 大小 × ROB 大小（及 RS/LSQ 等）、正确性两阶段（基础程序：向量乘/向量加/0-100 累加 → 仿真程序：CPU Simulator 全部程序）、报告含参数消融与架构探索；面积用 YoSys+ASP7 综合（内存不综合不计面积、禁止用寄存器组当内存）、IPC 用 Verilator 统计（测试点 = CPU-2026-Benchmark 仓库）、频率 ≥300MHz、统一内存（冯·诺依曼）、内存延迟功能 3 拍 / 性能档 20 拍；三档"面积上限与最低 IPC 同时满足"：(10000, 0.6000) / (20000, 0.7800) / (40000, 1.0140)，档位设计为 IPC ×1.3 ↔ 面积上限 ×2。

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
- 终止标记 = `ori x0,x0,255`（raw `0x0FF06093`），**不用**参考的 `li a0,255`（0x0ff00513 会把 a0 返回值冲掉）；标记指令正常提交，提交时锁存 halt，ROB 排空后采样 `x10 & 0xFF`
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
| `MEM_SIZE` | 65536 | 字节寻址 RAM 容量 | memory |
| `MEM_LATENCY` | 3 | load 延迟（消融扫 1/3/6） | memory |
| `MEM_INFLIGHT` | 4 | 飞行 load 槽数 | memory |
| `INIT_FILE` | "" | 非空时仿真初始化 $readmemh（每行 8 位 hex，支持 @地址） | memory |
| 派生 | | `PW=$clog2(PRF_SIZE)=6, RW=$clog2(ROB_SIZE)=5, LW=$clog2(LSQ_SIZE)=4, BW=$clog2(BHT_SIZE), RA=$clog2(RAS_SIZE), SRW=$clog2(RS_SIZE), CSW=$clog2(RS_SIZE+1), RCW=$clog2(ROB_SIZE+1), LCW=$clog2(LSQ_SIZE+1), PCW=$clog2(PRF_SIZE+1)` | |

## 时序约定（全部模块）

- 全部模块 `always @(posedge clk)`，**同步低有效复位 `rst_n`**；每个握手信号 = 1 拍脉冲、**单一写者**；输出 = 当前状态组合
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
5. load 完成脉冲与 flush 竞争 → lsq 检查条目有效性，无效丢弃
6. 同拍多误预测 → 最老 tag；walker 中途扩展不重复回滚（walk_ptr 只递减）
7. 执行槽选择互斥（同年龄低槽赢）、两槽不选同一 RS 条目
8. 同批 2 store 提交 → 第 2 个下拍；同批 2 call → RAS 链保证 top[i] 正确
9. fetch 半批处理：stall 在批边界、redirect 丢弃整批
10. store 前向只覆盖已执行 store；load 发起排序条件（所有更老 store 已执行）不可省
11. **misp 周期抑制 issue**：walker 触发时 walk_ptr 按旧 rob_last 捕获，若 misp 当拍仍发射，错路批会落在 flush 窗口尾部之外 → RAT/preg 泄漏。故 `issue_en` 必须含 `!misp_valid`（fetch 批同时被 redirect 丢弃，无吞吐损失）
12. 陈旧 ready 位（伪竞态）：rename-clear 与 RS push 同 posedge，被推条目下拍才对选择可见，此时 ready 已是 0；free list 中 preg 恒 ready=1 的场景由"老 producer 已提交"保证读旧值正确——无需额外端口，实现时注释说明
13. load 执行槽的 CDB 标签竞态：依赖者会匹配 load 槽 prd（地址）→ `cdb_slot_valid[g] = sel_valid[g] && !is_load`（RS 就绪判断与 exec_valid 同源）

## 实施计划（两阶段，用户已确认）

### Phase A — 接口冻结 + cpu_top 总流水线（骨架）【进行中】

目标：**尽早冻结全部接口契约**，让工程先可编译、可综合检查。

1. ✅ 15 个模块全部按本规格写出**完整参数表 + 端口声明**，内部为可综合空壳（输出定值，标注 `// TODO(Phase B)`）
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

**进度**：步 1–8 模块内部已全部实现，全部单元 TB（除按用户要求不跑的 `tb_mul`）与 `tb_cpu_top`（p1_sum 417 拍 / p2_vecadd 224 / p3_vecmul 192）退出码 0。整机编译程序验证链路已打通（§5）：`naive` ret=94、`gcd` ret=178（726 拍 / 364 提交 / 60 冲刷）；过程中抓出 2 个严重取指缺陷（见 §4）。当前阻塞：整机 TB 仿真速度（§6 调查中）—— 长程序（pi/queens/superloop 可能 10^5~10^6 拍）必须先解决，否则跑不完 18 个程序与消融矩阵。

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
- **整机 TB 仿真速度 30~50 ms/拍**（gcd 726 拍 23 s、tb_cpu_top 833 拍 41 s）：详见 **§6 调查**（"宽向量网络"这一原假设已被隔离实验证伪，勿再按它下手）。

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
- **harness**：`tb/top/tb_cpu_prog.v`（`+PROG=<名>` 选程序、`+DUMP=N` 只记前 N 拍、`+TRACE=N` 逐拍 trace rob/rs/lsq/mem）+ `tb/top/prog/*.data`（19 个镜像，`$readmemh` 直载）；Makefile `ARGS=` 透传 vvp。
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

**注意**：这批结果全部是 `MEM_LATENCY=3` 下的。按 description.md，性能档要求内存延迟 20 拍 ——
换到 20 拍后立刻炸出**第三个独立缺陷**（§7.4），说明"功能配置下全过"并不等于"性能配置下可用"。

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

## 消融 + 综合（报告素材）

- 矩阵：W{1,2,4} × ROB{16,32,64} × RS{8,16,24} × PRF{32,64,128} × LSQ{8,16,32} × MEM_LATENCY{3,20} × BHT{16,32,128} × RAS{0,8,32}，3 程序各跑一遍，记录 IPC/提交/冲刷统计（cpu_top 调试输出）
  - MEM_LATENCY 必须含 **20 拍**：description.md 规定性能阶段的内存延迟为 20 拍（功能仿真 3 拍），评估性能档要用 20
- YoSys + ASAP7 实测（默认参数、单发射、当前代码）：全核 **7768.5 µm²**（memory 黑盒另计），mul 554.6；详见 `docs/area_budget.md`
  - 达标口径（description.md）：**面积上限与最低 IPC 同时满足** —— (10000, 0.6000) / (20000, 0.7800) / (40000, 1.0140)；默认配置面积已在第 1 档内，瓶颈是 IPC
  - IPC 评测口径是 **Verilator 跑 CPU-2026-Benchmark**，本仓库的 `+PERF=N` 只是内部对照，报告中须说明两者口径差异
- 可选消融点（报告素材）：RAT 快照恢复 vs walker、值捕获 RS vs 状态式、无延迟内存 vs MEM_LATENCY

## 关键文件

- 修改：rtl/front/{fetch,decode,bht,ras}.v、rtl/core/{rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory}.v、rtl/exec/{alu,branch}.v、rtl/top/cpu_top.v（Phase A 先写接口骨架 + cpu_top 全部布线，Phase B 逐模块填充内部；新增 TB 9 个）
- 修改（§6 性能修复）：rtl/exec/mul.v（tree_level 改词级运算 + 校正位行整行单驱动）、rtl/exec/alu.v（非乘法 op 门控乘法器输入）
- 不动：rtl/exec/adder32.v、Makefile（自动发现新文件）
- 参考语义源：RISC-V-Tomasulo-CPU-Simulator/src/core/cpu_top.cpp、include/ports/*.hpp
