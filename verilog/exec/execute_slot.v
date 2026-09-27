// 执行槽: 每槽一份, **两级流水** (D 级: B3 字段取 | Q 级: B1 操作数获取 + B3 执行 + B4 误预测检测)
// 内部实例化 alu + branch; 由 cpu_top 按 sel_idx 分发, 槽间除 CDB 标签/结果外无互连
// misp 汇出链 (最老优先 = 跨槽拓扑) 在 cpu_top: 本模块只输出 misp_det (=smisp)
// 与 smisp 级 payload (misp_red/misp_fs/misp_ras), cpu_top 侧 1-bit 前缀 OR 链汇出
// 槽 0 的 ret_sample 读口复用由 cpu_top override (rd1_preg mux; 判据是本模块的 sel_valid_q)
// div: 本槽只**发起** (div_start_req + op/a/b/prd/rob_tag); 33 拍后由 div.v 经 CDB 槽 W+1 回来,
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
//   3. 误预测当拍 **清空**寄存器而不是冻结 —— 寄存器里那条就是检出误预测的分支本人
//      (misp_det 是本模块的组合输出), 它本拍已执行完, 正对应原设计里"它的 rs 条目当拍被清"。
//      若改成冻住, misp_det 就由它自己持续产生 ⇒ misp_valid 常 1 ⇒ flushing_r 反复置位,
//      死循环 (**实测踩过**, 见 §15.10.13)。清空与"不放它条目"必须成对, 故 pipe_stall 含 flush_hit。
//   4. 冲刷窗口 (flush_win) 内冻结 D→Q 移交。若让 D 级继续移交, 进来的 div 会因条目已被清
//      而逃过 rs 失效掩码, 等冲刷结束再启动 ⇒ 错路 div 完成时按 rob_tag 置 ready, 而那个
//      tag 早已被新指令复用 ⇒ 真错。
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
    input                          flush_hit,   // cpu_top 的 misp_valid: 本拍检出误预测, 同上
    input                          div_accept,  // 本槽的 div 发起被收下 (cpu_top 的 div_go_w)
    // ---- 操作数 (B1: CDB 旁路 + ready_table→PRF 索引读) ----
    input  [PRF_SIZE - 1 : 0]                 rt_ready,
    input  [31 : 0]                           prf_d1, prf_d2,        // 本槽 PRF 读口
    input  [ISSUE_WIDTH : 0]                  cdb_slot_valid,        // 槽 0..W-1 执行, 槽 W load
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] cdb_tag,
    input  [ISSUE_WIDTH * 32 - 1 : 0]         cdb_exec_result,
    input  [31 : 0]                           load_cdb_result,
    // ---- 输出: 读口地址 / CDB 生产者 / 访存 / 误预测 / BHT / 分支计数 ----
    output                         sel_valid_q, // Q 级有效 (cpu_top 的 ret_sample 读口判据)
    output                         pipe_stall,  // Q 级冻结 ⇒ cpu_top 必须同时放过 rs_clear
    output [$clog2(PRF_SIZE) - 1 : 0]         rd1_preg, rd2_preg,
    output                                    exec_valid,
    output [$clog2(PRF_SIZE) - 1 : 0]         exec_prd,
    output [31 : 0]                           exec_result,
    output [$clog2(ROB_SIZE) - 1 : 0]         exec_rob_tag,
    // ---- 输出: 多周期除法发起 (结果不经本槽 ALU, 由 div.v 33 拍后经 CDB 槽 W+1 回) ----
    output                                    div_start_req,
    output [1 : 0]                            div_op,
    output [31 : 0]                           div_a, div_b,
    output [$clog2(PRF_SIZE) - 1 : 0]         div_prd,
    output [$clog2(ROB_SIZE) - 1 : 0]         div_rob_tag,
    output                                    set_addr_req, set_data_req,
    output [$clog2(LSQ_SIZE) - 1 : 0]         set_addr_idx, set_data_idx,
    output [31 : 0]                           set_addr_val, set_data_val,
    output                                    misp_det,
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
    //   flush_hit ⇒ **清空**: 寄存器里那条就是检出误预测的分支本人, 它本拍已执行完 (结果/重定向
    //     都已组合汇出), 原设计里它的 rs 条目也正是这拍被清的 —— 所以这里对应"消费掉"。
    //     若改成冻住, misp_det 就由它自己产生 ⇒ misp_valid 常 1 ⇒ flushing_r 反复置位, 死循环。
    //   q_freeze  ⇒ 冻结: 冲刷窗口 (不放新指令进来) 或 div 没被收下 (本条还没被任何单元接走)。
    assign sel_valid_q = sel_valid_q_r;
    wire q_freeze;      // 赋值在译码之后 (依赖 is_div); iverilog 要求先声明后用
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_all_q     <= {TOTW{1'b0}};
            sel_valid_q_r <= 1'b0;
        end else if (flush_hit) begin
            sel_all_q     <= {TOTW{1'b0}};
            sel_valid_q_r <= 1'b0;
        end else if (!q_freeze) begin
            sel_all_q     <= sel_all_w;
            sel_valid_q_r <= sel_valid;
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
    // 注: prs==0 短路 0; 旁路优先; 否则 ready_table 命中读 PRF (索引读)
    wire [31 : 0] op1 = (prs1 == 0) ? 32'd0 : (m1_any ? byp1 : (rt_ready[prs1] ? prf_d1 : 32'd0));
    wire [31 : 0] op2 = (prs2 == 0) ? 32'd0 : (m2_any ? byp2 : (rt_ready[prs2] ? prf_d2 : 32'd0));
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

    // ---- CDB 生产者 (load 槽排除: 其 prd 是"地址", 依赖者不得匹配;
    //      div 同样排除: 多周期, 其完成走 CDB 槽 W+1, 本拍广播的 alu_result 是无意义的占位) ----
    assign exec_valid   = sel_valid_q_r && !is_load && !is_div;
    assign exec_prd     = prd;
    assign exec_result  = is_ctrl ? br_link : alu_result;
    assign exec_rob_tag = rob_tag;

    // ---- 除法发起: 仅"选中且非忙"时才真正被 div.v 收下 (cpu_top 侧门控) ----
    assign div_start_req = sel_valid_q_r && is_div;
    assign div_op        = func3[1 : 0];      // 0=div 1=divu 2=rem 3=remu
    assign div_a         = op1;
    assign div_b         = op2;
    assign div_prd       = prd;
    assign div_rob_tag   = rob_tag;

    // ---- 访存: 地址 = alu 结果, store 数据 = rs2 ----
    assign set_addr_req = sel_valid_q_r && is_mem;
    assign set_addr_idx = lsq_tag;
    assign set_addr_val = alu_result;
    assign set_data_req = sel_valid_q_r && is_store;
    assign set_data_idx = lsq_tag;
    assign set_data_val = op2;

    // ---- B4 误预测检测 (汇出链在 cpu_top) ----
    assign misp_det = sel_valid_q_r && ((is_branch && (br_taken != pred_taken))
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
