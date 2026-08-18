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

2-bit 饱和计数，复位 `2'b01`（弱不取）；W 写口按槽序依次应用（同索引重复取低槽结果）。

### front/ras.v
| name | dir | width | 驱动方 | 说明 |
|---|---|---|---|---|
| `top[W*32-1:0]` | out | 32×W | fetch | `top[i]` = 处理 ops[0..i-1] 后的栈顶（组合链） |
| `head_snap[W*RA-1:0]` | out | RA×W | cpu_top（误预测恢复） | `head_snap[i]` = 处理 ops[0..i-1] 后 head |
| `ops[W*2-1:0]` | in | 2×W | fetch | 每条：0=无 1=push 2=pop（call=push pc+4，ret=pop） |
| `push_val[W*32-1:0]` | in | 32×W | fetch | push 值（pc+4） |
| `restore_valid, restore_head` | in | 1/RA | cpu_top | 误预测 head 恢复（优先级 > fetch ops） |

内部：栈数组 + head 寄存器；W 路顺序链计算 `top[i]`/`head_snap[i]`；空栈 pop 忽略、满栈 push 丢弃。**每批的 RAS 操作在取指时一次性应用**（stall 保持批时不再重复应用）。

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
| `stall` | in | 1 | cpu_top | 队列满 / walker / halt → 保持 PC 与输出 |
| `redirect_valid, redirect_pc` | in | 1/32 | cpu_top | 误预测 → 下拍从 redirect_pc 取，清空当前批 |
| `halt` | in | 1 | cpu_top | 锁存停止取指 |

内部：PC 寄存器 → imem 地址；预测：BHT 查 `(pc>>2)%BHT_SIZE`，jal 恒 taken，ret（rd=0&&rs1=1）→ ras.top+pop，call（rd=1）→ push pc+4；branch/jal 的预测目标需要 B 型/J 型 imm 符号扩展（与 decode 重复 ~6 行，注释注明保持同步——参考同款做法）。fetch 级 = 1 拍（PC 在 T 拍、指令 T+1 拍到达，含流水寄存器）。

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
| `alloc_val[W*PW-1:0]` | out | PW×W | cpu_top | head 起连续 W 个空闲 preg（组合，回绕到 32，绝不分配 preg 0） |
| `count_out[PCW-1:0]` | out | `$clog2(PRF_SIZE+1)` | cpu_top | 当前空闲 + 本拍 push 数（issue 判断） |
| `pop_req[W-1:0]` | in | W | cpu_top | 弹出（prefix 语义） |
| `push_valid[W-1:0], push_preg[W*PW-1:0]` | in | W / PW×W | cpu_top | 回收（commit 与 walker 复用同一端口——二者互斥：walker 期间 commit 冻结） |

复位：head=32，count=PRF_SIZE-32（phys 0..31 已被恒等映射占用）。优先级：push > pop。**每个 preg 每生命周期恰好写一次**（free list 只在 producer 提交后释放）。

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

## 消融 + 综合（报告素材）

- 矩阵：W{1,2,4} × ROB{16,32,64} × RS{8,16,24} × PRF{32,64,128} × LSQ{8,16,32} × MEM_LATENCY{1,3,6} × BHT{16,32,128} × RAS{0,8,32}，3 程序各跑一遍，记录 IPC/提交/冲刷统计（cpu_top 调试输出）
- YoSys + ASAP7：单发射核心 1500–2000µm²（RAM 用 ram 风格映射/黑盒，**报告注明面积为核心逻辑**）；2× 面积 → ≥1.3× 性能
- 可选消融点（报告素材）：RAT 快照恢复 vs walker、值捕获 RS vs 状态式、无延迟内存 vs MEM_LATENCY

## 关键文件

- 修改：rtl/front/{fetch,decode,bht,ras}.v、rtl/core/{rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory}.v、rtl/exec/{alu,branch}.v、rtl/top/cpu_top.v（Phase A 先写接口骨架 + cpu_top 全部布线，Phase B 逐模块填充内部；新增 TB 9 个）
- 不动：rtl/exec/{adder32,mul}.v、Makefile（自动发现新文件）
- 参考语义源：RISC-V-Tomasulo-CPU-Simulator/src/core/cpu_top.cpp、include/ports/*.hpp
