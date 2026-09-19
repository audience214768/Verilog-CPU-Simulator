# RV32IM 乱序多发射 CPU — 计划与实现记录

> 本文件是**过程文档**：当前状态、阶段计划、实施过程记录（含 debug 台账）、消融矩阵与待办。
> 设计规格（设计决策 / 参数表 / 时序约定 / 模块接口 / 握手协议 / 陷阱清单）见 `docs/architecture.md`；
> 评测口径一律以 `docs/description.md` 为准（该文件只由用户手动修改）。

## 当前状态

**正确性 · 功能配置（`MEM_LATENCY=3`）**：18 个编译程序中 **17 个 PASS**（ret 全部与期望相符）；
`pi` 因单程序仿真墙钟时间为同批数倍，本轮按用户决定放过 → **待办**。
基础程序阶段（description.md 75 分门槛）已过：`p1_sum`/`p2_vecadd`/`p3_vecmul` = 417/224/192 拍。

**正确性 · 性能配置（`MEM_LATENCY=20`）：尚不成立 —— 这是当前头等大事。**
已修掉只在该配置下暴露的缺陷 §7.4（rs push 被静默丢弃 → 死锁）；但重型程序紧接着暴露出**两个新问题**：
`queens` **算错**（ret=7，期望 171）、`tak` **出现 X 传播**（20 万拍内只做了 51 次分支，等于没动）。
两者在 3 拍下都 PASS。故用户定的链条"确认正确性 → 用要求的参数（20 拍）测试 → 再优化"，
**第二个环节还没过，谈优化为时过早**。

**IPC（内部对照；`+PERF` 首 20 万拍窗口，20 拍 / `MEM_INFLIGHT=16`）**：superloop 0.732 /
basicopt1 0.634 / qsort 0.550 / bulgarian 0.192 / magic 0.180 / hanoi 0.128（三档门槛
0.6000 / 0.7800 / 1.0140）。hanoi 的停滞归因已定位到 free_list 容量（空闲池余量 **0** 个 preg）——见 §8。

**面积**：默认参数单发射全核 7768.5 µm²（memory 黑盒），落在第 1 档上限 10000 内 →
瓶颈是 IPC 不是面积。详见 `docs/area_budget.md`。

**IPC 口径**：description.md 指定的测试点 `CPU-2026-Benchmark`（6 个 workload）已由用户放入仓库
根目录 `CPU-2026-Benchmark/`。`tb/top/prog/` 的 18 个程序是**功能验证集**（能判对错），**不是** IPC 口径。
接入障碍与计划见 §9。

**下一步**：① 定位 `queens` / `tak` 在 20 拍下的根因（正确性优先）；② 接入 benchmark（§9）；
③ 之后才谈优化（候选已列在 §8）。

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

**§7.4 修复后的 3 拍重型回归（进行中）**：§7.4 改的是发射资源门，理论上 `MEM_LATENCY=3` 下不该有任何
影响（实测全部程序 `block rs=0`）。用**修复后的 RTL** 重跑重型程序确认：

| 程序 | cycles | commit | flush | branch | 与上表 |
|---|---|---|---|---|---|
| basicopt1 | 755464 | 472952 | 45051 | 155139 | 一致 |
| hanoi | 326181 | 130306 | 12830 | 17459 | 一致（cycles/commit 逐位相同） |

其余 6 个（bulgarian/magic/qsort/queens/superloop/tak）仍在跑。**结论：§7.4 的修复在 3 拍下确实零影响。**

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

三档门槛 0.6000 / 0.7800 / 1.0140（单发射上限即 1.0）。**三个在线下，hanoi 差 4.7 倍。**

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
消融矩阵里的 `RAS{0,8,32}` 与 `BHT{16,32,128}` 两行正是为此设的。

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

### 8.1 `queens` / `tak` 归因【进行中】

**已观测**：`lat=20 / inf=16` 下 `queens` 算错、`tak` 出 X（见上）。**复现矩阵**（3 拍 / 20 拍 ×
inf 4/16）进行中 —— **在拿到复现结果前不下结论**。

**为什么值得优先**：这是**正确性**问题，而用户的口径是"先确保程序正确性，再谈优化"。
且它只在性能配置下暴露 → 若性能档评测（`MEM_LATENCY=20`）下算错，IPC 再高也无意义。

**排查方向（待定，按 §7 已验证的方法论）**：
1. 先确定配置相关性：只与 `MEM_LATENCY` 有关，还是也与 `MEM_INFLIGHT` 有关（后者是**本设计的**
   参数，不是评测规定的）。
2. `tak` 的 X 比 `queens` 的错值更好查 —— **X 会传播**，可以顺着 `+TRACE/+FROM` 回放到第一个
   `x` 出现的那一拍，比"答案错在哪"容易定位。**故建议先查 tak**。
3. 若与 §7.4 同族，先查其余"发射资源门"及**所有"本拍腾出的资源下拍才可用"的时序假设**
   （长延迟会把依赖它的窗口拉宽）；若不同族，重点看访存前向（store→load）与 LSQ 失效路径在
   长延迟下的取值时机 —— **"前向时数据还没到"这类窗口会随延迟变宽**，与本缺陷"只在长延迟下犯"
   的特征吻合。

### 9. Benchmark 接入（真正的 IPC 评测口径）

**用户已把评测仓库放入 `CPU-2026-Benchmark/`**（`ACMClassCourse-2025/CPU-2026-Benchmark`，自带
`.git`，是嵌套仓库 → 需决定入库方式：`.gitignore` 还是 submodule）。6 个 workload：
`median` / `multiply` / `qsort` / `rsort` / `towers` / `vvadd`。

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
**注意 ④ 是新增的正确性面**（这 6 个程序从未在本 CPU 上跑过）。

## 消融 + 综合（报告素材）

- 矩阵：W{1,2,4} × ROB{16,32,64} × RS{8,16,24} × PRF{32,64,128} × LSQ{8,16,32} × MEM_LATENCY{3,20} × BHT{16,32,128} × RAS{0,8,32}，3 程序各跑一遍，记录 IPC/提交/冲刷统计（cpu_top 调试输出）
  - MEM_LATENCY 必须含 **20 拍**：description.md 规定性能阶段的内存延迟为 20 拍（功能仿真 3 拍），评估性能档要用 20
- YoSys + ASAP7 实测（默认参数、单发射、当前代码）：全核 **7768.5 µm²**（memory 黑盒另计），mul 554.6；详见 `docs/area_budget.md`
  - 达标口径（description.md）：**面积上限与最低 IPC 同时满足** —— (10000, 0.6000) / (20000, 0.7800) / (40000, 1.0140)；默认配置面积已在第 1 档内，瓶颈是 IPC
  - IPC 评测口径是 **Verilator 跑 CPU-2026-Benchmark**，本仓库的 `+PERF=N` 只是内部对照，报告中须说明两者口径差异
- 可选消融点（报告素材）：RAT 快照恢复 vs walker、值捕获 RS vs 状态式、无延迟内存 vs MEM_LATENCY
