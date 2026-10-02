// 取指: PC → imem (同步读语义: 本拍地址, 下拍数据) → 寄存批 f2i_*; BHT/JAL/RAS 预测随指令流动
// 内部实例化 bht + ras; 每批 RAS 操作在接收拍一次性应用 (接收拍之外 ops=0)
// 握手: pc_r ≡ "本拍要向存储请求的批地址"; 到达数据读自上一拍锁存进存储的地址 imem_addr_d,
//       该地址 == 期望交付地址 exp_pc_r 且 imem_valid (数据确实回来了) 且批寄存器可接收时接收;
//       redirect 清批并改 PC; halt 冻结取指 (重定向例外)
// 请求回退 (rewind): 稳态下 pc_r 领先 exp_pc 一个批 (请求在途), 若此时到达的正是 exp_pc 而批
//       寄存器满 (后端 stall), 该批会被丢弃且 pc 已越过它 → 永远不再交付。故丢弃拍把 pc 回退到
//       exp_pc 重取; 回退后存储每拍重复交付 exp_pc, 一旦 stall 解除即可立即接收 (无额外气泡)
// 失步防护: pc_r 与 exp_pc_r 恒差 0 或一个批。到达批被接收时若其内有预测跳转, exp_pc 跳到该目标,
//       pc 必须同拍跳到同一目标 —— 故预测跳转优先于一切保持分支 (见 pc_next 注释), 否则两者永久失步。
//       存储带延迟时 (imem_hit=0: 期望批尚未取到) pc 只停在 exp_pc_r 上重复请求它, 绝不超前 ——
//       超前会让请求地址每拍翻转, 预取流永远重启, 一个字也取不回来 (见 pc_lead_w 注释)
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
    output [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0]  f2i_ras_snap,   // 误预测恢复载荷 = 取指时**本槽 ops 之后**的 ras head
    output [ISSUE_WIDTH * 32 - 1 : 0]  imem_addr,      // 到 memory 的取指地址 (pc+4i)
    // B: 输入 (透传内部 bht/ras)
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_req,    // 执行槽 i: 条件分支更新 (透传 bht)
    input  [ISSUE_WIDTH * $clog2(BHT_SIZE) - 1 : 0]  bht_upd_idx,    // 执行槽 i: 索引 (pc>>2)%BHT_SIZE
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_taken,  // 执行槽 i: 实际方向
    input                        ras_restore_valid,  // 误预测 head 恢复 (透传 ras)
    input  [$clog2(RAS_SIZE) - 1 : 0]              ras_restore_head,
    input  [ISSUE_WIDTH * 32 - 1 : 0] inst_data,       // 存储读出 (固定 1 拍, 或变长延迟)
    input                 imem_valid,            // 本拍 inst_data 确实读自 imem_addr_d (变长延迟时可能为 0)
    input                 imem_hit,              // 本拍 imem_addr 上的地址在存储中已可取 (可带延迟的缓冲存储;
                                                 //   固定 1 拍存储恒 1) —— 用来判"能否预先发出下一批请求"
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
    // imem_valid: 存储可含延迟, 未就绪时 inst_data 仍是上一次的值 (地址已对但数据是旧的),
    //   故"接收/回退"都必须以它为前提 —— 单看 arr_ok_w 会把旧数据当成新到达
    //   (负向用例实测: cap_w 这一项是硬要求 (删掉立刻把旧指令当到达批收下);
    //    rewind_w 这一项被 pc_next 的默认分支 (退回 exp_pc_r) 覆盖 —— 单删不报错, 保留为使本条自身完整)
    wire cap_w     = arr_ok_w && cap_ok_w && !halt && imem_valid; // 本拍接收到达 (halt 冻结: 不接收, exp_pc 不动)
    wire rewind_w  = arr_ok_w && !cap_ok_w && !halt && imem_valid; // 期望批到达却因满被丢弃 → pc 回退重取 (见头注释)
    // 预测可信条件: 到达数据正是期望批。否则到达的是错路/重复读出的陈旧指令
    // (重定向后 1 拍、预测跳转后 1 拍、stall 期间的重复读出), 若用它的跳转预测改写 pc,
    // pc 会被陈旧指令的目标劫持 → imem_addr_d 再也追不上 exp_pc_r → 永久失步死锁。
    // 非期望批时 pc 只做顺序推进 (它只是"在途请求", 不改变 exp_pc 的推进)
    // ★ 数据未就绪 (imem_valid=0) 时 inst_data 是上一次的指令, 用它的预测目标改 pc
    //   就是上面那条死锁路径 (从"理论"变成"可达") —— 故此处也必须含 imem_valid。
    //   (负向用例实测: 迟到拍 hold_w 已挡住一切 pc 写, 故本项目前被 hold_w 覆盖, 单删不报错;
    //    仍就地写全, 使"预测可信"的条件不依赖 hold_w 这条远端约束)
    wire pred_ok_w = arr_ok_w && !halt && imem_valid;

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
            // call = jal/jalr 且 rd ∈ {x1, x5} —— ABI 的两个 link 寄存器。
            // 编译器生成的调用全是 auipc + jalr x1, 旧写法只认 jal ⇒ 调用从不 push,
            // 每次 ret 都对着空栈预测 0 (docs/plan.md §二十八)
            wire is_call = (is_jal || is_jalr)
                        && ((raw[11 : 7] == 5'd1) || (raw[11 : 7] == 5'd5));
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

    // ---- PC 推进 (redirect > 满批丢弃回退 > 预测目标 > 批被接收 > 落后补发 > 退回请求 exp_pc) ----
    // pc_r 的语义 ≡ "本拍要向存储请求的地址" (存储契约: imem_addr 上的地址, 下拍交付其数据)。
    //   与 exp_pc_r (下一批要交付的地址) 的关系恒为 pc_r ∈ { exp_pc_r, exp_pc_r + 4W }:
    //     相等 = "期望批尚未取到, 正在请求它"; 差一个批 = "已有一批在途" (稳态流水)。
    // 预测目标优先于一切保持分支: 到达批被接收 (cap_w) 时 exp_pc 已推进到其跳转目标,
    //   若因 stall (cpu_top 冲刷期 flushing_r 使然) 而让 pc 停在原地, 到达地址流再也追不上
    //   exp_pc → 取指永久跑飞。带预测跳转的到达批必然是"被接收"的 (arr_ok && !rewind ⇒ cap_ok),
    //   故 pc 与 exp_pc 同步跳
    // ★ 末支"退回请求 exp_pc_r"是变长延迟存储下的**硬要求**(1 拍存储下不可复现):
    //   期望批的数据迟到时若 pc 仍停在 exp_pc_r + 4W, 存储下拍就去准备 exp_pc_r + 4W 的数据,
    //   exp_pc_r 的数据再也不会被交付 ⇒ arr_ok_w 恒 0 ⇒ 取指永久失步。实测 (官方 add_to_100):
    //   t=108 起 0x44 的数据迟到 4 拍 (imem_valid=0, pc 被回退前的旧写法冻在 0x48); t=112 数据回来,
    //   但存储此刻查找的是 0x48 (它只认"上一拍请求的地址"), imem_valid=1 而 arr_ok_w=0 ——
    //   旧写法 `!stall` 分支照推进 ⇒ pc 一路 +4 跑到 0x4c8c, exp_pc_r 冻在 0x44, rob 排空后
    //   全机死锁 (commit 恒 9)。退回请求 exp_pc_r 后, 存储查找地址即为 exp_pc_r, 数据一到即接收。
    //   (1 拍存储下 V 恒 1 ⇒ cap 每拍成立, 本支不可达 ⇒ 行为与改动前逐拍一致)
    // halt 冻结 (redirect 例外, 重定向必须随时能改 pc); stall 时停在 exp_pc_r 等它 —— 存储每拍
    //   重复读出该地址, 一旦批寄存器空出即可立即接收 (无额外气泡)
    wire pc_jmp_w = pred_ok_w && pt_c[ISSUE_WIDTH];
    wire pc_behind_w = (pc_r == exp_pc_r);      // 尚未发出下一批请求 (重定向/回退/命中恢复之后)
    // 落后补发: 期望批本身已在存储中可取 (imem_hit) 时, 才可把请求预先推到下一批 —— 它只花一个在途
    //   请求的代价换来"到达流与 exp_pc 同拍对齐"。若不加 imem_hit, 数据未回的拍会盲目超前 →
    //   下一拍到达的不是期望批 → 退回 → 再超前 → 请求地址每拍翻转, 预取流永远重启, 一个字也取不回来
    //   (实测: 官方 add_to_100 的失败运行 VCD 里 pc_r 每拍在两个相邻批地址间翻转 —— 1e6 拍内变化 999988 次;
    //    AR 只发出 286 条后再无一条 (最后一次在全程的约 1/1600 处), 提交停在 414/421 条)
    // ★ 这里的 imem_hit 必须是**整批 W 个字**都可取 (与接收侧的 imem_valid = &slot_hit 同口径, 见
    //   mem_subsystem.v 该输出的注释): W≥2 下只比批首时, "槽 0 已回、槽 1 未回"也会放行超前 ⇒
    //   下一拍 arr_ok 成立但 imem_valid=0 ⇒ cap 落空 ⇒ pc 退回 exp_pc_r ⇒ 又超前 ⇒ 同样每拍翻转。
    //   W=1 时整批 == 批首, 与原判据逐位等价。
    wire pc_lead_w = pc_behind_w && imem_hit && !stall;
    wire [31 : 0] pc_next = redirect_valid ? redirect_pc
                          : rewind_w       ? exp_pc_r
                          : pc_jmp_w       ? flow_c[ISSUE_WIDTH * 32 +: 32]
                          : halt           ? pc_r
                          : cap_w          ? (pc_r + 32'd4 * ISSUE_WIDTH)
                          : pc_lead_w      ? (pc_r + 32'd4 * ISSUE_WIDTH)
                          : exp_pc_r;
    // redirect/rewind/pc_jmp/落后补发 都必须能写进 pc, 故写使能只看"下一值是否与当前不同"
    wire pc_wr_w = rst_n && (pc_next != pc_r);
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
