// 取指: PC → imem (同步读 1 拍) → 寄存批 f2i_*; BHT/JAL/RAS 预测随指令流动
// 内部实例化 bht + ras; 每批 RAS 操作在接收拍一次性应用 (接收拍之外 ops=0)
// 握手: 只有"pc 被写入"的拍才发起新取指请求 (req 标记随 imem 延迟流动),
//       到达 (inst_data 上是新请求的结果) 且批寄存器可接收时接收; redirect 清批并改 PC; halt 停止取指
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
    reg [ISSUE_WIDTH - 1 : 0]      f2i_valid_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_raw_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_pc_r;
    reg [ISSUE_WIDTH - 1 : 0]      f2i_ptaken_r;
    reg [ISSUE_WIDTH * 32 - 1 : 0] f2i_ptarget_r;
    reg [ISSUE_WIDTH * RA - 1 : 0] f2i_ras_r;

    // ---- 取指握手: 请求序号 (tag) 随 imem 延迟流动, 按序接收 ----
    // pc_wr_w: 本拍写 pc (顺序推进/预测目标/重定向) = 向 imem 发起一次新请求;
    //          stall/halt 拍不写, pc_r 保持 → imem 重复读出同一地址
    // tag 机制: 每次请求带递增序号, inst_data(C+1) 对应 pres(C) = pc_r(C) 的序号 tag_r(C);
    //   接收条件 = 到达序号 == 期望序号 del_tag_r。pc 保持 / 冲刷 / 预测跳转拍重复读出或
    //   已作废的地址, 其序号与期望不符 → 自动丢弃 (不会重复发射, 也不会发射错路指令)
    //   期望序号只在接收时 +1, 重定向时跳到 (tag_r + 1) = 跳转目标请求的序号
    // 在途请求 ≤ 2 (imem 读 1 + 到达 1) → 2 bit 序号不回绕冲突
    reg [1 : 0] tag_r, arr_tag_r, del_tag_r;
    reg kill_r;     // 跳转应用拍 → 下拍到达作废 (见下)
    wire batch_any   = |f2i_valid_r;
    wire batch_taken = batch_any && !stall;         // 本拍批被发射 (stall 由 cpu_top 给出)
    wire cap_ok_w  = !batch_any || batch_taken;     // 下拍批寄存器可接收 (空 或 本拍批被发射)
    wire arr_ok_w  = !kill_r && (arr_tag_r == del_tag_r);   // 本拍到达是期望的下一条指令
    wire cap_w     = arr_ok_w && cap_ok_w;          // 本拍接收到达
    wire pc_wr_w   = rst_n && (redirect_valid || (!stall && !halt));

    // ---- 预测组合 (基于到达指令 inst_data 与 T 拍 pc_r) ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] pred_target_w;
    wire [ISSUE_WIDTH - 1 : 0]      pred_taken_w;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  ras_ops_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0] ras_pv_w;
    wire fetch_ok = cap_w && !redirect_valid && !halt;    // 接收拍 (RAS ops 仅此拍驱动)
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

    // ---- 跳转作废 + 序号推进 (需 pt_c/flow_c, 故置于此处) ----
    // 跳转作废: 预测跳转/重定向在 E 边沿改 PC, 而 E 结束时锁存进 imem 的地址是跳转前
    // 呈现的顺序地址 (取指看不到尚未到达的分支), 其到达 (下拍) 必是错路 → 作废一拍
    wire jump_w = pt_c[ISSUE_WIDTH] || redirect_valid;
    always @(posedge clk) begin
        if (!rst_n) begin
            kill_r    <= 1'b0;
            tag_r     <= 2'd0;
            arr_tag_r <= 2'd0;                      // 复位值 PC = 序号 0, 首拍到齐
            del_tag_r <= 2'd0;
        end else begin
            kill_r    <= jump_w;
            tag_r     <= tag_r + {{1{1'b0}}, pc_wr_w};
            arr_tag_r <= tag_r;                     // 与 memory 数据同延迟 (1 拍)
            // 跳转 (重定向 / 接收了预测跳转批): 期待下拍发起的请求 (跳转目标), 跳过在途的顺序地址
            del_tag_r <= (redirect_valid || (cap_w && pt_c[ISSUE_WIDTH])) ? (tag_r + 2'd1)
                       : cap_w ? (del_tag_r + 2'd1) : del_tag_r;
        end
    end

    // ---- PC 推进 (redirect > 预测目标 > stall/halt 保持 > 顺序推进) ----
    wire [31 : 0] pc_next = redirect_valid ? redirect_pc
                          : (stall || halt) ? pc_r
                          : pt_c[ISSUE_WIDTH] ? flow_c[ISSUE_WIDTH * 32 +: 32]
                          : (pc_r + 32'd4 * ISSUE_WIDTH);
    always @(posedge clk) begin
        if (!rst_n)       pc_r <= 32'd0;
        else if (pc_wr_w) pc_r <= pc_next;
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

    always @(posedge clk) begin
        if (!rst_n) begin
            f2i_valid_r <= {ISSUE_WIDTH{1'b0}};
            f2i_raw_r   <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_pc_r    <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_ptaken_r  <= {ISSUE_WIDTH{1'b0}};
            f2i_ptarget_r <= {ISSUE_WIDTH * 32{1'b0}};
            f2i_ras_r   <= {ISSUE_WIDTH * RA{1'b0}};
        end else if (redirect_valid) begin
            // redirect 优先于 stall: 误预测拍 issue_en=0 → stall=1, 若 stall 优先则本批
            // (错路指令) 被保留, 冲刷结束后会被当成新取指发射进 rob
            f2i_valid_r <= {ISSUE_WIDTH{1'b0}};
        end else if (cap_w) begin
            // 批内首个预测跳转 (含) 之后截断 valid: 其后的指令是错误路径
            for (bb = 0; bb < ISSUE_WIDTH; bb = bb + 1)
                f2i_valid_r[bb] <= !pt_c[bb];
            f2i_raw_r     <= inst_data;
            f2i_pc_r      <= imem_addr_d;   // 与 inst_data 同地址
            f2i_ptaken_r  <= pred_taken_w;
            f2i_ptarget_r <= pred_target_w;
            f2i_ras_r     <= ras_head_snap;
        end else if (batch_taken) begin
            // 已发射 → 清 valid (数据由下次接收覆盖), 否则同一条目会被再次发射
            f2i_valid_r <= {ISSUE_WIDTH{1'b0}};
        end
        // else: 未接收 (批未发射 / 无到达) → 保持
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
