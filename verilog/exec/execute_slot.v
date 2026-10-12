// 执行槽: 每槽一份, **三级流水** (D 级: B3 字段取 | Q 级: B1 操作数获取 + B3 执行 + B4 误预测检测
//                                       | W 级: 消费者侧产物登记)
// 内部实例化 alu + branch; 由 cpu_top 按 sel_idx 分发, 槽间除 CDB 标签/结果外无互连
// misp 汇出链 (最老优先 = 跨槽拓扑) 在 cpu_top: 本模块只输出 misp_det (=smisp)
// 与 smisp 级 payload (misp_red/misp_fs/misp_ras), cpu_top 侧 1-bit 前缀 OR 链汇出
// 槽 0 的 ret_sample 读口复用由 cpu_top override (rd1_preg mux; 判据是本模块的 sel_valid_q)
// div: 本槽只**发起** (div_start_req + op/a/b/prd/rob_tag); 34 拍后由 div.v 经 CDB 槽 W+1 回来,
//      故 exec_valid 对它置 0 —— 否则会立刻广播一个垃圾 alu_result 并把 ROB 置就绪
//
// ---- 流水切点与三条不变量 (§15.10.13) ----
// 切在 `sel_all_w` 之后: D 级 = 仲裁结果 sel_idx → one-hot → 144 位 AND-OR 字段取;
// Q 级 = PRF 读口索引 → 旁路 → alu/branch → CDB。切开的收益来自**摆率在寄存器处归零**
// (官方 abc 无 -constr ⇒ 不插 buffer, 摆率沿组合路径单调恶化, 见 tools/README.md §诊断),
// 而不仅仅是级数减半。寄存器只 144+1 位 (≈ 80 µm², 0.7% 面积)。
//   1. **RS 条目在入选那拍就被清** (cpu_top 的 rs_clear_valid), 所以 D→Q 必须同一拍完成移交:
//      凡是要"扣住"的情形都只能扣**流水寄存器**, 扣 RS 条目已经晚了 (条目当拍就没了)。
//   2. 因此"扣寄存器"(`q_freeze`) 与"放过条目"(`pipe_stall` 门控 rs_clear) 必须同条件,
//      否则会出现"条目被清但没进寄存器"(指令丢失) 或"没清却进了寄存器"(重复执行)。
//      唯一的例外是 flush_hit, 见第 3 条。
//   3. 误预测当拍 **清空**寄存器而不是冻结 —— 被清的那条 (检出误预测的分支本人) 本拍已执行完
//      (结果/重定向组合汇出, W 级照常装载), 正对应原设计里"它的 rs 条目当拍被清"。
//      若改成冻住, misp_det 就由它自己持续产生 ⇒ misp_valid 常 1 ⇒ flushing_r 反复置位,
//      死循环 (**实测踩过**, 见 §15.10.13)。清空与"不放它条目"必须成对, 故 pipe_stall 含 flush_hit。
//      ★ W>=2 **不能**用全局 misp_valid 清所有槽: 冻结的槽 (div 没被收下) 会一直握着它入选
//        那拍的那条, 另一槽却已前进若干条 ⇒ 两槽 Q **不再是年龄序**, 冻住的那条可能**比误预测
//        分支更老** (= 正确路, 必须提交且 rs 条目在入选那拍已清 ⇒ Q 是唯一副本) ⇒ 清了就是
//        指令丢失, 它的 ROB 条目永不就绪 ⇒ 提交停摆 ⇒ free_list 漏干 ⇒ 全机死锁。
//        实测 basicopt1 W=2: 槽 1 自 cycle 41950 冻住 tag 17(rem, 除法器忙), 槽 0 前进到 tag 24
//        的分支并于 41972 误预测 (head=8, fs=24) ⇒ 广播清空把 17 一并销毁 ⇒ 挂死。
//        ⇒ flush_hit 由 cpu_top **逐槽**给出, 口径与 rs/lsq 失效掩码、div_kill 一致 (见其注释)。
//   4. 冲刷窗口 (flush_win) 内冻结 D→Q 移交。若让 D 级继续移交, 进来的 div 会因条目已被清
//      而逃过 rs 失效掩码, 等冲刷结束再启动 ⇒ 错路 div 完成时按 rob_tag 置 ready, 而那个
//      tag 早已被新指令复用 ⇒ 真错。
//
// ---- 手法 4: Q/W 切点 (§15.10.14) ----
// 切在**消费者侧产物**上: Q 级组合算出的 exec_valid/exec_prd/exec_result/exec_rob_tag 与
// set_addr_req/idx/val、set_data_req/idx/val → W 级寄存器 (114 位) 输出。
// 依据: 实测 99 级里第 91 级之后那 5.4 ns 全在**写口广播网**上 —— CDB → prf 2048 个 flop 的
// 一位热译码 + AND 链、LSQ addr_r/data_r 512 个 flop 同理。它不需要更短的逻辑, 只需要一个
// 寄存器输出让它从零重新起算 (官方 abc 无 -constr, 摆率只在寄存器处归零)。
// 与 D/Q 切点的区别: 这里**不切控制**, misp_det / div 发起 / BHT 更新 / pipe_stall 全部留在
// Q 级原样不动 —— 它们的载荷与误预测汇出链、rs_clear 门控耦合, 挪动会改冲刷时序。
// W 级是**一次性脉冲**: 只在 Q 前进那一拍装载; 冻结那拍把三个 strobe 清 0 —— 若照 Q 级那样
// 冻住保持, 同一条结果会在 CDB 上重复广播, 而它可能早已提交 (prd 被 free_list 回收后重新
// 分配) ⇒ 把陈旧值写进新目的寄存器。装载的那一份在**下一拍**被 CDB/LSQ 消费 (消费者都在
// 那个 posedge 采样), 所以"冻结拍清 0"不会丢任何一次写。
// W 里那条指令**永远比 Q 里那条更老** ⇒ 不会被冲刷: misp 当拍 Q 被清而 W 照常装载 (误预测
// 分支本人就在 Q 里, 它的 link 必须广播出去, 且它的 rs 条目当拍被清 = 原设计的"消费掉"),
// 故 W 不需要任何 flush 相关的新逻辑。唯一要守的是装载条件必须与 Q 前进条件**同一个**
// (q_freeze), 否则会出现"Q 没动而 W 重复装载同一条"(重复广播)。
module execute_slot #(
    parameter ISSUE_WIDTH = 1,
    parameter RS_SIZE     = 16,
    parameter PRF_SIZE    = 64,
    parameter LSQ_SIZE    = 16,
    parameter ROB_SIZE    = 32,
    parameter RAS_SIZE    = 8,
    parameter BHT_SIZE    = 32,
    parameter SLOT_ID     = 0     // 本槽编号 (旁路排除自己: prs==prd 时自旁路是组合环)
) (
    input                          clk, rst_n,
    // ---- D 级: 选择与条目 (B3 字段取) ----
    input                          sel_valid,
    input  [$clog2(RS_SIZE) - 1 : 0]          sel_idx,
    input  [RS_SIZE * 7 - 1 : 0]              rs_entry_opcode, rs_entry_func7,
    input  [RS_SIZE * 3 - 1 : 0]              rs_entry_func3,
    input  [RS_SIZE * $clog2(PRF_SIZE) - 1 : 0] rs_entry_prs1, rs_entry_prs2, rs_entry_prd,
    input  [RS_SIZE * 32 - 1 : 0]             rs_entry_pc, rs_entry_imm, rs_entry_pred_target,
    input  [RS_SIZE * $clog2(LSQ_SIZE) - 1 : 0] rs_entry_lsq_tag,
    input  [RS_SIZE * $clog2(ROB_SIZE) - 1 : 0] rs_entry_rob_tag,
    input  [RS_SIZE - 1 : 0]                  rs_entry_pred_taken,
    input  [RS_SIZE * $clog2(RAS_SIZE) - 1 : 0] rs_entry_ras_snap,
    // ---- Q 级流水控制 ----
    input                          flush_win,   // cpu_top 的 flushing_r: 冲刷窗口, Q 级冻结
    input                          flush_hit,   // 本槽 Q 级本条该被误预测销毁 (cpu_top **逐槽按年龄**算,
                                                 // 不是全局 misp_valid —— 理由见文件头不变量 3)
    input                          div_accept,  // 本槽的 div 发起被收下 (cpu_top 的 div_go_w)
    // ---- 操作数 (B1: CDB 旁路 + PRF 索引读) ----
    input  [31 : 0]                           prf_d1, prf_d2,        // 本槽 PRF 读口
    input  [ISSUE_WIDTH : 0]                  cdb_slot_valid,        // 槽 0..W-1 执行, 槽 W load
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] cdb_tag,
    input  [ISSUE_WIDTH * 32 - 1 : 0]         cdb_exec_result,
    input  [31 : 0]                           load_cdb_result,
    // ---- 输出: 读口地址 / CDB 生产者 / 访存 / 误预测 / BHT / 分支计数 ----
    output                         sel_valid_q, // Q 级有效 (cpu_top 的 ret_sample 读口判据)
    output                         pipe_stall,  // Q 级冻结 ⇒ cpu_top 必须同时放过 rs_clear
    output                         q_freeze,    // Q 级被扣住 (cpu_top 逐槽算 flush_hit 用)
    output [$clog2(ROB_SIZE) - 1 : 0] q_rob_tag, // Q 级条目的 rob_tag (同上, 年龄判据)
    output [$clog2(PRF_SIZE) - 1 : 0]         rd1_preg, rd2_preg,
    output                                    exec_valid,
    output [$clog2(PRF_SIZE) - 1 : 0]         exec_prd,
    output [31 : 0]                           exec_result,
    output [$clog2(ROB_SIZE) - 1 : 0]         exec_rob_tag,
    // ---- 输出: 多周期除法发起 (结果不经本槽 ALU, 由 div.v 34 拍后经 CDB 槽 W+1 回) ----
    output                                    div_start_req,
    output [1 : 0]                            div_op,
    output [31 : 0]                           div_a, div_b,
    output [$clog2(PRF_SIZE) - 1 : 0]         div_prd,
    output [$clog2(ROB_SIZE) - 1 : 0]         div_rob_tag,
    output                                    set_addr_req, set_data_req,
    output [$clog2(LSQ_SIZE) - 1 : 0]         set_addr_idx, set_data_idx,
    output [31 : 0]                           set_addr_val, set_data_val,
    output                                    misp_det,
    output                                    misp_det_b,  // 判决的**第二副本** (供上半机负载劈半; 值恒等)
    output [31 : 0]                           misp_red,
    output [$clog2(ROB_SIZE) - 1 : 0]         misp_fs,
    output [$clog2(RAS_SIZE) - 1 : 0]         misp_ras,
    output                                    br_inc,
    output                                    upd_req, upd_taken,
    output [$clog2(BHT_SIZE) - 1 : 0]         upd_idx
);
    localparam SRW = $clog2(RS_SIZE);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam RA  = $clog2(RAS_SIZE);
    localparam BW  = $clog2(BHT_SIZE);

    // ---- B3 字段取: **one-hot + AND-OR** (原为 `rs_entry_xxx[sel_idx * W +: W]`) ----
    // 直接写数组索引读会综合出 N 选 1 的 mux 树, 索引**最低位落在最宽的一级**:
    // 扇出 = (N/2) × 位宽 = 8 × 144 = 1152 (实测 1152)。而官方综合流程的 abc 没带
    // `-constr` ⇒ 不做 buffer/upsize (§15.10.8), 于是那一级实测 6.2 ns。
    // 改成先把索引译成 one-hot 再对每一位做 AND-OR: sel_oh[ge] 只驱动条目 ge 的
    // 位宽个门 (144), 峰值扇出 1152 → 144 (8 倍); 面积基本持平
    // (mux ≈ 2 门, AND2 + OR2 ≈ 2 门)。
    // 注: 144 是**不做译码器复制**时的下界 —— 复制会被 opt_merge 合并回去
    // (实测: 同一个 `sel_idx == ge` 写三遍会被并成一条网), 故这里不做无谓的复制。
    localparam TOTW = 7 + 3 + 7 + 3 * PW + 64 + LW + RW + 1 + 32 + RA;   // 13 个字段合计位宽
    // 各字段在打包总线里的起始位 (逐行累加, 行尾注释即该字段宽度; 与下面拼接顺序一一对应)
    localparam O_RAS  = 0;                          // : RA
    localparam O_PTGT = O_RAS  + RA;                // : 32
    localparam O_PTAK = O_PTGT + 32;                // : 1
    localparam O_RTAG = O_PTAK + 1;                 // : RW
    localparam O_LTAG = O_RTAG + RW;                // : LW
    localparam O_IMM  = O_LTAG + LW;                // : 32
    localparam O_PC   = O_IMM  + 32;                // : 32
    localparam O_PRD  = O_PC   + 32;                // : PW
    localparam O_PRS2 = O_PRD  + PW;                // : PW
    localparam O_PRS1 = O_PRS2 + PW;                // : PW
    localparam O_F7   = O_PRS1 + PW;                // : 7
    localparam O_F3   = O_F7   + 7;                 // : 3
    localparam O_OPC  = O_F3   + 3;                 // : 7

    wire [RS_SIZE - 1 : 0] sel_oh;
    wire [RS_SIZE * TOTW - 1 : 0] ent_all;
    wire [TOTW - 1 : 0] sel_all_w;      // D 级输出 (AND-OR 归约结果)
    reg  [TOTW - 1 : 0] sel_all_q;      // Q 级寄存器: 选中条目的全部字段
    reg                 sel_valid_q_r;  // Q 级寄存器: 有效位
    // ★ 源触发器的**副本** (值恒等于 sel_valid_q_r): 劈扇出负载用。
    //   官方 ABC 不带 `-constr` ⇒ 不插缓冲/不做驱动强度优化, 于是判决广播网由一颗 X1 门驮着
    //   上百个负载 (实测 `_088848_` 58.93 fF / 143 脚, 单级 572 ps)。劈法只能从**源触发器**下手:
    //   组合网复制会被 `&fraig` 的 SAT 等价类并掉, 而两颗触发器是**两个不同的 PI** ⇒ 等价性不成立。
    //   副本的 enable **必须引用自己的 Q** (q_freeze_b), 否则 `opt_merge`("同类型 + 输入信号完全相同")
    //   会把它并回原寄存器 —— 实测: 无自反馈的复制 16→8 颗, 有自反馈 16 颗全存活 (玩具电路 + 官方脚本)。
    reg                 sel_valid_q_r_b;
    wire                q_freeze_b;     // 副本的冻结条件 (与 q_freeze 同式, 但吃自己的 Q —— 见上)
    genvar gd, gb, ge;
    generate
        // 索引 → one-hot (16 条, 每条只驱动一个条目的位宽)
        for (gd = 0; gd < RS_SIZE; gd = gd + 1) begin : dec
            assign sel_oh[gd] = (sel_idx == gd[SRW - 1 : 0]);
        end
        // 13 个字段按条目重排成 [ge][TOTW], 顺序与上面的 O_* 偏移一一对应
        for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : pack
            assign ent_all[ge * TOTW +: TOTW] = {
                rs_entry_opcode[ge * 7 +: 7], rs_entry_func3[ge * 3 +: 3], rs_entry_func7[ge * 7 +: 7],
                rs_entry_prs1[ge * PW +: PW], rs_entry_prs2[ge * PW +: PW], rs_entry_prd[ge * PW +: PW],
                rs_entry_pc[ge * 32 +: 32], rs_entry_imm[ge * 32 +: 32],
                rs_entry_lsq_tag[ge * LW +: LW], rs_entry_rob_tag[ge * RW +: RW],
                rs_entry_pred_taken[ge], rs_entry_pred_target[ge * 32 +: 32],
                rs_entry_ras_snap[ge * RA +: RA] };
        end
        // 逐位 AND-OR 归约 (一条 generate 覆盖全部 144 位)
        for (gb = 0; gb < TOTW; gb = gb + 1) begin : red
            wire [RS_SIZE - 1 : 0] m;
            for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : e
                assign m[ge] = ent_all[ge * TOTW + gb] & sel_oh[ge];
            end
            assign sel_all_w[gb] = |m;
        end
    endgenerate

    // ---- D/Q 流水寄存器 ----
    // freeze 与 clear 是两回事, 条件也不一样 (依赖 is_div, 故 q_freeze 定义在译码之后):
    //   flush_hit ⇒ **清空**: 本条是检出误预测的分支本人 (或错路), 它本拍已执行完 (结果/重定向
    //     都已组合汇出), 原设计里它的 rs 条目也正是这拍被清的 —— 所以这里对应"消费掉"。
    //     若改成冻住, misp_det 就由它自己产生 ⇒ misp_valid 常 1 ⇒ flushing_r 反复置位, 死循环。
    //     ★ W>=2 由 cpu_top 逐槽判定 (年龄 >= 冲刷点), 不再收全局 misp_valid —— 理由见文件头 3。
    //   q_freeze  ⇒ 冻结: 冲刷窗口 (不放新指令进来) 或 div 没被收下 (本条还没被任何单元接走)。
    assign sel_valid_q = sel_valid_q_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_all_q       <= {TOTW{1'b0}};
            sel_valid_q_r   <= 1'b0;
            sel_valid_q_r_b <= 1'b0;
        end else if (flush_hit) begin
            sel_all_q       <= {TOTW{1'b0}};
            sel_valid_q_r   <= 1'b0;
            sel_valid_q_r_b <= 1'b0;
        end else begin
            if (!q_freeze)   sel_valid_q_r   <= sel_valid;
            if (!q_freeze_b) sel_valid_q_r_b <= sel_valid;
            if (!q_freeze)   sel_all_q       <= sel_all_w;
        end
    end

    wire [6 : 0]      opcode      = sel_all_q[O_OPC  +: 7];
    wire [2 : 0]      func3       = sel_all_q[O_F3   +: 3];
    wire [6 : 0]      func7       = sel_all_q[O_F7   +: 7];
    wire [PW - 1 : 0] prs1        = sel_all_q[O_PRS1 +: PW];
    wire [PW - 1 : 0] prs2        = sel_all_q[O_PRS2 +: PW];
    wire [PW - 1 : 0] prd         = sel_all_q[O_PRD  +: PW];
    wire [31 : 0]     pc          = sel_all_q[O_PC   +: 32];
    wire [31 : 0]     imm         = sel_all_q[O_IMM  +: 32];
    wire [LW - 1 : 0] lsq_tag     = sel_all_q[O_LTAG +: LW];
    wire [RW - 1 : 0] rob_tag     = sel_all_q[O_RTAG +: RW];
    wire              pred_taken  = sel_all_q[O_PTAK];
    wire [31 : 0]     pred_target = sel_all_q[O_PTGT +: 32];
    wire [RA - 1 : 0] ras_snap    = sel_all_q[O_RAS  +: RA];

    // Q 级条目的 rob_tag (端口; cpu_top 逐槽算 flush_hit 的年龄判据)
    // ★ 必须写在 rob_tag 的声明**之后**: Icarus 拒绝"先用后声明"(implicit net), Verilator 容忍 ——
    //   放在上面会让 make -f Makefile.tb 整条 TB 流程编译不过 (与 W 无关)。
    assign q_rob_tag = rob_tag;

    wire is_r      = (opcode == 7'h33);
    wire is_i      = (opcode == 7'h13);
    wire is_lui    = (opcode == 7'h37);
    wire is_auipc  = (opcode == 7'h17);
    wire is_load   = (opcode == 7'h03);
    wire is_store  = (opcode == 7'h23);
    wire is_branch = (opcode == 7'h63);
    wire is_jal    = (opcode == 7'h6F);
    wire is_jalr   = (opcode == 7'h67);
    // M 扩展: f7=0000001 且 f3[2]=0 → mul*, f3[2]=1 → div/rem (见 decode 的 mul/div_f3_ok)
    wire is_mul    = is_r && (func7 == 7'h01) && (func3 <  3'd4);
    wire is_div    = is_r && (func7 == 7'h01) && (func3 >= 3'd4);
    wire is_ctrl   = is_branch || is_jal || is_jalr;
    wire is_mem    = is_load || is_store;

    // ---- Q 级冻结 / 扣住 rs 条目 (见文件头不变量 1/2) ----
    // q_freeze 的两个成因: 冲刷窗口 (不放新指令进执行级, 否则它会逃过 rs 失效掩码) 与
    // div 没被收下 (条目在入选那拍已清 ⇒ 只能扣寄存器; 不扣就丢掉这一发 ⇒ 永不执行)。
    assign q_freeze   = flush_win || (sel_valid_q_r && is_div && !div_accept);
    assign q_freeze_b = flush_win || (sel_valid_q_r_b && is_div && !div_accept);
    //   (端口 q_freeze/q_rob_tag 的声明在端口表; 赋值只能在这里 —— 依赖 is_div 与 rob_tag)
    // pipe_stall 是给 cpu_top 用的 **rs_clear 放过条件**, 比 q_freeze 多一个 flush_hit:
    // 误预测当拍 D 级选中的那条本拍**没有**进执行级 (寄存器被清), 所以它的条目绝不能清 ——
    // 它可能比误预测分支更老 (仲裁选的是最老**就绪**项, 一条当拍才被 CDB 唤醒的可以更老),
    // 那就并未被冲刷, 清了就是指令丢失 ⇒ 死锁; 也可能更年轻 ⇒ 交给 rs 失效掩码收拾。
    // 留着条目对两种情况都成立。
    assign pipe_stall = q_freeze || flush_hit;

    // ---- B1 操作数获取 (CDB 旁路链, 槽内局部: 遍历 j∈[0..W], 槽 W = load 完成) ----
    // 排除自己 (j == SLOT_ID): 自广播的 prd==prs 时 op 组合依赖自己的结果 = 组合环
    wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] byp1_acc, byp2_acc, byp1_c, byp2_c;
    wire [ISSUE_WIDTH : 0]                m1, m2;
    wire m1_any = |m1, m2_any = |m2;
    genvar j;
    generate
        for (j = 0; j <= ISSUE_WIDTH; j = j + 1) begin : byp
            wire res1 = (j != SLOT_ID) && cdb_slot_valid[j] && (cdb_tag[j * PW +: PW] == prs1);
            wire res2 = (j != SLOT_ID) && cdb_slot_valid[j] && (cdb_tag[j * PW +: PW] == prs2);
            wire [31 : 0] resv = (j < ISSUE_WIDTH) ? cdb_exec_result[j * 32 +: 32] : load_cdb_result;
            assign m1[j] = res1;
            assign m2[j] = res2;
            assign byp1_acc[j * 32 +: 32] = res1 ? resv : 32'd0;
            assign byp2_acc[j * 32 +: 32] = res2 ? resv : 32'd0;
            if (j == 0) begin : b0
                assign byp1_c[0 * 32 +: 32] = byp1_acc[0 * 32 +: 32];
                assign byp2_c[0 * 32 +: 32] = byp2_acc[0 * 32 +: 32];
            end else begin : bn
                assign byp1_c[j * 32 +: 32] = byp1_c[(j - 1) * 32 +: 32] | byp1_acc[j * 32 +: 32];
                assign byp2_c[j * 32 +: 32] = byp2_c[(j - 1) * 32 +: 32] | byp2_acc[j * 32 +: 32];
            end
        end
    endgenerate
    wire [31 : 0] byp1 = byp1_c[ISSUE_WIDTH * 32 +: 32];
    wire [31 : 0] byp2 = byp2_c[ISSUE_WIDTH * 32 +: 32];
    // 注: prs==0 短路 0; 旁路优先; 否则直接读 PRF —— **rt_ready 掩码已净删** (2026-10-11)
    //   理由: rs.v 的就绪判据是入选的**必要条件** (ready_e_w = prs==0 || CDB 命中 || rt_ready),
    //   故选中条目若 prs!=0 且无 CDB 命中 ⇒ 入选那一刻 rt_ready[prs] 必为 1; 而 prs 的产出者
    //   要到**本条退休**才被释放重分配 ⇒ rt_ready[prs] 在此前恒 1, 掩码是恒通门。
    //   若掩码原本要挡的"未写过 preg 的 X"真的发生, 它会直接可见于 make test (不静默算错值)。
    wire [31 : 0] op1 = (prs1 == 0) ? 32'd0 : (m1_any ? byp1 : prf_d1);
    wire [31 : 0] op2 = (prs2 == 0) ? 32'd0 : (m2_any ? byp2 : prf_d2);
    assign rd1_preg = prs1;
    assign rd2_preg = prs2;

    // ---- B3 执行: alu + branch (全组合 1 周期) ----
    wire [31 : 0] alu_a = is_lui ? 32'd0 : (is_auipc ? pc : op1);
    wire [31 : 0] alu_b = (is_lui || is_auipc || is_i || is_mem) ? imm : op2;
    // alu op 编码: 0=add 1=sub 2=sll 3=slt 4=sltu 5=xor 6=srl 7=sra 8=or 9=and 10..13=mul*
    //              14..17 = div/divu/rem/remu 占位 (结果被 exec_valid=0 屏蔽, 只为不落 default)
    wire [4 : 0] alu_op = is_r ? (is_mul
 ? (func3 == 3'd0 ? 5'd10 : func3 == 3'd1 ? 5'd11
 : func3 == 3'd2 ? 5'd12 : 5'd13)
 : is_div ? (5'd14 + {3'd0, func3[1 : 0]})
 : (func3 == 3'd0 ? (func7[5] ? 5'd1 : 5'd0)
 : func3 == 3'd1 ? 5'd2 : func3 == 3'd2 ? 5'd3
 : func3 == 3'd3 ? 5'd4 : func3 == 3'd4 ? 5'd5
 : func3 == 3'd5 ? (func7[5] ? 5'd7 : 5'd6)
 : func3 == 3'd6 ? 5'd8 : 5'd9))
 : is_i ? (func3 == 3'd0 ? 5'd0 : func3 == 3'd1 ? 5'd2
 : func3 == 3'd2 ? 5'd3 : func3 == 3'd3 ? 5'd4
 : func3 == 3'd4 ? 5'd5 : func3 == 3'd5 ? (func7[5] ? 5'd7 : 5'd6)
 : func3 == 3'd6 ? 5'd8 : 5'd9)
 : 5'd0;   // lui/auipc/load/store/NOP → add
    wire [31 : 0] alu_result;
    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .result(alu_result));
    wire [1 : 0]  br_mode = is_jal ? 2'd1 : (is_jalr ? 2'd2 : 2'd0);
    wire br_taken;
    wire [31 : 0] br_link, br_target;
    branch u_br (.rs1(op1), .rs2(op2), .pc(pc), .imm(imm),
                 .mode(br_mode), .br_op(func3), .taken(br_taken),
                 .target(br_target), .link(br_link));

    // ---- 消费者侧产物 (Q 级组合 → W 级寄存器, 手法 4 见文件头) ----
    // CDB 生产者 (load 槽排除: 其 prd 是"地址", 依赖者不得匹配;
    //      div 同样排除: 多周期, 其完成走 CDB 槽 W+1, 本拍广播的 alu_result 是无意义的占位);
    // 访存: 地址 = alu 结果, store 数据 = rs2
    wire         w_valid_in    = sel_valid_q_r && !is_load && !is_div;
    wire [31 : 0] w_result_in  = is_ctrl ? br_link : alu_result;
    wire         w_addr_req_in = sel_valid_q_r && is_mem;
    wire         w_data_req_in = sel_valid_q_r && is_store;
    reg          w_valid_r, w_addr_req_r, w_data_req_r;
    reg [PW - 1 : 0] w_prd_r;
    reg [RW - 1 : 0] w_rob_tag_r;
    reg [LW - 1 : 0] w_lsq_tag_r;
    reg [31 : 0]     w_result_r, w_addr_val_r, w_data_val_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_valid_r    <= 1'b0;
            w_addr_req_r <= 1'b0;
            w_data_req_r <= 1'b0;
            w_prd_r      <= {PW{1'b0}};
            w_result_r   <= 32'd0;
            w_rob_tag_r  <= {RW{1'b0}};
            w_lsq_tag_r  <= {LW{1'b0}};
            w_addr_val_r <= 32'd0;
            w_data_val_r <= 32'd0;
        end else if (!q_freeze) begin
            // 只在 Q 前进那拍装载 (与 Q 前进同条件, 否则同一条会被重复装载/重复广播)
            w_valid_r    <= w_valid_in;
            w_prd_r      <= prd;
            w_result_r   <= w_result_in;
            w_rob_tag_r  <= rob_tag;
            w_addr_req_r <= w_addr_req_in;
            w_data_req_r <= w_data_req_in;
            w_lsq_tag_r  <= lsq_tag;
            w_addr_val_r <= alu_result;
            w_data_val_r <= op2;
        end else begin
            // 冻结: 载荷无需清 (只由 strobe 门控), 但三个脉冲位必须清
            // (上一拍已广播过 ⇒ 再广播一次就可能落进被回收重分配的目的寄存器)
            w_valid_r    <= 1'b0;
            w_addr_req_r <= 1'b0;
            w_data_req_r <= 1'b0;
        end
    end
    assign exec_valid   = w_valid_r;
    assign exec_prd     = w_prd_r;
    assign exec_result  = w_result_r;
    assign exec_rob_tag = w_rob_tag_r;
    assign set_addr_req = w_addr_req_r;
    assign set_addr_idx = w_lsq_tag_r;
    assign set_addr_val = w_addr_val_r;
    assign set_data_req = w_data_req_r;
    assign set_data_idx = w_lsq_tag_r;
    assign set_data_val = w_data_val_r;

    // ---- 除法发起: 仅"选中且非忙"时才真正被 div.v 收下 (cpu_top 侧门控) ----
    assign div_start_req = sel_valid_q_r && is_div;
    assign div_op        = func3[1 : 0];      // 0=div 1=divu 2=rem 3=remu
    assign div_a         = op1;
    assign div_b         = op2;
    assign div_prd       = prd;
    assign div_rob_tag   = rob_tag;

    // ---- B4 误预测检测 (汇出链在 cpu_top) ----
    assign misp_det = sel_valid_q_r && ((is_branch && (br_taken != pred_taken))
                                     || (is_jalr && (br_target != pred_target)));
    // 第二副本: 只换源触发器, **比较链共用** (它不依赖 sel_valid, 本来就不该被复制)
    assign misp_det_b = sel_valid_q_r_b && ((is_branch && (br_taken != pred_taken))
                                         || (is_jalr && (br_target != pred_target)));
    assign misp_red = misp_det ? br_target : 32'd0;
    assign misp_fs  = misp_det ? rob_tag  : {RW{1'b0}};
    assign misp_ras = misp_det ? ras_snap : {RA{1'b0}};

    // ---- BHT 更新 (仅条件分支, 实际方向) / 分支计数 ----
    // `!flush_win`: 冲刷窗口内 Q 级冻结, 寄存器里那条 (误预测分支本人) 会**连续多拍**重复求值。
    // 不门控的话 BHT 会被同一条分支反复训练 (方向虽同, 2 位计数器会被推到饱和) 且分支计数虚高;
    // 门控后恰好只在它执行的那一拍更新一次, 与原单周期行为逐拍一致。
    // 注意只能用 flush_win (寄存器量), 不能用 flush_hit: misp_valid ← misp_det 是本模块的
    // 组合输出, 若用它门控这几个输出就会形成 misp_det → misp_valid → 本信号的组合环。
    assign upd_req   = sel_valid_q_r && is_branch && !flush_win;
    assign upd_idx   = (pc >> 2) % BHT_SIZE;
    assign upd_taken = br_taken;
    assign br_inc    = sel_valid_q_r && is_branch && !flush_win;
endmodule
