# RV32IM 乱序多发射 CPU — 架构与实现计划

## 背景 (Context)

verilog-cpu-simulator 是 PPCA 大作业：一个**可参数化的乱序多发射 RV32IM CPU**（Verilog-2005，可仿真可综合）。`adder32` 与 `mul`（2位Booth+华莱士树）已实现，其余 15 个模块是空壳占位。本计划定义**全部模块的 input/output 接口**、cpu_top 布线、握手协议与实现/TB 顺序，供实现阶段直接照做。参考工程 `/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`（C++ 版 Tomasulo，单发射）的接线已全部分析，本设计**借用其验证过的机制、修正其不合理处**。

需求（project.pptx + CLAUDE.md）：RV32IM（去掉 csr*/fence/半字与字节 load）、参数化 W∈{1,2,4} × PRF 大小 × ROB 大小（及 RS/LSQ 等）、跑 3 个程序（向量乘/向量加/0-100 累加）、报告含参数消融、YoSys+ASAP7 单发射 1500–2000µm²、面积翻倍性能 ≥1.3×。

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

**进度**：步 1–8 模块内部已全部实现，`tb_cpu_top` 三程序（p1_sum 417 拍 / p2_vecadd 224 / p3_vecmul 192）全通过；`tb_fetch` 重写后全绿（段1 15 个 directed + 段2 300 拍逐拍模型对照），并在过程中抓出 5 个 def（见下节）。`tb_rs`、`tb_lsq` 已按"窄修期望值"修完（见 3.6），**除 `tb_mul`（按用户要求不跑）与 `tb_cpu_top` 外，全部单元 TB 退出码 0**。

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

## 消融 + 综合（报告素材）

- 矩阵：W{1,2,4} × ROB{16,32,64} × RS{8,16,24} × PRF{32,64,128} × LSQ{8,16,32} × MEM_LATENCY{1,3,6} × BHT{16,32,128} × RAS{0,8,32}，3 程序各跑一遍，记录 IPC/提交/冲刷统计（cpu_top 调试输出）
- YoSys + ASAP7：单发射核心 1500–2000µm²（RAM 用 ram 风格映射/黑盒，**报告注明面积为核心逻辑**）；2× 面积 → ≥1.3× 性能
- 可选消融点（报告素材）：RAT 快照恢复 vs walker、值捕获 RS vs 状态式、无延迟内存 vs MEM_LATENCY

## 关键文件

- 修改：rtl/front/{fetch,decode,bht,ras}.v、rtl/core/{rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory}.v、rtl/exec/{alu,branch}.v、rtl/top/cpu_top.v（Phase A 先写接口骨架 + cpu_top 全部布线，Phase B 逐模块填充内部；新增 TB 9 个）
- 不动：rtl/exec/{adder32,mul}.v、Makefile（自动发现新文件）
- 参考语义源：RISC-V-Tomasulo-CPU-Simulator/src/core/cpu_top.cpp、include/ports/*.hpp
