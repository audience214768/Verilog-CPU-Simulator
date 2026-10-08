# RV32IM 乱序 CPU — 架构说明

> 本文只讲**架构本身**：模块层次、参数、时序约定、握手契约与正确性不变量，供读者自上而下读懂本项目的
> RTL（Verilog-2005，可仿真可综合）。评测口径一律以 `docs/description.md` 为准（该文件只由用户手动修改）；
> 本文与 RTL 不一致时**以 RTL 为准**。

## 1. 总览

本项目是一个**可参数化的 RV32IM 乱序执行、按序提交处理器**：默认参数为**单发射**（`ISSUE_WIDTH=1`），
发射宽度、ROB/RS/LSQ/PRF 容量、BHT/RAS、Cache 容量与相联度全部由 `student_top` 的 parameter 收口。

```
student_top                       ← 官方顶层：19 个 AXI4-Lite 端口，reset 高有效（保持 5 拍）
├── cpu_top                       ← 乱序流水线（存储接口外露为端口，与 core/memory.v 对位）
│   ├── fetch ── bht, ras         front/：PC + 预测 + 变长延迟取指握手
│   ├── decode                    front/（纯组合无状态）
│   ├── rat, free_list            重命名映射 / 空闲物理寄存器池
│   ├── rob, rs, ready_table      提交窗口 / 保留站 / 就绪位图
│   ├── prf, cdb                  物理寄存器堆 / 写回总线
│   ├── lsq                       装载-存储队列
│   ├── div                       exec/ 多周期除法（完成经 CDB 槽 W+1）
│   └── execute_slot ×W           exec/ 每槽 alu(adder32, mul) + branch(adder32)
└── mem_subsystem                 ← 存储子系统（唯一的 AXI4-Lite 主机）
    ├── icache                    I 侧 L1：直接映射、行预取
    ├── dcache                    D 侧 L1：组相联、写回 + 脏位、下一行预取
    ├── load 适配                 子字抽取 + miss 队列 + SQ 字节合并链
    ├── store_queue               已提交未可见 store（同时是 AXI 写来源）
    ├── 读口仲裁                  需求 load > 取指填充 > D 填充（AXI 读只有 1 笔 AR/拍）
    └── axi_lite_master           纯 AXI4-Lite 协议层
```

**数据通路（逐级）**

- **取指**（`fetch`，内例化 `bht`+`ras`）：按 `(pc>>2)%BHT_SIZE` 读 BHT 计数器、读 RAS 栈顶做预测，向存储发
  `imem_addr`（下一批基址），把到达批连同 PC/预测方向/目标/RAS head 快照写进 `f2i_*` 批寄存器；执行槽用
  `bht_upd_*` 回报方向、误预测用 `ras_restore_*` 恢复 RAS head。
- **译码**（`decode`）：纯组合出类别单热线、寄存器号、立即数、`writes_rd`、访存宽度/符号。
- **重命名**（`rat`+`free_list`）：`rat` 组合读口把 rs1/rs2 映成物理号（含批内前递），写 `rd → 新 preg`；
  `free_list` 弹出新 preg；被覆盖的旧映射记进 ROB 供回收，同时清 `ready_table` 对应就绪位。
- **派发**（`cpu_top` 发射组合块）：**整批 or 不批** —— ROB/RS/free_list/LSQ 空间齐备（`resources_ok`，
  `cpu_top.v:442`）就整批同时压入 `rob`（new/old preg、`lsq_tag`、原始指令）、`rs`（操作数 preg、pc/imm、
  预测载荷）与 `lsq` 条目。
- **发射**（`rs` 仲裁 → `execute_slot` 的 D/Q/W 三级）：`rs` 按年龄（`rob_tag − rob_head` 回绕）选出
  至多 W 条就绪条目；D 级按 one-hot 索引取字段，Q 级取操作数（`prs==0→0` / CDB 当拍旁路 / `ready_table`
  就绪则读 `prf`）并组合执行 alu 或 branch，W 级把结果登记 CDB 槽、地址/数据写进 `lsq`。
- **执行/写回**（`exec/` + `cdb`）：`alu`（内含 2 位 Booth + Wallace 树的 `mul`）与 `branch` 全组合一拍
  出结果，`div` 由任意槽发起、33 拍后经 CDB 槽 W+1 回来；`cdb` 纯组合合成三源写回（执行槽、load 完成槽
  W、div 完成槽 W+1）——写 `prf`、置 `ready_table` 与 `rob` 的 ready 位（ROB ready 的唯一写者）。
- **提交**（`cpu_top` 提交组合块 + `rob`）：ROB head 起连续就绪的条目按序提交，每拍 ≤W 条且 store ≤1
  （第一个 store 之后截断）；回收 `free_list`、失效 `lsq` 条目、store 经 `sw_*` 直写存储、判定终止锁存 `halt`。
- **回滚**（`cpu_top` walker FSM）：检出误预测当拍即重定向取指、截断 `rob`（`set_last`）、失效
  `rs`/`lsq` 窗口、恢复 RAS head、抑制发射；之后每拍 `ROLLBACK_WIDTH` 条回滚 `rat`/`free_list`/`ready_table`。

## 2. 参数表

默认值 = `verilog/top/student_top.v` 的 parameter 声明；子模块的同名 parameter 默认值只是占位，
`student_top`/`cpu_top` 对每个实例都显式绑定。

| 参数 | 默认 | 含义 | 使用模块 |
|---|---|---|---|
| `ISSUE_WIDTH` (W) | 1 | 取指/发射/执行/提交宽度 | 全部 |
| `ROB_SIZE` | 16 | ROB 条目数（2 的幂） | rob |
| `RS_SIZE` | 4 | 保留站条目数 | rs |
| `PRF_SIZE` | 64 | 物理寄存器数（2 的幂） | prf, rat, free_list, ready_table |
| `LSQ_SIZE` | 8 | 装载-存储队列条目数（2 的幂） | lsq |
| `BHT_SIZE` | 8 | 2-bit 饱和计数器数 | bht, fetch |
| `RAS_SIZE` | 4 | 返回地址栈深度（有效深度 RAS_SIZE−1） | ras, fetch |
| `ROLLBACK_WIDTH` | 4 | 回滚 walker 每拍撤销条数（与 W 解耦） | rat, free_list, ready_table |
| `IC_SIZE` | 512 | I-cache 总容量（字节） | icache |
| `IC_LINE_WORDS` | 8 | I-cache 行字数（2 的幂） | icache |
| `IC_BYPASS` / `IC_PREFETCH` | 0 / 1 | 交付一次即失效（每次都 miss 的归因对照）/ 顺需求行预取下一行 | icache |
| `DC_SIZE` | 2048 | D-cache 总容量（字节；0 = 旁路） | dcache |
| `DC_LINE_WORDS` | 8 | D-cache 行字数（2 的幂） | dcache |
| `DC_WAYS` | 2 | D-cache 相联度（2 路走 LRU） | dcache |
| `DC_PREFETCH` | 2 | D-cache 下一行预取：0 关 / 1 需求缺失起填那拍 / 2 每次命中交付那拍 | dcache |
| `LD_INFLIGHT` | 4 | 在飞 load 上限（AXI 未完成读数） | mem_subsystem |
| `SQ_DEPTH` | 8 | 已提交 store 队列深度（2 的幂） | mem_subsystem |
| `RD_DEPTH` / `WR_DEPTH` | 16 / 8 | AXI 读事务 FIFO 深度（2 的幂）/ 写事务在途上限 | axi_lite_master |

派生量（`cpu_top` localparam）：`PW/RW/LW/SRW/BW/RA = $clog2(PRF_SIZE/ROB_SIZE/LSQ_SIZE/RS_SIZE/BHT_SIZE/
RAS_SIZE)`；计数器宽 `CSW/RCW/LCW/PCW = $clog2(容量+1)`。**参数合法性硬约束**（改参数前对照）：

- `ISSUE_WIDTH ≥ 1`；`ROLLBACK_WIDTH ≥ ISSUE_WIDTH`；`ROB_SIZE ≥ ISSUE_WIDTH`、`RS_SIZE ≥ ISSUE_WIDTH`
  （发射按整批预留空间，不足即永不发射）；`LSQ_SIZE ≥ ISSUE_WIDTH+1`（窗口保留 1 槽表示"空"）；
  `IC_LINE_WORDS ≥ ISSUE_WIDTH`（否则一批可能跨三行，两拍装配不够，`icache.v:54`）；`PRF_SIZE ≥ 63`
  （工程取 64，理由见 §5.2）；`RAS_SIZE ≥ 2`（`$clog2(0)` 未定义）。
- 按位掩码取模的容量必须是 2 的幂：`ROB_SIZE`、`LSQ_SIZE`、`PRF_SIZE`、`SQ_DEPTH`、`LD_INFLIGHT`、
  `RD_DEPTH`/`WR_DEPTH`（指针按 `2^PW` 取模）；`DC_LINE_WORDS`/`DC_WAYS` 也是 2 的幂。
- `IC_SIZE` 为 `4·IC_LINE_WORDS` 的整数倍且行数 ≥ 2；`DC_SIZE` 为 `4·DC_LINE_WORDS·DC_WAYS` 的整数倍
  （组数向上取 2 的幂）；`RD_DEPTH ≥ 2·IC_LINE_WORDS`（一次填充连发 `IC_LINE_WORDS` 笔 AR，而读 FIFO
  实际容量 `RD_DEPTH−1`）；`WR_DEPTH < 从机 AW/W FIFO 深度`（官方从机每通道 16 项）。

## 3. 时序约定

- **复位极性**：官方顶层 `reset` **高有效**（初始化保持 5 拍）；内部一律低有效 `rst_n`，取反只做在
  `student_top` 包层一行（`student_top.v:67`），不给各模块加极性参数。
- **复位风格现存两种，新代码优先异步**：多数模块是异步 `always @(posedge clk or negedge rst_n)`
  （`rob`×2、`rs`、`rat`、`ready_table`、`div`、`axi_lite_master`、`mem_subsystem`、两个 cache、`cpu_top`
  的 walker/halt/计数器），少数同步 `always @(posedge clk)` + `if (!rst_n)`（`prf`、`lsq`、`free_list`、
  `ras`、`bht`、`fetch`）—— ASAP7 r28 库里**没有**同步复位触发器，同步复位会被拆成软逻辑。
- 纯数据阵列（FIFO/队列载荷）的写口无复位分支；**组合逻辑一律 `assign`/`?:`**（不写 `always @*`），状态
  只写在时序块里；每个握手信号 = 1 拍脉冲、单一写者，输出 = 当前状态的组合结果。**CDB 无寄存器**：结果
  当拍组合到达 ⇒ 当拍旁路、当拍 posedge 写 PRF/置 ready；模块内部优先级统一 flush > commit > issue > exec。

## 4. 前端

### 4.1 `front/fetch.v` — 取指与预测（内部例化 `bht` + `ras`）

| 端口 | 位宽 | 含义 |
|---|---|---|
| `f2i_valid/raw/pc/pred_taken/pred_target/ras_snap` | W / 32W / 32W / W / 32W / W×RA | 到 decode 的批（寄存器输出；stall 保持，redirect 清 0，批内首个预测跳转之后 valid 截断） |
| `imem_addr` / `inst_data` / `imem_valid` / `imem_hit` / `imem_direct` | W×32 / W×32 / 1 / 1 / 1 | 存储口：批基址+4i / 数据 / "这拍数据属于上一拍地址" / "本拍地址整批可取" / "本拍到达是直通行交付" |
| `bht_upd_req/idx/taken`、`ras_restore_valid/head` | W / W×BW / W；1 / RA | 执行槽的条件分支更新；误预测 RAS head 恢复 |
| `stall` / `redirect_valid` / `redirect_pc` / `halt` | 1 / 1 / 32 / 1 | 后端背压 / 重定向 / 冻结 |

**取指握手契约（★ 改存储或改 fetch 前必读）**

- `imem_addr` 是**需求**语义：本拍要向存储请求的**下一批**地址 = `exp_pc_r` 的下一个值（组合输出，
  `fetch.v:229`），不是"上一拍请求过的地址"。存储契约是"本拍地址 → 下拍交付"，而接收判据是
  `arr_ok = (imem_addr_d == exp_pc_r)` ⇒ **`imem_addr(T)` 必须 ≡ `exp_pc_r(T+1)`**：预测跳转与重定向的
  **那一拍**地址就要跟着转向，否则目标批晚一拍到。
- `imem_valid`：说明"本拍 `inst_data` 属于上一拍锁存的地址"；变长延迟下数据未回时为 0（`inst_data`
  仍是旧值）—— 接收与"预测可信"（`pred_ok_w`）都必须以它为前提。
- `imem_hit`：本拍 `imem_addr` 上的地址**已可取**（固定 1 拍存储恒 1）；只有它成立才允许把请求提前
  一批（`pc_lead_w`，`fetch.v:199`）。**口径必须是整批 W 个字**：只比批首时，W≥2 下"槽 0 已回、槽 1
  未回"也放行超前 ⇒ 请求地址每拍翻转、预取流永远重启，一笔 AR 也发不出去。
- **不变量 `pc_r ∈ { exp_pc_r, exp_pc_r + 4W }`**：稳态 `pc_r == exp_pc_r`（在途批由组合的 `imem_addr`
  承担）；数据迟到时 pc 停在 `exp_pc_r` 上**重复请求它**，绝不盲目超前。
- **满批丢弃回退（rewind）**：stall 期间到达的期望批因批寄存器满被丢弃 ⇒ 丢弃拍把 PC 退回 `exp_pc_r` 重取
  （`fetch.v:93`）；**复位期强制 `imem_addr = pc_r`**（`fetch.v:229` 首支），否则释放后首批会被错绑到批 0。
- **预测/RAS 操作只在接收拍生效**（`fetch_ok = cap_nb_w && !redirect_valid && !halt`），且 **RAS 操作
  只对"首个预测跳转之前的前缀"驱动**（`fetch.v:140`）：截断之后的槽属错误路径。`cap_nb_w` 用无环版
  交付指示 `imem_direct` 选通，避免 `ras_top → imem_addr → imem_valid → cap → ras_ops` 的组合环。
- **PC 与 `exp_pc_r` 跟随首个预测跳转**（低槽优先，`fetch.v:188`）—— 同批第二个预测跳转在截断之后，
  不得改写 PC。halt 冻结取指；redirect 优先于 stall（否则错路批会在冲刷结束后被发射）。

### 4.2 `front/bht.v` — 分支历史表

| 端口 | 位宽 | 含义 |
|---|---|---|
| `counters` | 2·BHT_SIZE | 全阵列读出（fetch 按 pc 索引选） |
| `upd_req` / `upd_idx` / `upd_taken` | W / W×BW / W | 执行槽实际方向更新（仅条件分支） |

2-bit 饱和计数器（复位 `2'b01`，弱不取），W 个写口按槽序正序应用、同索引时高槽（更年轻）最后写则赢；
**不变式**：各槽新值都取自"旧值快照" ⇒ 同批同索引别名时只体现最年轻分支的一次更新。

### 4.3 `front/ras.v` — 返回地址栈

| 端口 | 位宽 | 含义 |
|---|---|---|
| `top` / `head_snap` | W×32 / W×RA | `top[i]` = 处理 `ops[0..i-1]` 后的栈顶（ret 预测目标）；`head_snap[i]` = 处理 `ops[0..i]` 后（**含**本槽 push/pop）的 head |
| `ops` / `push_val` / `restore_valid` / `restore_head` | W×2 / W×32 / 1 / RA | 每槽 0=无 1=push 2=pop（push 值 = pc+4）；误预测恢复（优先级 > 本拍 ops） |

- **有效深度 = `RAS_SIZE−1` 条**：head 只有 RA 位（`head_snap` 原样喂恢复通路），满栈判据
  `head == RAS_SIZE−1`，最后一项用不上。push/pop 判据（在 `fetch.v`）：call = `jal`/`jalr` 且
  `rd ∈ {x1,x5}` ⇒ push pc+4；ret = `jalr` 且 `rd==x0` 且 `rs1==x1` ⇒ pop。
- `head_snap[i]` 必须**含**本槽 ops：误预测重定向去的是该指令目标、它自己不重取；恢复值若撤销它自己的
  push/pop，每次调用都会被自己的误预测撤销（RAS 恒空）。空栈 pop 忽略、满栈 push 丢弃；栈数组随复位清零。

## 5. 后端

### 5.1 `front/decode.v` — 译码（纯组合无状态）

| 端口 | 位宽 | 含义 |
|---|---|---|
| `raw`/`d_valid`/`writes_rd`、`opcode`/`func3`/`func7`、`rd`/`rs1`/`rs2`/`imm` | W×32 / W / W；W×7 等；W×5 ×3 / W×32 | 指令字、有效、写目的（rd≠0 且写；store/branch/非法/终止指令为 0）；字段与 6 型立即数符号扩展（非法 → 0） |
| `is_alu … is_auipc`（10 条单热线）、`mem_width`/`mem_unsigned` | W 各；W×2 / W | 互斥单热类别；访存字节数（00=1 01=2 10=4）与 load 无符号 |

合法性门含 func3/func7 合规检查，不合法 → 全类别 0。终止指令 `addi a0,x0,255`（`0x0FF00513`）的 rd
视作 x0 ⇒ 不分配 prd、不改 a0 映射。

### 5.2 `core/rat.v` + `core/free_list.v` — 重命名与物理寄存器池

| 模块 | 端口 | 位宽 | 含义 |
|---|---|---|---|
| rat | `map_out1/map_out2`；`read_rs1/rs2`、`rename_valid/rd/new`、`flush_valid/rd/old` | W×PW；W×5 ×2；W / W×5 / W×PW；RW / RW×5 / RW×PW | 组合读口，**含批内转发**（读口 i 看到 rename j<i，最后匹配者赢）；读地址；发射重命名（valid 是前缀）；walker 回滚（写优先级 > rename，槽序更老者最后写） |
| rat | `map_arch` | 32×PW | 全阵列输出（调试；`ret_val` 采样 `map_arch[10]`） |
| free_list | `alloc_val` / `pop_req` | W×PW / W | 槽 i = 栈顶起第 `pc_pre[i]` 个空闲 preg（仅在 `pop_req[i]` 时有效） |
| free_list | `count_out` / `push_valid`+`push_preg` | PCW / RW / RW×PW | 本拍可分配量（= 栈内空闲数，**不含本拍 push**）；回收（commit 与 walker 复用，互斥） |

- `rat` 复位为**恒等映射** `map[i]=i`；写优先级 flush > rename。`free_list` 是 **LIFO 栈 + 真实存储**
  （`FREE_NUM = PRF_SIZE−32` 项 × PW 位）：回收顺序不按分配序到达，环形池的"head+i"组合计算表示不了；
  复位 `sp = FREE_NUM`、栈顶 = 32（首次分配得 preg 32）。
- **`push_ok[c] = push_valid[c] && (push_preg[c] != 0)`**：只挡 preg 0（x0 恒等映射，永不复用），恒等
  映射区 1..31 被放弃时**照常回池**。**PRF 下限 63**（工程取 64）：被架构映射占住的池内 preg 数上界 31
  （x0 只读不写）⇒ 更小的点会在"写多个目的寄存器"的程序上永久死锁，与 `ROB_SIZE` 无关。
- 同拍 push/pop：push 正好写在本拍 pop 腾出的槽位（`pool[sp−pop_cnt+ps_pre]`）；写到栈顶之上会残留
  旧值，下拍 pop 到已分配的 preg。

### 5.3 `core/rob.v` — 重排序缓冲

| 端口 | 位宽 | 含义 |
|---|---|---|
| `head`/`last`/`empty`/`full` | RW / RW / 1 / 1 | 环形指针与状态（满/空用 free 计数区分，不靠指针相等） |
| `free_count` / `set_head_valid`+`val` / `set_last_valid`+`val` | RCW / 1+RW ×2 | 当前空闲（本拍提交数由 cpu_top 相加）；提交推进；flush 截断 |
| `ready`/`opcode`/`rd` | ROB_SIZE / 7·ROB_SIZE / 5·ROB_SIZE | 完成位（唯一写者：CDB）/ 类别 / 目的寄存器 |
| `new_pnum`/`old_pnum`、`lsq_tag`/`ins_raw`、`push_valid`+`push_*` / `set_ready_req` | PW·ROB_SIZE ×2；LW·ROB_SIZE / 32·ROB_SIZE；W 各 / ROB_SIZE | 目的 preg / rename 前映射；提交时取 store 条目 / 终止检测；发射（push 时清该条目 ready）/ CDB 完成置位 |

写优先级：`set_last`（flush 截断；head 若被截则收敛到 `last+1`）> `set_head` > `set_ready` > `push`；
`set_last_val = fs + 1`（`cpu_top.v:676`）—— last 是"空槽位"语义，截到 `fs` 会丢掉误预测分支自己（jalr 的
link 与它占的 preg 回池都没了）。

### 5.4 `core/rs.v` — 保留站

| 端口 | 位宽 | 含义 |
|---|---|---|
| `sel_valid` / `sel_idx`；`free_count` | W / W×SRW；CSW | 年龄优先仲裁结果（槽 0 最老；槽间互斥、同年龄低条目号赢）；当前空槽数（严格 = `!valid_r` 计数，**不含本拍 clear 腾出的槽**） |
| `entry_*` | 各 ×RS_SIZE | 条目字段（valid/opcode/func3/func7/prs1/prs2/prd/pc/imm/lsq_tag/rob_tag/pred_taken/pred_target/ras_snap） |
| `rt_ready` / `cdb_tag` / `cdb_slot_valid` / `rob_head` | PRF_SIZE / (W+1)·PW / W+1 / RW | 就绪判断输入（**只有 load 槽参与**）；年龄比较 |
| `push_valid`+`push_*` / `clear_valid`+`clear_idx` / `flush_mask` | W 各 / W+W×SRW / RS_SIZE | 发射（扫描分配空槽）；选中自清；窗口失效 |

**状态式保留站**：只存物理号 + 译码字段，不存操作数；就绪 = `prs==0 || load CDB 命中 || rt_ready`；
仲裁是**锦标赛树**（(valid, age) 全序的结合律，深度 O(log₂ RS_SIZE)）；写优先级 `flush_mask` > clear >
push。**push 前置条件**：`push_valid[k]=1` 必须有第 k 个空槽（调用方用 `rs_free >= ISSUE_WIDTH` 保证），
违约时 `pidx[k]` 是无主索引、会写坏任意条目。执行槽广播不参与就绪判断（会成环），执行依赖靠 `rt_ready`；
`cdb_slot_valid` 只有 `W+1` 位（槽 0..W−1 执行 + 槽 W load）。

### 5.5 `core/ready_table.v` + `core/prf.v` — 就绪位图与物理寄存器堆

| 模块 | 端口 | 位宽 | 含义 |
|---|---|---|---|
| ready_table | `ready` / `set_req`/`clear_req`/`flush_clear_req` | PRF_SIZE ×4 | 就绪向量（→ `rs` 全阵列）；CDB 置位 / rename 清零 / walker 回滚清零 |
| prf | `rd1_preg`/`rd2_preg` → `data_out1`/`data_out2`；`wr_valid`/`wr_preg`/`wr_data` | W×PW / W×32；W+2 / (W+2)·PW / (W+2)·32 | 索引读口（**`preg==0` 短路输出 0**；槽 0 读口复用为 `ret_val` 采样）；写回（仅 CDB 单一来源） |

优先级 `flush_clear > clear > set`：同 preg 同拍 set+clear ⇒ **clear 赢**（刚重新命名的 preg 新值未就绪）。
复位 0..31 置 1、其余 0，**preg 0 常就绪**且不可清。`prf` 读口用 one-hot + AND-OR 归约（避免综合出
索引最低位落在最宽一级的 mux 树）；每个 preg 每生命周期恰好写一次（rename 单射 + commit 回收才复用）。

### 5.6 `core/cdb.v` — 公共数据总线（纯组合写回扇出）

| 端口 | 位宽 | 含义 |
|---|---|---|
| `exec_*` / `load_*` / `div_*` | W 组 / 1 组 / 1 组 | 生产者：执行槽 / load 完成（≤1/拍）/ div 完成（≤1/拍，隐含 `rob_wr=1`） |
| `prf_valid/prf_preg/prf_data`；`rt_set_req` / `rob_ready_req` | W+2 组；PRF_SIZE / ROB_SIZE | 写回口（→ prf）；就绪置位掩码（→ ready_table / rob） |

- 广播槽：`0..W−1` = 执行（**参与同拍旁路**）、槽 `W` = load 完成、槽 `W+1` = div 完成。
- **同拍不回绕规则**：槽 `W`/`W+1` 不参与同拍旁路（`ready_table` 是寄存器，被唤醒的依赖者最早下拍才被
  选中，那时 PRF 已写入）；执行槽参与旁路但不回绕进 `rs` 就绪判断（会成环）。`prd==0` 的槽不写 PRF、
  不置 ready；`rob_wr` 的槽按 tag 置 ROB ready。div 不共用槽 `W`（load 完成是组合脉冲、不可延迟，
  共用会让除法在 load 密集循环里长期饿死）。

## 6. 访存

### 6.1 `core/lsq.v` — 装载/存储队列

| 端口 | 位宽 | 含义 |
|---|---|---|
| `head`/`last`/`full`/`free_count` / `rob_head` | LW ×2 / 1 / LCW / RW | 环形窗口（保留 1 槽；head 每拍跳过连续死条目）；年龄比较 |
| `valid`/`is_load`/`addr_ready`/`data_ready`、`addr`/`data`/`rob_tag`/`prs2_or_prd`/`width`/`is_unsigned` | LSQ_SIZE 各 | 条目状态与内容（store 存 rs2 的 preg，load 存目的 preg） |
| `push_valid`+`push_*` / `set_addr_req/idx/val`、`set_data_req/idx/val` | W 各 | 发射建条目；执行槽写地址 / store 数据 |
| `flush_mask` / `invalidate` | LSQ_SIZE 各 | 窗口失效 / 提交后失效（**延迟一拍**到达） |
| `mem_done_valid/idx/data`、`ld_busy`、`ld_start_valid/addr/width/idx` | 1 / LW / 32 / 1；1 / 32 / 2 / LW | 存储完成与背压（`ld_busy` 见 §6.2）；组合发起（→ 存储） |
| `load_cdb_valid/prd/result/rob_tag/rob_wr` | 1 / PW / 32 / RW / 1 | load 完成（→ CDB 槽 W） |

- **窗口语义**：`[head, last)` 环形、**保留 1 槽** ⇒ 占用 ≤ `LSQ_SIZE−1`，`head == last` 唯一表示"空"；
  `free_count` 由 head/last 组合导出，已含本拍失效腾出的槽。
- **`cand` 是距离索引**：位 gd（距 head 的偏移）↔ 条目 `(head_r + gd) & (LSQ_SIZE−1)`，输出的 `head` 则是
  **条目号**。距离链 `store_ok[0]=1'b1`、`store_ok[gd+1] = store_ok[gd] && 前一条目不是未执行完的 store`
  （`lsq.v:128-144`）⇒ 最老候选 = 最小距离；`cand` 额外含 `!kill`（`kill = flush_mask | invalidate`）。
- **发起/在飞语义（`issued_r`）**：条目号是完成与请求之间**唯一**的身份标识 —— 发起被接受即置位、完成才清
  （不重复发起）；在飞条目即使 `valid` 被清也**不算死** ⇒ head 不跳过它、槽位不被复用，完成当拍读到的
  字段必然还属于原请求（否则陈旧完成写坏新条目的目的寄存器）；代价是 flush 恰逢在飞 load 时 head 最多
  阻塞一个存储往返（不死锁）。
- 发起条件 = 最老未完成 load ∧ `addr_ready` ∧ 所有更老 store 都已执行完 ∧ `!ld_busy`。完成时**字节合并
  前向**：逐字节取"更老、未提交、已执行 store"的重叠字节覆盖内存数据，再按宽度与 `is_unsigned` 做**符号
  扩展**（`lsq.v:291-297`）。写优先级 flush > invalidate(commit) > push > set_*。

### 6.2 `core/mem_subsystem.v` — 存储子系统

内部四块：**icache**、**dcache**、**load 适配**（miss 队列 + 子字抽取 + SQ 字节合并）、**已提交 store
队列**，外加**三路 AR 仲裁**。CPU 侧端口与 `core/memory.v` 逐一对位 ⇒ `cpu_top` 一行不改。

| 契约 | 内容 |
|---|---|
| 取指 / `imem_direct` | `imem_hit`/`imem_valid` 口径是**整批 W 个字**（命中 1 拍交付，未命中走填充不交付）；`imem_direct` 是 `imem_valid` 的无环投影（不含跨行装配支、不依赖 `imem_addr`），不变量 `imem_direct ⇒ imem_valid`，W=1 下二者逐位相等 |
| `ld_busy==0` | **必须当场兑现**：`lsq.v` 的 `ld_start_valid` 组合自 `!ld_busy`、收到即置 `issued_r`；反悔 ⇒ 条目永久在飞 ⇒ head 卡死 ⇒ 全机死锁。由"在飞数 + 本拍推送项 + D-cache 当拍能否收下"组合决定（`mem_subsystem.v:235`） |
| 完成脉冲 / 子字 | 每个被接受的 load **恰好**一个 `ld_done_valid`（`mem_subsystem.v:264`；`rresp` **不参与门控**，少一个脉冲就是死锁）；`araddr` 强制 4 字节对齐、回包右移 `8·addr[1:0]` 后**零扩展**（符号扩展由 `lsq.v` 做），不支持跨 4 字节边界的非对齐访问 |
| store 可见性 | 合并层次 **`memory` < `store_queue` < `LSQ`**；条目退休 = **已可见（被缓存吸收或 B 已握手）且"可见那拍之前发出的 load"都已回**（只等 B 不够：那些读可能在该 store 落盘前被服务）；提交与完成同拍的那条 store 由**上层 LSQ** 兜（并入会造组合环） |
| 背压 / 仲裁 | 队列满 ⇒ `sw_ready=0` ⇒ `cpu_top` 压住该拍提交（提交路径唯一背压点）；AR 仲裁 需求 load > 取指填充 > D 填充（三者都是有限长度事务 ⇒ 低优先者不被无限饿死） |

`store_queue` 三指针不变式 `ret ≤ snd ≤ iss ≤ wr`：`[ret,snd)` 已定局、`[snd,iss)` 已判旁路待发、
`[iss,wr)` 未判定；判旁路那拍 `iss` 即前进（不等 B），被吸收的条目由 `snd` 逐拍跳过。合并链必须按
**年龄**遍历（三指针自由回绕，按槽号扫会让最老的 store 赢 = 写反）。

### 6.3 `core/icache.v` — I 侧 L1（直接映射）

行数据 + tag 同放一块 `sram_fakeram`（valid 只用 DFF 位图）；默认参数 ⇒ 16 行 × 32 B。不变量：① SRAM
读地址 ≡ `line(本拍正在取的地址)`（仅跨行装配那拍改写成 L1 行基址）；② `imem_valid(T) = !rd_div_r &&
rd_ok_r && valid[q_line] && (条目 tag == rd_addr_q 的 tag)`（tag 与数据必然同源，**不是**拿 `imem_addr`
去比）；③ `imem_hit(T)` = 不跨行 且 批内各槽目标行 valid 全 1（保守、不查 tag、同拍整批口径）；
④ `imem_direct` = "直通行"交付（`!st_wait_r && ②`），**不得依赖 `imem_addr`**。

- miss 判据必须挂在"交付失败"上（`rd_ok_r && !ent_ok`），不能挂在"请求地址已稳定"上 —— 否则假命中让 pc
  每拍翻转、"已稳定"永不成立，一次填充也发不出去。单端口 SRAM：填充写**绝对优先**，被偷走的读显式作废
  （`rd_ok_r=0`）；发起填充时**立刻清 valid**（否则旧数据被新 tag 冒充 = 假命中），最后一字落地才置 valid。
- 跨行批（仅 W≥2 可达）走两拍装配（先锁 L0 尾部窗口进 `tail_r`、再把读地址改指 L1 行基址），装配期
  `imem_hit` 恒 0 ⇒ pc 钉住不动；不缓存自修改代码（ISA 豁免 `FENCE.I`，I 侧无一致性硬件）。

### 6.4 `core/dcache.v` — D 侧 L1（组相联、写回）

默认参数 ⇒ 32 组 × 2 路 × 32 B；tag 与数据同放一块 `sram_fakeram`（一拍读出所有路 tag、T+1 并行比较
⇒ 多路不需要多读口）。

- **写回 + 脏位**：缓存行是数据权威，内存只是备份。驱逐脏行时先用读口把整行捕获进 1 项 WB 缓冲、再
  排水到写通道、收齐 B 才松手；**替换** = 最低空路优先（2 路下"命中路 +1"即 LRU 路）。**写粒度 32 位**
  （`WRITE_GRANULARITY=32`）：store 命中就地更新行并置脏（`st_absorb`），未命中旁路给 AXI（`st_bypass`），
  去向在 store **退休**那拍由 dcache 判定。
- **单交付源不变量**：命中在 T+1 交付、AXI 回包任意拍交付，二者可能撞车而 LSQ 只有一个完成口 ⇒
  `hit_valid = 命中 && !rsp_busy`（抢输的命中降级为缺失或重放），保证每拍恰好一个 `ld_done_valid`。
- **MSHR 与污染（poison）**：单条在填行合并（同行缺失不重发 AR，最后一字落地那拍重放该 load）+ 1 条
  排队寄存器；起填前/中只要有"尚未可见"的 store 落在**同一行**，本次填充作废（粘滞污染位、行粒度、
  安装那拍也抑制；豁免"本帧就落在在填行的缓存型 store"）。
- **下一行预取**：`DC_PREFETCH` 0 关 / 1 需求缺失起填那拍 / 2 每次命中交付那拍，登记进 1 槽排队、填充器
  空闲时消化；**起填前必须显式查存在性** —— 对已驻留行再起填会让 victim 落到另一路，安装时清理会静默
  作废那一路的脏副本（该行吸收过的 store 永远到不了内存）。
- **单端口 SRAM 冲突**：填充安装 / store 就地更新绝对优先，WB 捕获读次之，被偷走的查表读必须**重放**
  （写周期 `rdata` 不可信）；在线冲突各一个比较器：同一行的填充不起、同一行的旁路 store 不发。

### 6.5 `core/axi_lite_master.v` — 纯 AXI4-Lite 协议层

只做 5 通道握手与 VALID 稳定性，不含存储语义（对齐/越界/MMIO 一律由从机裁决）。

- 读/写各一组四指针 FIFO（收请求 → 发 AR/AW → 收 R/B → 交付）。**无 ID** ⇒ R 严格按 AR 序、B 严格按
  AW 序返回；请求 tag 随响应原样回传（读 2 位区分三个读用户，写多 1 位区分 SQ 旁路 store 与 WB）。
- **`rready`/`bready` 恒 `1'b1`**：不驱动 `bready` ⇒ 停机 store 的 B 永不握手 ⇒ 从机 `done` 永假 ⇒ 每条
  用例超时（最容易"功能全对却零分"的一处）。**AW 与 W 由同一 FIFO 条目在同一拍驱动**、两通道都握手才
  推进 ⇒ AW 序 == W 序 == 提交序（从机"按位置配对 `aw.front()`/`w.front()`"）；地址/数据取自只在握手拍
  才动的 FIFO 条目 ⇒ **VALID 稳定性结构上免费获得**。`RD_DEPTH`/`WR_DEPTH` 是主要寄存器开销。

## 7. 执行单元

| 模块 | 结构 |
|---|---|
| `exec/adder32.v` | 参数化宽度加法器，单条连续赋值：`{cout,sum} = a + b + cin` |
| `exec/mul.v` | 32×32：radix-4（**2 位 Booth**）编码出 17 个部分积 + 1 行校正位 → **6 层 Wallace 列压缩**（18→12→8→6→4→3→2）→ 64 位 `adder32`；`a_signed`/`b_signed` 选符号模式（MUL/MULH/MULHSU/MULHU） |
| `exec/branch.v` | 纯组合无参数；`mode` 0=branch / 1=jal / 2=jalr；`br_op` 0=beq 1=bne 4=blt 5=bge 6=bltu 7=bgeu。输出 `taken`（mode=1/2 恒 1）、`target`（branch/jal = pc+imm；jalr = `(rs1+imm)&~1`）、`link`=pc+4；内部 4 个 `adder32` |
| `exec/div.v` | radix-2 **恢复余数**：32 次 + 1 拍输出 = **恰好 33 拍**。取 `|a|/|b|` 迭代后按符号修正；恢复式 `R ∈ [0,|b|)` ⇒ `Rs={R,A[31]}` 33 位无符号足够、无末尾修正步；除零（商全 1 / 余 = 被除数）与 `INT_MIN/−1` 显式 mux。`kill` 只作废**在飞**那一发（判据 `kill && busy_r`，空闲时不得吞掉同拍新 start——那条指令的 RS 条目已被上层清掉，漏收即死锁） |
| `exec/execute_slot.v` | 每槽一份、**三级流水**：D 级按 `sel_idx` one-hot + AND-OR 取字段（144 位切点）；Q 级取操作数 + `alu`/`branch` + 误预测检测；W 级登记消费者侧产物（CDB/访存，114 位切点）；div 只**发起**（`exec_valid` 置 0） |

`exec/alu.v`（纯组合，内部例化 `adder32` + `mul`）op 编码：

| op | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10..13 | 14..17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 运算 | add | sub | sll | slt | sltu | xor | srl | sra | or | and | mul/mulh/mulhsu/mulhu | div/divu/rem/remu（仅占位，返回 0） |

LUI/AUIPC 由 `cpu_top` 映射为 add（a=0/pc，b=imm），alu 无需 pc 输入。乘法器输入由
`sel_prod = (op ≥ 10) && (op ≤ 13)` 门控：不收窄到 13 的话，除法占位编码会点燃整棵华莱士树。

**execute_slot 四条不变量**（改流水必须维持）：① RS 条目在入选那拍就被清（`cpu_top.v:263`）⇒ 凡要
"扣住"只能扣**流水寄存器**；② "扣寄存器"（`q_freeze`）与"放过条目"（门控 `rs_clear` 的 `pipe_stall`）
必须**同条件**，否则会"条目被清却没进寄存器"（丢失）或"没清却进了寄存器"（重复执行）；③ 误预测当拍
**清空**寄存器而非冻结（冻住则 `misp_det` 自持续 ⇒ 死循环），清哪些槽必须由 `cpu_top` 逐槽按年龄给
（`flush_hit`）；④ 冲刷窗口内冻结 D→Q 移交（否则进来的 div 会因条目已被清而逃过 RS 失效掩码）。

## 8. 顶层与官方框架对接

### 8.1 `top/student_top.v`

官方顶层：固定 19 个 AXI4-Lite 端口（`clock`/`reset` + AR/R/AW/W/B，端口名一个不改），`reset` **高有效**、
初始化保持 5 拍；内部 `wire rst_n = ~reset;`（`student_top.v:67`）后例化 `cpu_top` 与 `mem_subsystem`。
**终止**：程序向 MMIO `0x80000000` 做一次 32 位 store（`WSTRB=4'hf`）⇒ `cpu_top` 内 `mmio_exit` 拉起 `halt`
（`cpu_top.v:880`）；退出值由官方从机在 B 握手时从 `WDATA[31:0]` 取（本模块不引出 `ret_val`），TERM
marker 判定与其 OR 并存。

### 8.2 `top/cpu_top.v`

| 端口 | 位宽 | 含义 |
|---|---|---|
| `clk` / `rst_n` / `halt` / `ret_val` | 1 / 1 / 1 / 8 | 时钟 / 异步低有效复位 / 终止已锁存 / ROB 排空后 `prf[map_arch[10]] & 0xFF`（TB 诊断口） |
| `commit_count`/`flush_count`/`branch_count`、`rob_head`/`rob_ready_head` | 32 各；RW / 1 | 性能统计（halt 后冻结）；调试 |
| `imem_addr`/`inst_data`/`imem_valid`/`imem_hit`/`imem_direct` | W×32 / W×32 / 1 / 1 / 1 | 取指存储口（契约见 §4.1 / §9） |
| `ld_start_*`、`ld_done_*`、`ld_busy` | 1 / 32 / 2 / LW 等 | load 口（发起 ≤1/拍、完成 ≤1/拍） |
| `sw_valid/addr/data/width`、`sw_ready` | 1 / 32 / 32 / 2 / 1 | store 口（提交级 ≤1/拍；`sw_ready=0` ⇒ 本拍不提交） |

内部组合块（全部 `assign`/`generate`，无隐藏模块）：**B2 发射**（整批 or 不批 + 批内 rename/free_list/
ready_table 副作用）、**B3/B4 执行分发与误预测汇出**（最老优先前缀 OR，当拍抑制发射）、**B5 walker**
（每拍 `ROLLBACK_WIDTH` 条回滚）、**B6 提交**（连续就绪、store ≤1、终止判定、计数器）；提交级的 ROB/LSQ
索引读全部 one-hot + AND-OR（索引最低位从最宽 mux 级挪走，削扇出）。

### 8.3 官方框架关键契约

| 项 | 内容 |
|---|---|
| 顶层与端口名 | 必须命名 `student_top`，AXI4-Lite 端口模板固定（框架 C++ 驱动按名引用 `top.araddr`/`top.rvalid`…；综合按名取时钟端口 `clock`）；`reset` 高有效、初始化保持 5 拍 |
| 内存 | 外部 **256 MiB** 统一内存（`0x00000000`–`0x0fffffff`），AXI4-Lite 从机 |
| 从机语义 | AR/AW/W/R/B 各 16 项队列；握手当拍入队、下一拍起才可能被服务；每拍最多 1 读 + 1 写，**跨通道顺序无保证**；服务到响应 **LATENCY 默认 10 拍** |
| `make run` / OJ 协议 | `make run` argv：`sim IMAGE EXPECTED MAX_CYCLES LATENCY [WAVE]`（stdout 打 PASS/FAIL，退出码即判据）；OJ（`argc == 1`）stdin = `CPU2026-OJ 1\n{max_cycles} {latency}\n{镜像}\n`，stdout **只许一行** `{退出值}\n`（多余输出不被容忍），stderr 打 `CPU2026 cycles=N`（IPC 分母） |
| 终止 | 向 MMIO `0x80000000` 做 32 位 store（`WSTRB=4'hf`），退出值 = `WDATA[31:0]`；**B 通道握手那一拍**从机才置 `done` ⇒ `bready` 必须驱动；**子字 store 到该地址不终止**（普通写、从机返回 SLVERR） |
| 周期上限 | 默认 1 000 000 拍；RTL 里调 `$finish` 会提前中止且 `done` 未置位 ⇒ 仿真代码不得进综合路径 |
| 面积口径 | Yosys + ABC → ASAP7 7.5-track RVT TT + OpenSTA；`sram_fakeram` 估算面积**计入总面积**；**禁止用寄存器组当内存**（DFF 贵约 7 倍） |
| SRAM 估算与约束 | 单实例面积 ≈ `DEPTH × WIDTH × 0.0419904 µm²`（按写掩码 lane 分别取整后求和；`DEPTH` 是**条目数**不是字节数）。`sram_fakeram`：参数 `DEPTH`/`WIDTH`/`WRITE_GRANULARITY`，端口 `clk/en/we/wmask/addr/wdata/rdata`；**同步单端口 1RW**（一拍只能读或写）、读延迟 1 拍、**无复位引脚**、越界地址报错；单实例 `DEPTH×WIDTH ≤ 2^24` bit；**不得写进 `filelist.f`**，不得自写 stub |

## 9. 关键握手契约与不变量（`cpu_top` ↔ 存储）

新写存储或换存储必须照此实现：

| # | 契约 |
|---|---|
| 1 | `imem_addr` = **本拍要向存储请求的批地址**（需求，不是"上一拍发过的"）；存储必须在下一拍把**上一拍地址**的数据摆上 `inst_data`，并用 `imem_valid` 说明"这拍 `inst_data` 属于它" |
| 2 | `imem_hit` = 本拍 `imem_addr` 上的地址**已可取**（固定 1 拍存储恒 1）—— fetch 用它判断能否把请求提前到下一批；变长延迟存储必须真实实现（整批口径） |
| 3 | `imem_direct` = `imem_valid` 的无环投影（不含跨行装配支、不依赖 `imem_addr`），不变量 `imem_direct ⇒ imem_valid`；W=1 下与 `imem_valid` 逐位相等 |
| 4 | `ld_busy==0` 是**必须当场兑现**的承诺（LSQ 收到即置 `issued`）⇒ 反悔即全机死锁 |
| 5 | 每个被接受的 load **恰好**回一个 `ld_done_valid`（`rresp` 不门控 —— LSQ 没有错误口） |
| 6 | `ld_done_data` 只做**零扩展**，符号扩展在 `lsq.v` 内（按 `is_unsigned` 与宽度） |
| 7 | `sw_valid` 是提交级 1 拍脉冲（`sw_ready=0` ⇒ 该拍不提交该 store，提交路径唯一的背压点）；已提交 store 必须在队列里留到 **B 已握手 且 该 B 之前发出的 load 都已回** |
| 8 | store 可见性次序 **`memory` < `store_queue` < `LSQ`**；合并链**不含**本拍正在提交的那条 store（由 LSQ 兜住；硬并入会造出 `sw_valid → load 回包 → … → sw_valid` 的零延迟组合环）。一笔 AR 恰好一个 R、一个 B 恰好对一笔 AW：丢响应/重发都会写坏目的寄存器或让 store 永不退休 |

## 10. 不变量与陷阱清单

**取指 / 前端**

1. 满批丢弃必须回退（rewind）：stall 期间到达的期望批被批寄存器丢弃时要把 PC 退回 `exp_pc_r` 重取。
2. 截断槽污染 RAS：批内首个预测跳转之后的槽属错误路径，RAS 操作只对"首个预测跳转之前的前缀"驱动。
3. PC 与 `exp_pc_r` 跟随**首个**预测跳转（低槽优先），不是最后一个。
4. `imem_addr` 的"上一拍地址"必须按槽 W×32 位保存、复位值 = `4g`；单地址或全 0 会让复位后首批批内 pc 错位。
5. `imem_hit` 必须整批口径；只比批首会让 W≥2 的请求地址每拍翻转、预取流永远重启。
6. `pred_ok` 必须含 `imem_valid`：数据未回时 `inst_data` 是旧指令，用它的预测目标改 PC 就是被劫持。
7. 发射压入必须带 `f2i_valid[s]`：它是稠密前缀，漏掉错路槽会以全 0 字段进 ROB（永不就绪）。
8. RAS 有效深度 = `RAS_SIZE−1`；空栈 pop 忽略、满栈 push 丢弃；栈数组随复位清零（不是 X）。

**重命名 / 发射 / 后端**

9. 批内 rename 前递（RAT 读口最后匹配者赢）；`old_map` 链必须逐级比较"本批早于 s 的最后一个同 rd
   写者"——回落到前一槽的映射会记错 old（提前回收别人的 preg ⇒ 池内重复项 ⇒ 依赖者永不就绪）。
10. `writes_rd` 门控（rd=0 / store / branch / 非法 / 终止指令不重命名），否则 x0 被重命名。
11. `ready_table` 优先级 `flush_clear > clear > set`；同 preg 同拍 set+clear ⇒ clear 赢；preg 0 常就绪。
12. `free_list` 只挡 preg 0；写成"只回收 ≥32"会让恒等映射区永久占住池 ⇒ 全写批发不出（死锁）。
13. `free_list` 的 push 必须写在本拍 pop 腾出的槽位；写到栈顶之上会残留旧值，下拍 pop 到已分配的 preg。
14. PRF 下限 63（工程取 64）：池 = `PRF_SIZE−32`、占住上界 31（x0 只读不写）；更小值在写多目的寄存器程序上死锁。
15. ROB 必须按本批实际 push 数 `n_valid` 预留空位；只查 `!rob_full` 在 W≥2 时会让自由计数器下溢、槽位越界复用。
16. RS push 不得静默丢弃：`push_valid[k]=1` 必须有第 k 个空槽（`rs_free >= ISSUE_WIDTH`），违约时 `pidx[k]` 是无主索引。
17. `free_count` 一律是"当前真空闲数"（不含本拍 clear 腾出的槽）；把本拍选中数也算可用会放行注定被丢的 push。
18. 执行槽选择互斥（同年龄低条目号赢）、两槽不选同一 RS 条目；年龄用 `(tag − rob_head)` 回绕比较；
   load 执行槽的 CDB 标签必须排除（`cdb_slot_valid[g] = sel_valid[g] && !is_load`）。
19. 多误预测取**最老**；walker 中途新误预测只扩展范围（`walk_ptr` 只递减，不重复回滚）；misp 周期必须
   抑制发射（错路批会落在 flush 窗口尾部之外 ⇒ RAT/preg 泄漏）且同拍禁提交（否则重复提交、出重）。
20. `set_last_val = fs + 1`：丢掉误预测分支自己会让 jalr 的 link 丢失、它占的 preg 永不回池。
21. execute_slot 四条不变量见 §7：扣寄存器与放过条目同条件；误预测当拍清空而非冻结；`flush_hit` 逐槽按年龄给。
22. div 收下与放行必须同拍一一对应（每拍恰好一个）；`kill` 只作废在飞那一发（`kill && busy_r`），
   空闲时不得吞掉同拍新 start。
23. 提交需 `cmt_in_win`（槽序号 < ROB 占用量），否则会越过 `last` 外的陈旧槽；提交 store ≤1/批且
   `sw_ready=0` 时整批截断、不产生任何副作用。

**访存 / 存储 / 总线**

24. LSQ 窗口保留 1 槽（占用 ≤ `LSQ_SIZE−1`），`head == last` 唯一表示"空"；`head` 每拍跳过连续死条目。
25. `issued_r` 是完成与请求之间唯一的身份标识：发起即置、完成才清；**在飞条目即使 valid 被清也不算死、
   槽位不可复用**（否则陈旧完成写坏新条目的目的寄存器）。
26. `cand` 必须排除本拍被 kill 的条目；否则 `issued` 与 `valid` 同拍翻转，head 用边沿前的值照样跳过它。
27. load 完成时字节合并覆盖"所有更老已执行的 store"；load 发起的排序条件是"所有更老 store 已执行完"。
28. 提交失效送 LSQ **晚一拍**：load 完成数据在时钟沿前采样而 store 的写与失效落在同一沿 ⇒ 不晚一拍时，
   恰在该拍返回的 load 两条路都丢它（hanoi 式静默算错）。
29. store 队列合并必须按**年龄**遍历（三指针自由回绕，按槽号扫会让最老的 store 赢 = 写反）；D-cache
   的命中路径与填充路径都必须过 SQ 合并（缓存里的旧值不会自己消失）。
30. 填充污染必须中止（污染后回包必被丢弃），只查"安装那一拍"不够 ⇒ 粘滞污染位、行粒度。
31. 探测读口撞拍：填充写 / store 就地更新绝对优先，被偷走的查表读必须显式重放（写周期 `rdata` 不可信）；
   写回下"误判缺失"= 读陈旧内存 ∧ 覆盖脏行 = 静默算错。
32. 对**已驻留行**再起填会静默作废另一路的脏副本（只清 valid/dirty、不写回）⇒ 预取起填前必须查存在性。
33. 写回 + `WR_DEPTH < 8` 时另有两处静默算错：排队填充项被"同拍起填"重新武装（对已驻留行重复填充）、
   等 B 段与排水段共用计数器被新捕获清零（写还在 FIFO 里行就被判空闲）；默认 `WR_DEPTH=8` 不现形。
34. 命中与回包可能撞车 ⇒ 必须保证每拍恰好一个 `ld_done_valid`（`hit_valid` 抢不到就不交 / 重放）。
35. `bready` 恒 1：不驱动 ⇒ 停机 store 的 B 永不握手 ⇒ 每案超时；`arvalid`/`awvalid`/`wvalid` 必须保持到
   ready、地址/数据在握手拍之前不变；一笔 AR 恰好一个 R（丢响应/重发 = 写坏目的寄存器）。
36. 子字访问：`araddr` 强制 4 字节对齐、回包右移后零扩展；不支持跨 4 字节边界的非对齐访问。
37. 自修改代码：I 侧无一致性硬件（ISA 豁免 `FENCE.I`）。

## 11. 代码布局与官方边界

- **目录约定**：`verilog/<域>/<模块>.v`（域 = top/front/core/exec），`tb/<域>/tb_<模块>.v`；模块在域内
  **平铺**，模块名 = 文件名（testbench 模块名 = 文件名）；`verilog/filelist.f` 是 RTL 清单（路径相对
  `verilog/`），**新增/删除源文件必须同步**。
  - `exec/`：adder32, mul, div, alu, branch, execute_slot
  - `front/`：fetch, decode, bht, ras；`top/`：cpu_top, student_top
  - `core/`：rat, free_list, rob, rs, ready_table, prf, lsq, cdb, memory, axi_lite_master, icache, dcache, mem_subsystem
- `core/memory.v` **仅供 TB**（固定 1 拍存储）；`student_top` 不例化它，综合时被 `hierarchy -top` 剪掉。
- **TB 契约**：波形输出 `sim/<域>/tb_<模块>.vcd`；成功打印 `ALL TESTS PASSED` 后 `$finish`，失败打印
  `N TESTS FAILED` 后 `$stop`；一律经 `make -f Makefile.tb run/wave tb=...`（内部 `vvp -N`，失败退出码 1）。
- **官方、勿改**：根 `Makefile`、`config.mk`、`scripts/`、`docs/{axi4-lite,sram}.md`、`testcases/`；本机
  工具链路径写进 gitignore 的 `config.local.mk`（`make CONFIG=config.local.mk <target>`）。参考语义源（C++
  Tomasulo 版）：`/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator`。
