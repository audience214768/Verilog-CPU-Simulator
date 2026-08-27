// 执行槽: 每槽一份的纯组合逻辑 (B1 操作数获取 + B3 执行分发 + B4 误预测检测)
// 内部实例化 alu + branch; 由 cpu_top 按 sel_idx 分发, 槽间除 CDB 标签/结果外无互连
// misp 汇出链 (最老优先 = 跨槽拓扑) 在 cpu_top: 本模块只输出 misp_det (=smisp)
// 与 smisp 级 payload (misp_red/misp_fs/misp_ras), cpu_top 侧 1-bit 前缀 OR 链汇出
// 槽 0 的 ret_sample 读口复用由 cpu_top override (rd1_preg mux)
module execute_slot #(
    parameter ISSUE_WIDTH = 1,
    parameter RS_SIZE     = 16,
    parameter PRF_SIZE    = 64,
    parameter LSQ_SIZE    = 16,
    parameter ROB_SIZE    = 32,
    parameter RAS_SIZE    = 8,
    parameter BHT_SIZE    = 32
) (
    // ---- 选择与条目 (B3 字段取) ----
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
    // ---- 操作数 (B1: CDB 旁路 + ready_table→PRF 索引读) ----
    input  [PRF_SIZE - 1 : 0]                 rt_ready,
    input  [31 : 0]                           prf_d1, prf_d2,        // 本槽 PRF 读口
    input  [ISSUE_WIDTH : 0]                  cdb_slot_valid,        // 槽 0..W-1 执行, 槽 W load
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] cdb_tag,
    input  [ISSUE_WIDTH * 32 - 1 : 0]         cdb_exec_result,
    input  [31 : 0]                           load_cdb_result,
    // ---- 输出: 读口地址 / CDB 生产者 / 访存 / 误预测 / BHT / 分支计数 ----
    output [$clog2(PRF_SIZE) - 1 : 0]         rd1_preg, rd2_preg,
    output                                    exec_valid,
    output [$clog2(PRF_SIZE) - 1 : 0]         exec_prd,
    output [31 : 0]                           exec_result,
    output [$clog2(ROB_SIZE) - 1 : 0]         exec_rob_tag,
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

    // ---- B3 字段取 (按 sel_idx 位段) ----
    wire [6 : 0]      opcode   = rs_entry_opcode[sel_idx * 7 +: 7];
    wire [2 : 0]      func3    = rs_entry_func3[sel_idx * 3 +: 3];
    wire [6 : 0]      func7    = rs_entry_func7[sel_idx * 7 +: 7];
    wire [PW - 1 : 0] prs1     = rs_entry_prs1[sel_idx * PW +: PW];
    wire [PW - 1 : 0] prs2     = rs_entry_prs2[sel_idx * PW +: PW];
    wire [PW - 1 : 0] prd      = rs_entry_prd[sel_idx * PW +: PW];
    wire [31 : 0]     pc       = rs_entry_pc[sel_idx * 32 +: 32];
    wire [31 : 0]     imm      = rs_entry_imm[sel_idx * 32 +: 32];
    wire [LW - 1 : 0] lsq_tag  = rs_entry_lsq_tag[sel_idx * LW +: LW];
    wire [RW - 1 : 0] rob_tag  = rs_entry_rob_tag[sel_idx * RW +: RW];
    wire              pred_taken  = rs_entry_pred_taken[sel_idx];
    wire [31 : 0]     pred_target = rs_entry_pred_target[sel_idx * 32 +: 32];
    wire [RA - 1 : 0] ras_snap    = rs_entry_ras_snap[sel_idx * RA +: RA];

    wire is_r      = (opcode == 7'h33);
    wire is_i      = (opcode == 7'h13);
    wire is_lui    = (opcode == 7'h37);
    wire is_auipc  = (opcode == 7'h17);
    wire is_load   = (opcode == 7'h03);
    wire is_store  = (opcode == 7'h23);
    wire is_branch = (opcode == 7'h63);
    wire is_jal    = (opcode == 7'h6F);
    wire is_jalr   = (opcode == 7'h67);
    wire is_mul    = is_r && (func7 == 7'h01);
    wire is_ctrl   = is_branch || is_jal || is_jalr;
    wire is_mem    = is_load || is_store;

    // ---- B1 操作数获取 (CDB 旁路链, 槽内局部: 遍历 j∈[0..W], 槽 W = load 完成) ----
    wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] byp1_acc, byp2_acc, byp1_c, byp2_c;
    wire [ISSUE_WIDTH : 0]                m1, m2;
    wire m1_any = |m1, m2_any = |m2;
    genvar j;
    generate
        for (j = 0; j <= ISSUE_WIDTH; j = j + 1) begin : byp
            wire res1 = cdb_slot_valid[j] && (cdb_tag[j * PW +: PW] == prs1);
            wire res2 = cdb_slot_valid[j] && (cdb_tag[j * PW +: PW] == prs2);
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
    wire [4 : 0] alu_op = is_r ? (is_mul
 ? (func3 == 3'd0 ? 5'd10 : func3 == 3'd1 ? 5'd11
 : func3 == 3'd2 ? 5'd12 : 5'd13)
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

    // ---- CDB 生产者 (load 槽排除: 其 prd 是"地址", 依赖者不得匹配) ----
    assign exec_valid   = sel_valid && !is_load;
    assign exec_prd     = prd;
    assign exec_result  = is_ctrl ? br_link : alu_result;
    assign exec_rob_tag = rob_tag;

    // ---- 访存: 地址 = alu 结果, store 数据 = rs2 ----
    assign set_addr_req = sel_valid && is_mem;
    assign set_addr_idx = lsq_tag;
    assign set_addr_val = alu_result;
    assign set_data_req = sel_valid && is_store;
    assign set_data_idx = lsq_tag;
    assign set_data_val = op2;

    // ---- B4 误预测检测 (汇出链在 cpu_top) ----
    assign misp_det = sel_valid && ((is_branch && (br_taken != pred_taken))
                                 || (is_jalr && (br_target != pred_target)));
    assign misp_red = misp_det ? br_target : 32'd0;
    assign misp_fs  = misp_det ? rob_tag  : {RW{1'b0}};
    assign misp_ras = misp_det ? ras_snap : {RA{1'b0}};

    // ---- BHT 更新 (仅条件分支, 实际方向) / 分支计数 ----
    assign upd_req   = sel_valid && is_branch;
    assign upd_idx   = (pc >> 2) % BHT_SIZE;
    assign upd_taken = br_taken;
    assign br_inc    = sel_valid && is_branch;
endmodule
