// 取指: PC → imem (同步读 1 拍) → 寄存批 f2i_*; BHT/JAL/RAS 预测随指令流动
// 内部实例化 bht + ras; 每批 RAS 操作在采样拍一次性应用 (stall/halt/redirect 拍 ops=0 不重复)
// stall 保持 PC 与输出; redirect 清空当前批并改 PC; halt 停止取指
module fetch #(
    parameter ISSUE_WIDTH = 1,
    parameter BHT_SIZE    = 32,
    parameter RAS_SIZE    = 8
) (
    input  clk,
    input  rst_n,
    // A: 到 decode/issue (寄存; stall 保持; redirect 清 0)
    output [ISSUE_WIDTH - 1 : 0]     f2i_valid,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_raw,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_pc,
    output [ISSUE_WIDTH - 1 : 0]     f2i_pred_taken,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_pred_target,
    output [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0]  f2i_ras_snap,   // 取指时 ras head (仅 branch/jalr 有意义)
    output [ISSUE_WIDTH * 32 - 1 : 0]  imem_addr,      // 到 memory 的取指地址 (pc+4i)
    // B: 输入 (透传内部 bht/ras)
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_req,    // 执行槽 i: 条件分支更新 (透传 bht)
    input  [ISSUE_WIDTH * $clog2(BHT_SIZE) - 1 : 0]  bht_upd_idx,    // 执行槽 i: 索引 (pc>>2)%BHT_SIZE
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_taken,  // 执行槽 i: 实际方向
    input                        ras_restore_valid,  // 误预测 head 恢复 (透传 ras)
    input  [$clog2(RAS_SIZE) - 1 : 0]              ras_restore_head,
    input  [ISSUE_WIDTH * 32 - 1 : 0] inst_data,       // memory 同步读 (1 拍延迟)
    input                 stall,                 // 保持 PC 与输出
    input                 redirect_valid,
    input  [31 : 0]         redirect_pc,
    input                 halt
);
    localparam RA = $clog2(RAS_SIZE);
    localparam BW = $clog2(BHT_SIZE);
    integer bb;

    // ---- 内部实例信号 (声明提前: generate 块内使用) ----
    wire [2 * BHT_SIZE - 1 : 0]     counters;
    wire [ISSUE_WIDTH * 32 - 1 : 0] ras_top;
    wire [ISSUE_WIDTH * RA - 1 : 0] ras_head_snap;
    reg [31 : 0] pc_r;
    // 与 inst_data 同地址的取指地址: memory 同步读 1 拍 + 批采样 1 拍,
    // 批的 pc/预测必须基于该地址, 否则与 raw 错位一拍
    reg [ISSUE_WIDTH * 32 - 1 : 0] imem_addr_d;

    // ---- 预测组合 (基于到达指令 inst_data 与 T 拍 pc_r) ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] pred_target_w;
    wire [ISSUE_WIDTH - 1 : 0]      pred_taken_w;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  ras_ops_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0] ras_pv_w;
    wire fetch_ok = !stall && !redirect_valid && !halt;   // 采样拍 (RAS ops 仅此拍驱动)
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : pr
            wire [31 : 0] raw  = inst_data[g * 32 +: 32];
            wire [31 : 0] pc_i = imem_addr_d[g * 32 +: 32];   // 与 inst_data 同地址
            wire [6 : 0]  opc  = raw[6 : 0];
            wire is_jal  = (opc == 7'b1101111);
            wire is_jalr = (opc == 7'b1100111);
            wire is_br   = (opc == 7'b1100011);
            wire is_call = is_jal && (raw[11 : 7] == 5'd1);
            wire is_ret  = is_jalr && (raw[11 : 7] == 5'd0) && (raw[19 : 15] == 5'd1);
            // B/J imm 符号扩展 (与 decode 保持同步, 见 plan)
            wire [31 : 0] imm_b = {{20{raw[31]}}, raw[7], raw[30 : 25], raw[11 : 8], 1'b0};
            wire [31 : 0] imm_j = {{12{raw[31]}}, raw[19 : 12], raw[20], raw[30 : 21], 1'b0};
            wire [BW - 1 : 0] bidx = (pc_i >> 2) % BHT_SIZE;
            wire [1 : 0] cnt = counters[bidx * 2 +: 2];
            wire bht_taken = cnt[1];
            assign pred_taken_w[g] = is_jal || (is_br && bht_taken) || is_ret;
            assign pred_target_w[g * 32 +: 32] = is_jal ? (pc_i + imm_j)
                                               : is_br ? (pc_i + imm_b)
                                               : is_ret ? ras_top[g * 32 +: 32]
                                               : (pc_i + 32'd4);
            assign ras_ops_w[g * 2 +: 2] = fetch_ok ? (is_call ? 2'd1 : (is_ret ? 2'd2 : 2'd0)) : 2'd0;
            assign ras_pv_w[g * 32 +: 32] = pc_i + 32'd4;
        end
    endgenerate

    // ---- 批内流式预测: 取指跟随最后一个预测跳转 (链: 低槽优先, 高槽覆盖) ----
    wire [ISSUE_WIDTH : 0]            pt_c;              // pred_taken 前缀 OR
    wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] flow_c;        // 流式目标链
    assign pt_c[0] = 1'b0;
    assign flow_c[0 * 32 +: 32] = 32'd0;
    genvar f;
    generate
        for (f = 0; f < ISSUE_WIDTH; f = f + 1) begin : flow
            assign pt_c[f + 1] = pt_c[f] | pred_taken_w[f];
            assign flow_c[(f + 1) * 32 +: 32] = pred_taken_w[f] ? pred_target_w[f * 32 +: 32]
                                              : flow_c[f * 32 +: 32];
        end
    endgenerate

    // ---- PC 推进 (redirect > 预测目标 > stall/halt 保持 > 顺序推进) ----
    wire [31 : 0] pc_next = redirect_valid ? redirect_pc
                          : (stall || halt) ? pc_r
                          : pt_c[ISSUE_WIDTH] ? flow_c[ISSUE_WIDTH * 32 +: 32]
                          : (pc_r + 32'd4 * ISSUE_WIDTH);
    always @(posedge clk) begin
        if (!rst_n) pc_r <= 32'd0;
        else        pc_r <= pc_next;
    end

    // ---- imem 地址 (当前拍 PC 基址 + 4i) ----
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : ia
            assign imem_addr[g * 32 +: 32] = pc_r + 32'd4 * g;
        end
    endgenerate
    // imem_addr_d: imem_addr 延迟一拍 (与 memory 的 inst_data 同地址)
    always @(posedge clk) begin
        if (!rst_n) imem_addr_d <= {ISSUE_WIDTH * 32{1'b0}};
        else        imem_addr_d <= imem_addr;
    end

    // ---- 批寄存器 (采样拍采预测+指令; stall/halt 保持; redirect 清 0) ----
    reg [ISSUE_WIDTH - 1 : 0]      f2i_valid_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_raw_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_pc_r;
    reg [ISSUE_WIDTH - 1 : 0]      f2i_ptaken_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_ptarget_r;
    reg [ISSUE_WIDTH * RA - 1 : 0] f2i_ras_r;
    // first_r: 复位解除后第一拍, memory 首地址 (0,4,..) 在复位拍与第一正常拍
    // 被采样两次且 imem_addr_d 尚是复位值, 批数据未就绪 → 本拍不采样 (保持复位态)
    reg first_r;
    always @(posedge clk) begin
        if (!rst_n) first_r <= 1'b1;
        else        first_r <= 1'b0;
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            f2i_valid_r <= {ISSUE_WIDTH{1'b0}};
            f2i_raw_r   <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_pc_r    <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_ptaken_r  <= {ISSUE_WIDTH{1'b0}};
            f2i_ptarget_r <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_ras_r   <= {ISSUE_WIDTH * RA{1'b0}};
        end else if (stall || halt) begin
            // 保持
        end else if (redirect_valid) begin
            f2i_valid_r <= {ISSUE_WIDTH{1'b0}};
        end else if (first_r) begin
            // 复位后第一拍不采样 (保持复位态)
        end else begin
            // 批内首个预测跳转 (含) 之后截断 valid: 其后的指令是错误路径
            for (bb = 0; bb < ISSUE_WIDTH; bb = bb + 1)
                f2i_valid_r[bb] <= !pt_c[bb];
            f2i_raw_r     <= inst_data;
            f2i_pc_r      <= imem_addr_d;   // 与 inst_data 同地址
            f2i_ptaken_r  <= pred_taken_w;
            f2i_ptarget_r <= pred_target_w;
            f2i_ras_r     <= ras_head_snap;
        end
    end

    // ---- bht / ras 实例 ----
    bht #(.ISSUE_WIDTH(ISSUE_WIDTH), .BHT_SIZE(BHT_SIZE)) u_bht (
        .clk(clk), .rst_n(rst_n),
        .counters(counters),
        .upd_req(bht_upd_req), .upd_idx(bht_upd_idx), .upd_taken(bht_upd_taken)
    );
    ras #(.ISSUE_WIDTH(ISSUE_WIDTH), .RAS_SIZE(RAS_SIZE)) u_ras (
        .clk(clk), .rst_n(rst_n),
        .top(ras_top), .head_snap(ras_head_snap),
        .ops(ras_ops_w), .push_val(ras_pv_w),
        .restore_valid(ras_restore_valid), .restore_head(ras_restore_head)
    );

    // ---- 输出 ----
    assign f2i_valid      = f2i_valid_r;
    assign f2i_raw        = f2i_raw_r;
    assign f2i_pc         = f2i_pc_r;
    assign f2i_pred_taken = f2i_ptaken_r;
    assign f2i_pred_target = f2i_ptarget_r;
    assign f2i_ras_snap   = f2i_ras_r;
endmodule
