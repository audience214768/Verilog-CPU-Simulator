// 保留站: 状态式 (只存 preg 号 + 译码字段, 不存操作数值)
// 每周期 W 级年龄优先仲裁 (年龄 = (rob_tag - rob_head) 无符号回绕; 就绪 = prs==0 || CDB 命中 || rt_ready;
//                          槽间互斥 (后级排除前级选中), 同年龄低槽赢)
// push 分配: pre_cnt 链 (条目 e 前空数) → 槽 k 取第 k+1 个空条目 (编码器)
// 写优先级: flush_mask > 自清(clear) > push
module rs #(
    parameter ISSUE_WIDTH = 1,
    parameter RS_SIZE     = 16,
    parameter PRF_SIZE    = 64,
    parameter ROB_SIZE    = 32,
    parameter LSQ_SIZE    = 16,
    parameter BHT_SIZE    = 32,
    parameter RAS_SIZE    = 8
) (
    input  clk,
    input  rst_n,
    // A: 选择结果 (组合, 年龄优先, 槽 0 最老)
    output [ISSUE_WIDTH - 1 : 0]     sel_valid,
    output [ISSUE_WIDTH * $clog2(RS_SIZE) - 1 : 0] sel_idx,
    output [$clog2(RS_SIZE + 1) - 1 : 0]             free_count,   // 当前空槽 (本拍选中数由 cpu_top 相加)
    // A: 条目字段 (cpu_top 按 sel_idx 取)
    output [RS_SIZE - 1 : 0]        entry_valid,
    output [RS_SIZE * 7 - 1 : 0]      entry_opcode,
    output [RS_SIZE * 3 - 1 : 0]      entry_func3,
    output [RS_SIZE * 7 - 1 : 0]      entry_func7,
    output [RS_SIZE * $clog2(PRF_SIZE) - 1 : 0]     entry_prs1, entry_prs2, entry_prd,
    output [RS_SIZE * 32 - 1 : 0]     entry_pc, entry_imm,
    output [RS_SIZE * $clog2(LSQ_SIZE) - 1 : 0]     entry_lsq_tag,
    output [RS_SIZE * $clog2(ROB_SIZE) - 1 : 0]     entry_rob_tag,
    output [RS_SIZE - 1 : 0]        entry_pred_taken,
    output [RS_SIZE * 32 - 1 : 0]     entry_pred_target,
    output [RS_SIZE * $clog2(RAS_SIZE) - 1 : 0]     entry_ras_snap,
    // C: 就绪判断输入
    input  [PRF_SIZE - 1 : 0]       rt_ready,
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] cdb_tag,        // 槽 0..W-1 执行, 槽 W load
    input  [ISSUE_WIDTH : 0]      cdb_slot_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]             rob_head,           // 年龄比较
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_opcode,
    input  [ISSUE_WIDTH * 3 - 1 : 0]  push_func3,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_func7,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_prs1, push_prs2, push_prd,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_pc, push_imm,
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] push_lsq_tag,
    input  [ISSUE_WIDTH * $clog2(ROB_SIZE) - 1 : 0] push_rob_tag,
    input  [ISSUE_WIDTH - 1 : 0]    push_pred_taken,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_pred_target,
    input  [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0] push_ras_snap,
    // B: 执行槽清空 (自清; 与 sel 同拍)
    input  [ISSUE_WIDTH - 1 : 0]    clear_valid,
    input  [ISSUE_WIDTH * $clog2(RS_SIZE) - 1 : 0] clear_idx,
    input  [RS_SIZE - 1 : 0]        flush_mask          // 窗口内条目失效
);
    localparam SRW = $clog2(RS_SIZE);
    localparam CSW = $clog2(RS_SIZE + 1);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam RA  = $clog2(RAS_SIZE);
    localparam STW = 1 + RW + SRW;          // 仲裁状态打包宽 {v, age, idx}

    // ---- 条目数组 ----
    reg              valid_r [0 : RS_SIZE - 1];
    reg [6 : 0]      opcode_r [0 : RS_SIZE - 1];
    reg [2 : 0]      func3_r [0 : RS_SIZE - 1];
    reg [6 : 0]      func7_r [0 : RS_SIZE - 1];
    reg [PW - 1 : 0] prs1_r [0 : RS_SIZE - 1];
    reg [PW - 1 : 0] prs2_r [0 : RS_SIZE - 1];
    reg [PW - 1 : 0] prd_r [0 : RS_SIZE - 1];
    reg [31 : 0]     pc_r [0 : RS_SIZE - 1];
    reg [31 : 0]     imm_r [0 : RS_SIZE - 1];
    reg [LW - 1 : 0] lsq_r [0 : RS_SIZE - 1];
    reg [RW - 1 : 0] rob_r [0 : RS_SIZE - 1];
    reg              ptaken_r [0 : RS_SIZE - 1];
    reg [31 : 0]     ptarget_r [0 : RS_SIZE - 1];
    reg [RA - 1 : 0] ras_r [0 : RS_SIZE - 1];

    // ---- 模块级组合打包线 (generate 间通信) ----
    wire [RS_SIZE - 1 : 0]     ready_e_w;          // 逐条目就绪 (含 valid)
    wire [RS_SIZE * RW - 1 : 0] age_pack;          // 逐条目年龄 (回绕)
    wire [ISSUE_WIDTH - 1 : 0] sel_valid_w;
    wire [ISSUE_WIDTH * SRW - 1 : 0] sel_idx_w;
    wire [ISSUE_WIDTH * SRW - 1 : 0] pidx;         // push 分配条目
    wire [ISSUE_WIDTH - 1 : 0] pvalid_w;           // 分配有效

    genvar ge, gj, gk;

    // ---- 就绪: CDB 命中 OR 链 (j = 0..W; 槽 W = load 完成) + 年龄 ----
    wire [RS_SIZE * (ISSUE_WIDTH + 1) - 1 : 0] h1c, h2c;
    generate
        for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : rdy
            for (gj = 0; gj <= ISSUE_WIDTH; gj = gj + 1) begin : hb
                if (gj == 0) begin : b0
                    assign h1c[ge * (ISSUE_WIDTH + 1) + 0]
                         = cdb_slot_valid[0] && (cdb_tag[0 * PW +: PW] == prs1_r[ge]);
                    assign h2c[ge * (ISSUE_WIDTH + 1) + 0]
                         = cdb_slot_valid[0] && (cdb_tag[0 * PW +: PW] == prs2_r[ge]);
                end else begin : bn
                    assign h1c[ge * (ISSUE_WIDTH + 1) + gj]
                         = h1c[ge * (ISSUE_WIDTH + 1) + (gj - 1)]
                         || (cdb_slot_valid[gj] && (cdb_tag[gj * PW +: PW] == prs1_r[ge]));
                    assign h2c[ge * (ISSUE_WIDTH + 1) + gj]
                         = h2c[ge * (ISSUE_WIDTH + 1) + (gj - 1)]
                         || (cdb_slot_valid[gj] && (cdb_tag[gj * PW +: PW] == prs2_r[ge]));
                end
            end
            assign age_pack[ge * RW +: RW] = rob_r[ge] - rob_head;
            assign ready_e_w[ge] = valid_r[ge]
                && ((prs1_r[ge] == 0)
                    || h1c[ge * (ISSUE_WIDTH + 1) + ISSUE_WIDTH]
                    || rt_ready[prs1_r[ge]])
                && ((prs2_r[ge] == 0)
                    || h2c[ge * (ISSUE_WIDTH + 1) + ISSUE_WIDTH]
                    || rt_ready[prs2_r[ge]]);
        end
    endgenerate

    // ---- W 级年龄仲裁: 级 k 状态链 {v, age, idx}, 候选排除前级选中 ----
    // psel[k][e] = 级 k 扫描时条目 e 已被更早级选中
    wire [ISSUE_WIDTH * RS_SIZE - 1 : 0] psel;
    wire [ISSUE_WIDTH * RS_SIZE * STW - 1 : 0] ast;
    generate
        for (gk = 0; gk < ISSUE_WIDTH; gk = gk + 1) begin : arb
            for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : slt
                // 前级选中掩码 (级 0 无)
                if (gk == 0) begin : p0
                    assign psel[0 * RS_SIZE + ge] = 1'b0;
                end else begin : pn
                    // 级 gk-1 的选中: sel_idx_w[gk-1] 与末级有效
                    wire onehot = sel_valid_w[gk - 1] && (sel_idx_w[(gk - 1) * SRW +: SRW] == ge);
                    assign psel[gk * RS_SIZE + ge] = psel[(gk - 1) * RS_SIZE + ge] || onehot;
                end
                // 候选: 就绪 && 未被前级选中 && 未 flush
                wire cand = ready_e_w[ge] && !flush_mask[ge] && !psel[gk * RS_SIZE + ge];
                // 状态递推
                wire [STW - 1 : 0] st_prev = (ge == 0)
                    ? {(1 + RW + SRW){1'b0}}
                    : ast[((gk * RS_SIZE) + ge - 1) * STW +: STW];
                wire better = !st_prev[STW - 1]
                    || (age_pack[ge * RW +: RW] < st_prev[SRW +: RW])
                    || ((age_pack[ge * RW +: RW] == st_prev[SRW +: RW]) && (ge < st_prev[SRW - 1 : 0]));
                assign ast[(gk * RS_SIZE + ge) * STW +: STW]
                     = (cand && better) ? {1'b1, age_pack[ge * RW +: RW], ge[SRW - 1 : 0]} : st_prev;
            end
            // 级输出: 末级 (e = RS_SIZE-1) 状态
            assign sel_valid_w[gk] = ast[(gk * RS_SIZE + RS_SIZE - 1) * STW + STW - 1];
            assign sel_idx_w[gk * SRW +: SRW] = ast[(gk * RS_SIZE + RS_SIZE - 1) * STW +: SRW];
        end
    endgenerate

    // ---- push 分配: pre_cnt 链 + 槽候选掩码 + 编码器 ----
    wire [RS_SIZE * CSW - 1 : 0] prec;
    generate
        for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : prc
            if (ge == 0) begin : b0
                assign prec[0 * CSW +: CSW] = {(CSW){1'b0}};
            end else begin : bn
                assign prec[ge * CSW +: CSW] = prec[(ge - 1) * CSW +: CSW] + {{(CSW - 1){1'b0}}, !valid_r[ge - 1]};
            end
        end
    endgenerate
    // 编码器链: 槽 k 取候选最低位 (候选唯一: pre_cnt 唯一)
    wire [ISSUE_WIDTH * RS_SIZE * SRW - 1 : 0] ecst;
    generate
        for (gk = 0; gk < ISSUE_WIDTH; gk = gk + 1) begin : enc
            for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : bit
                wire cand_p = !valid_r[ge] && (prec[ge * CSW +: CSW] == gk);
                wire [SRW - 1 : 0] prev_p = (ge == 0)
                    ? {SRW{1'b0}}
                    : ecst[((gk * RS_SIZE) + ge - 1) * SRW +: SRW];
                assign ecst[(gk * RS_SIZE + ge) * SRW +: SRW] = cand_p ? ge[SRW - 1 : 0] : prev_p;
                if (ge == 0) begin : v0
                    // pvalid 逐位 OR (打包链)
                end
            end
            assign pidx[gk * SRW +: SRW] = ecst[(gk * RS_SIZE + RS_SIZE - 1) * SRW +: SRW];
        end
    endgenerate
    // pvalid_w: 候选存在 (逐位 OR 链)
    wire [ISSUE_WIDTH * RS_SIZE - 1 : 0] pvc;
    generate
        for (gk = 0; gk < ISSUE_WIDTH; gk = gk + 1) begin : pv
            for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : bit
                wire cand_p = !valid_r[ge] && (prec[ge * CSW +: CSW] == gk);
                if (ge == 0) begin : b0
                    assign pvc[gk * RS_SIZE + 0] = cand_p;
                end else begin : bn
                    assign pvc[gk * RS_SIZE + ge] = pvc[gk * RS_SIZE + ge - 1] || cand_p;
                end
            end
            assign pvalid_w[gk] = pvc[gk * RS_SIZE + RS_SIZE - 1];
        end
    endgenerate

    // ---- 空槽计数 (free_count) ----
    wire [RS_SIZE * CSW - 1 : 0] fcnt;
    generate
        for (ge = 0; ge < RS_SIZE; ge = ge + 1) begin : fc
            if (ge == 0) begin : b0
                assign fcnt[0 * CSW +: CSW] = {{(CSW - 1){1'b0}}, !valid_r[0]};
            end else begin : bn
                assign fcnt[ge * CSW +: CSW] = fcnt[(ge - 1) * CSW +: CSW] + {{(CSW - 1){1'b0}}, !valid_r[ge]};
            end
        end
    endgenerate
    assign free_count = fcnt[(RS_SIZE - 1) * CSW +: CSW];

    // ---- 时序写: 优先级 flush_mask > clear > push (顺序: push 先, flush 最后覆盖) ----
    integer i2, k2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i2 = 0; i2 < RS_SIZE; i2 = i2 + 1) begin
                valid_r[i2] <= 1'b0;
                opcode_r[i2] <= 7'd0;
                func3_r[i2] <= 3'd0;
                func7_r[i2] <= 7'd0;
                prs1_r[i2] <= {PW{1'b0}};
                prs2_r[i2] <= {PW{1'b0}};
                prd_r[i2] <= {PW{1'b0}};
                pc_r[i2] <= 32'd0;
                imm_r[i2] <= 32'd0;
                lsq_r[i2] <= {LW{1'b0}};
                rob_r[i2] <= {RW{1'b0}};
                ptaken_r[i2] <= 1'b0;
                ptarget_r[i2] <= 32'd0;
                ras_r[i2] <= {RA{1'b0}};
            end
        end else begin
            // 1) push: 写分配条目全字段
            for (k2 = 0; k2 < ISSUE_WIDTH; k2 = k2 + 1) begin
                if (push_valid[k2] && pvalid_w[k2]) begin
                    opcode_r[pidx[k2 * SRW +: SRW]]   <= push_opcode[k2 * 7 +: 7];
                    func3_r[pidx[k2 * SRW +: SRW]]    <= push_func3[k2 * 3 +: 3];
                    func7_r[pidx[k2 * SRW +: SRW]]    <= push_func7[k2 * 7 +: 7];
                    prs1_r[pidx[k2 * SRW +: SRW]]     <= push_prs1[k2 * PW +: PW];
                    prs2_r[pidx[k2 * SRW +: SRW]]     <= push_prs2[k2 * PW +: PW];
                    prd_r[pidx[k2 * SRW +: SRW]]      <= push_prd[k2 * PW +: PW];
                    pc_r[pidx[k2 * SRW +: SRW]]       <= push_pc[k2 * 32 +: 32];
                    imm_r[pidx[k2 * SRW +: SRW]]      <= push_imm[k2 * 32 +: 32];
                    lsq_r[pidx[k2 * SRW +: SRW]]      <= push_lsq_tag[k2 * LW +: LW];
                    rob_r[pidx[k2 * SRW +: SRW]]      <= push_rob_tag[k2 * RW +: RW];
                    ptaken_r[pidx[k2 * SRW +: SRW]]   <= push_pred_taken[k2];
                    ptarget_r[pidx[k2 * SRW +: SRW]]  <= push_pred_target[k2 * 32 +: 32];
                    ras_r[pidx[k2 * SRW +: SRW]]      <= push_ras_snap[k2 * RA +: RA];
                    valid_r[pidx[k2 * SRW +: SRW]]    <= 1'b1;
                end
            end
            // 2) clear: 选中条目自清
            for (k2 = 0; k2 < ISSUE_WIDTH; k2 = k2 + 1)
                if (clear_valid[k2])
                    valid_r[clear_idx[k2 * SRW +: SRW]] <= 1'b0;
            // 3) flush: 窗口失效 (最高优先级, 后写覆盖)
            for (i2 = 0; i2 < RS_SIZE; i2 = i2 + 1)
                if (flush_mask[i2])
                    valid_r[i2] <= 1'b0;
        end
    end

    // ---- 输出打包 ----
    assign sel_valid = sel_valid_w;
    assign sel_idx   = sel_idx_w;
    genvar go;
    generate
        for (go = 0; go < RS_SIZE; go = go + 1) begin : out
            assign entry_valid[go]            = valid_r[go];
            assign entry_opcode[go * 7 +: 7]  = opcode_r[go];
            assign entry_func3[go * 3 +: 3]   = func3_r[go];
            assign entry_func7[go * 7 +: 7]   = func7_r[go];
            assign entry_prs1[go * PW +: PW]  = prs1_r[go];
            assign entry_prs2[go * PW +: PW]  = prs2_r[go];
            assign entry_prd[go * PW +: PW]   = prd_r[go];
            assign entry_pc[go * 32 +: 32]    = pc_r[go];
            assign entry_imm[go * 32 +: 32]   = imm_r[go];
            assign entry_lsq_tag[go * LW +: LW] = lsq_r[go];
            assign entry_rob_tag[go * RW +: RW] = rob_r[go];
            assign entry_pred_taken[go]       = ptaken_r[go];
            assign entry_pred_target[go * 32 +: 32] = ptarget_r[go];
            assign entry_ras_snap[go * RA +: RA] = ras_r[go];
        end
    endgenerate
endmodule
