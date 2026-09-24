// 取指: PC → imem (同步读 1 拍) → 寄存批 f2i_*; BHT/JAL/RAS 预测随指令流动
// 内部实例化 bht + ras; 每批 RAS 操作在接收拍一次性应用 (接收拍之外 ops=0)
// 握手: 只有"pc 被写入"的拍才发起新取指请求; 到达数据读自上一拍锁存进 memory 的地址 imem_addr_d,
//       该地址 == 期望交付地址 exp_pc_r 且批寄存器可接收时接收; redirect 清批并改 PC; halt 冻结取指
// 满批丢弃 (rewind): 稳态下 pc_r 领先 exp_pc 一个批 (请求在途), 若此时到达的正是 exp_pc 而批
//       寄存器满 (后端 stall), 该批会被丢弃且 pc 已越过它 → 永远不再交付。故丢弃拍把 pc 回退到
//       exp_pc 重取; 回退后 memory 每拍重复读出 exp_pc, 一旦 stall 解除即可立即接收 (无额外气泡)
// 失步防护: pc 是"下一次请求地址", exp_pc 是"下一批交付地址", 两者必须同步推进 (pc 领先恰好一个
//       批)。到达批被接收时若其内有预测跳转, exp_pc 跳到该目标, pc 必须同拍跳到同一目标——
//       故预测跳转优先于 stall 保持 (见 pc_next 注释), 否则两者永久失步, 取指跑飞
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

    // ---- 取指握手: 到达地址 vs 期望交付地址 ----
    // pc_wr_w: 本拍写 pc (顺序推进/预测目标/重定向) = 向 imem 发起一次新请求;
    //          stall/halt 拍不写 (例外: 到达批的预测跳转要改 pc, 见 pc_jmp_w),
    //          pc_r 保持 → imem 重复读出同一地址
    // exp_pc_r: 下一条应向 decode 交付的批地址。到达数据读自 imem_addr_d (上一拍地址),
    //   与之相等才是"下一批" → 接收。于是 pc 保持 (stall/halt) 造成的重复读出、
    //   预测跳转/重定向拍的错路读出 (地址仍是顺序地址) 全部自动丢弃, 无需额外作废信号;
    //   反之若到达的正是期望地址 (如重定向目标恰在途), 也照收不误
    //   推进: 接收时 +4*W (批内首个预测跳转则推进到其目标); 重定向时直接跟随 redirect_pc
    reg [31 : 0] exp_pc_r;
    wire batch_any   = |f2i_valid_r;
    wire batch_taken = batch_any && !stall;         // 本拍批被发射 (stall 由 cpu_top 给出)
    wire cap_ok_w  = !batch_any || batch_taken;     // 下拍批寄存器可接收 (空 或 本拍批被发射)
    wire arr_ok_w  = (imem_addr_d[0 * 32 +: 32] == exp_pc_r);   // 本拍到达是期望的下一批
    wire cap_w     = arr_ok_w && cap_ok_w && !halt; // 本拍接收到达 (halt 冻结: 不接收, exp_pc 不动)
    wire rewind_w  = arr_ok_w && !cap_ok_w && !halt; // 期望批到达却因满被丢弃 → pc 回退重取 (见头注释)
    // 预测可信条件: 到达数据正是期望批。否则到达的是错路/重复读出的陈旧指令
    // (重定向后 1 拍、预测跳转后 1 拍、stall 期间的重复读出), 若用它的跳转预测改写 pc,
    // pc 会被陈旧指令的目标劫持 → imem_addr_d 再也追不上 exp_pc_r → 永久失步死锁。
    // 非期望批时 pc 只做顺序推进 (它只是"在途请求", 不改变 exp_pc 的推进)
    wire pred_ok_w = arr_ok_w && !halt;

    // ---- 预测组合 (基于到达指令 inst_data 与 T 拍 pc_r) ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] pred_target_w;
    wire [ISSUE_WIDTH - 1 : 0]      pred_taken_w;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  ras_ops_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0] ras_pv_w;
    wire fetch_ok = cap_w && !redirect_valid && !halt;    // 接收拍 (预测/RAS ops 仅此拍生效)
    // 批内预测前缀链: pt_c[i] = "槽 i 之前已有预测跳转" = 槽 i 是否被截断
    wire [ISSUE_WIDTH : 0]            pt_c;              // pred_taken 前缀 OR
    wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] flow_c;        // 流式目标链 (首个跳转决定 PC)
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
            // RAS 操作只在"接收拍 + 该槽在取指路径上 (首个跳转及之前)"驱动:
            // 截断之后的槽是错误路径, 若也 push/pop 会污染 RAS (其指令稍后从目标地址重新取)
            assign ras_ops_w[g * 2 +: 2] = (fetch_ok && !pt_c[g])
                                         ? (is_call ? 2'd1 : (is_ret ? 2'd2 : 2'd0)) : 2'd0;
            assign ras_pv_w[g * 32 +: 32] = pc_i + 32'd4;
        end
    endgenerate

    // ---- 批内流式预测: PC 跟随"首个预测跳转"的目标 (低槽优先);
    //      其后的槽属错误路径 (valid 已截断), 它们即使预测取也不得改写 PC ----
    assign pt_c[0] = 1'b0;
    assign flow_c[0 * 32 +: 32] = 32'd0;
    genvar f;
    generate
        for (f = 0; f < ISSUE_WIDTH; f = f + 1) begin : flow
            assign pt_c[f + 1] = pt_c[f] | pred_taken_w[f];
            assign flow_c[(f + 1) * 32 +: 32] = pt_c[f] ? flow_c[f * 32 +: 32]
                                              : pred_taken_w[f] ? pred_target_w[f * 32 +: 32]
                                              : 32'd0;
        end
    endgenerate

    // ---- 期望交付地址推进 (需 pt_c/flow_c, 故置于此处) ----
    always @(posedge clk) begin
        if (!rst_n)               exp_pc_r <= 32'd0;    // 复位拍 memory 锁存地址 0, 首拍即到齐
        else if (redirect_valid)  exp_pc_r <= redirect_pc;
        else if (cap_w)           exp_pc_r <= pt_c[ISSUE_WIDTH] ? flow_c[ISSUE_WIDTH * 32 +: 32]
                                                            : (exp_pc_r + 32'd4 * ISSUE_WIDTH);
    end

    // ---- PC 推进 (redirect > 满批丢弃回退 > 预测目标 > stall/halt 保持 > 顺序推进) ----
    // 预测目标只在 pred_ok_w (到达批属于本流) 时采用, 见 pred_ok_w 注释
    // 预测目标优先于 stall 保持: 到达批被接收 (cap_w) 时 exp_pc 已推进到其跳转目标,
    //   若因 stall (cpu_top 冲刷期 flushing_r 使然) 而让 pc 停在原地, pc 之后只做顺序推进,
    //   到达地址流再也追不上 exp_pc → 取指永久跑飞 (pc 每拍 +4*W 走进未映射区, commit 冻结)。
    //   带预测跳转的到达批必然是"被接收"的 (arr_ok && !rewind ⇒ cap_ok), 故 pc 与 exp_pc 同步跳
    // 注: stall 且到达批无预测跳转时仍保持 pc——exp_pc 只 +4*W, 到达流下一拍即与之重合, 不失步
    wire pc_jmp_w = pred_ok_w && pt_c[ISSUE_WIDTH];
    wire [31 : 0] pc_next = redirect_valid ? redirect_pc
                          : rewind_w ? exp_pc_r
                          : pc_jmp_w ? flow_c[ISSUE_WIDTH * 32 +: 32]
                          : (stall || halt) ? pc_r
                          : (pc_r + 32'd4 * ISSUE_WIDTH);
    // pc_jmp_w 必须在写使能里 (否则 stall 拍 pc_wr_w=0, 上面选的跳转目标根本写不进去)
    wire pc_wr_w = rst_n && (redirect_valid || rewind_w || pc_jmp_w || (!stall && !halt));
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
    // 复位值 = pc_r(=0) 下的各槽地址 4*g: 复位期间 memory 已在读这组地址, 若复位成全 0
    // 则复位后首批的 pc[1..W-1] 会被写成 0 (批内 pc 错位一拍)
    always @(posedge clk) begin
        if (!rst_n)
            for (bb = 0; bb < ISSUE_WIDTH; bb = bb + 1)
                imem_addr_d[bb * 32 +: 32] <= 32'd4 * bb;
        else
            imem_addr_d <= imem_addr;
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
