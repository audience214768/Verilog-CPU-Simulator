// tb_fetch: 段 1 小规模+极端 (复位/顺序取指/stall 保持/redirect 清批/halt 停取指/jal 恒取/
//        BHT 弱不取判定+饱和更新+强取/call-push ret-pop 链/满 push 丢 空 pop 忽略/
//        RAS restore/同索引 BHT 高槽 (更年轻) 覆盖);
//        段 2 随机模型对照 (300 拍, PC/批输出/预测/counters/head_snap 逐拍断言)
// 握手契约 (verilog/front/fetch.v): 到达数据读自上一拍锁存进 memory 的地址 imem_addr_d,
//        该地址 == 期望交付地址 exp_pc_r 且批寄存器可接收 (空 或 本拍批被发射) 时接收;
//        接收拍推进 exp_pc (批内有预测跳转则推进到跳转目标, 否则 +4*W);
//        redirect 清批并把 PC 与 exp_pc 都置为 redirect_pc; halt/stall 拍 PC 不写 → 地址重复读出
// TB 自带 256 字 imem 模拟同步读: 本拍 inst_data = 上一拍取指地址的字 → 与 DUT 的 imem_addr_d 同址;
//        imem_valid=0 则模拟数据迟到 (总线上摆陈旧 jal x1, 见 STALE): 该拍不接收且 pc 冻结
`timescale 1ns/1ps
module tb_fetch;
    localparam IW  = 4;
    localparam BHT = 32;
    localparam RAS = 8;
    localparam RA  = 3;
    localparam BW  = 5;
    localparam IMEM_N = 256;            // imem 字数 (1KB)
    localparam NOP    = 32'h00000013;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [IW - 1 : 0]     f2i_valid;
    wire [IW * 32 - 1 : 0]  f2i_raw, f2i_pc, f2i_pred_target;
    wire [IW - 1 : 0]     f2i_pred_taken;
    wire [IW * RA - 1 : 0]  f2i_ras_snap;
    wire [IW * 32 - 1 : 0]  imem_addr;
    reg  [IW - 1 : 0]     bht_upd_req;
    reg  [IW * BW - 1 : 0]  bht_upd_idx;
    reg  [IW - 1 : 0]     bht_upd_taken;
    reg                 ras_restore_valid;
    reg  [RA - 1 : 0]   ras_restore_head;
    wire [IW * 32 - 1 : 0] inst_data;
    reg                 stall, redirect_valid, halt;
    reg  [31 : 0]         redirect_pc;
    reg                 imem_valid;      // 本拍 inst_data 是否有效 (默认 1 = 固定 1 拍存储; F15 拉低模拟变长延迟)

    fetch #(.ISSUE_WIDTH(IW), .BHT_SIZE(BHT), .RAS_SIZE(RAS)) dut (
        .clk(clk), .rst_n(rst_n),
        .f2i_valid(f2i_valid), .f2i_raw(f2i_raw), .f2i_pc(f2i_pc),
        .f2i_pred_taken(f2i_pred_taken), .f2i_pred_target(f2i_pred_target),
        .f2i_ras_snap(f2i_ras_snap), .imem_addr(imem_addr),
        .bht_upd_req(bht_upd_req), .bht_upd_idx(bht_upd_idx), .bht_upd_taken(bht_upd_taken),
        .ras_restore_valid(ras_restore_valid), .ras_restore_head(ras_restore_head),
        .inst_data(inst_data), .imem_valid(imem_valid), .stall(stall),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc), .halt(halt)
    );

    integer errors = 0;
    integer i, j, k;
    reg [31 : 0] saved_pc, saved_pcr;   // F3/F5 保持性检查用
    reg [31 : 0] saved_addr;            // F15 保持性检查用
    reg [RA - 1 : 0] saved_ras;         // F15: 迟到拍不得误 push RAS

    // ---- 指令编码辅助 ----
    function [31 : 0] jal_enc;
        input [4 : 0]  rd;
        input [31 : 0] imm;
        begin
            jal_enc = {imm[20], imm[10 : 1], imm[11], imm[19 : 12], rd, 7'b1101111};
        end
    endfunction
    function [31 : 0] jalr_enc;
        input [4 : 0]  rd, rs1;
        input [31 : 0] imm;
        begin
            jalr_enc = {imm[11 : 0], rs1, 3'b000, rd, 7'b1100111};
        end
    endfunction
    function [31 : 0] b_enc;
        input [4 : 0]  rs1, rs2;
        input [31 : 0] imm;
        begin
            b_enc = {imm[12], imm[10 : 5], rs2, rs1, 3'b000, imm[4 : 1], imm[11], 7'b1100011};
        end
    endfunction

    // ---- 模型状态 (TB 自身的取指影子, 不读 DUT 内部信号) ----
    reg [31 : 0] m_pc;                  // 本拍 pc_r
    reg [31 : 0] m_pc_prev;             // 上一拍 pc_r = 本拍 imem_addr_d 槽 0
    reg [31 : 0] m_exp;                 // 本拍期望交付地址 exp_pc_r
    reg [IW - 1 : 0]      m_fvalid;
    reg [IW * 32 - 1 : 0] m_fraw, m_fpc, m_ftarget;
    reg [IW - 1 : 0]      m_ftaken;
    reg [IW * RA - 1 : 0] m_fras;
    reg [1 : 0]      m_bht [0 : BHT - 1];
    reg [31 : 0]     m_stack [0 : RAS - 1];
    reg [RA - 1 : 0] m_head;
    // 上一拍组合量 (本拍 posedge 生效)
    reg                   m_arr, m_capok, m_rew, m_fok;   // 到达/可接收/满批回退/接收拍(ras ops 门控)
    reg                   m_cap;
    reg                   m_predok;           // 到达即期望批 → 其跳转预测才可改写 pc
    reg                   m_ptc;
    reg [31 : 0]          m_flow;
    reg [IW - 1 : 0]      m_rops_ok;          // 已门控的 call (push)
    reg [IW * 32 - 1 : 0] m_rpv;              // push 值 (批内该槽 pc+4)
    // 本拍组合量
    reg [IW - 1 : 0]      m_ptaken;
    reg [IW * 32 - 1 : 0] m_ptarget;
    reg [(IW + 1) * (RA + 1) - 1 : 0] m_h;    // ras head 链 (本拍)
    reg [IW - 1 : 0]      m_push_ok;          // 本拍 push 是否成功 (未满)
    reg [IW * RA - 1 : 0] m_snap;             // 本拍 head_snap
    reg [IW * 32 - 1 : 0] m_top;              // 本拍 ras 栈顶 (ret 目标)
    reg [2 * IW - 1 : 0]  m_nv;               // bht 每槽新值 (基于旧值快照)

    // ---- imem (同步读 1 拍): 本拍数据 = 上一拍取指地址的字 ----
    // imem_valid=0 模拟"变长延迟": 数据没回来, 总线上是陈旧值 → 显式摆一条 jal x1 (会劫持 pc / 误 push RAS),
    //   故 DUT 只要在迟到拍误用它 (接收或采信其预测), check_all 与冻结断言立刻失配
    localparam [31 : 0] STALE = 32'h0010_00EF;   // = jal x1, +0x800
    reg [31 : 0] imem [0 : IMEM_N - 1];
    genvar si;
    generate
        for (si = 0; si < IW; si = si + 1) begin : im
            assign inst_data[si * 32 +: 32]
                 = imem_valid ? imem[((m_pc_prev >> 2) + si) % IMEM_N] : STALE;
        end
    endgenerate

    // ---- 4 字节对齐随机立即数 (imem 按字索引, 非对齐目标无意义) ----
    function [31 : 0] rnd_imm4;
        input integer modv;
        begin
            rnd_imm4 = ($random % modv) * 4;
        end
    endfunction

    task clr_all;
        begin
            bht_upd_req = 0; bht_upd_idx = 0; bht_upd_taken = 0;
            ras_restore_valid = 0; ras_restore_head = 0;
            stall = 0; redirect_valid = 0; halt = 0;
            redirect_pc = 0;
            imem_valid = 1'b1;
        end
    endtask

    // ---- 组合量 (当拍状态 → 当拍到达判定/预测/ras 链); 复位后先 prime 一次再 tick ----
    task model_comb;
        integer li;
        reg [31 : 0] raw, pc_i, imm_b, imm_j, topv;
        reg [6 : 0]  opc;
        reg [BW - 1 : 0] bidx;
        reg is_jal, is_jalr, is_br, is_call, is_ret, bht_taken;
        reg [RA : 0] hprev;
        reg pt_seen;
        begin
            // B1) 握手: 到达地址 (m_pc_prev) == exp_pc; 批寄存器空或本拍被发射则可接收;
            //     halt 冻结 (不接收); 到达即所求却因满被丢弃 → rewind (pc 回退重取)
            m_arr  = (m_pc_prev == m_exp);
            m_capok = (m_fvalid == {IW{1'b0}}) || ((m_fvalid != {IW{1'b0}}) && !stall);
            // imem_valid: 数据未回时 inst_data 是旧值 → 不得接收, 也不得回退 (与 DUT 的 cap_w/rewind_w 一致)
            m_cap  = m_arr && m_capok && !halt && imem_valid;
            m_rew  = m_arr && !m_capok && !halt && imem_valid;
            m_fok  = m_cap && !redirect_valid && !halt;   // DUT 的 fetch_ok: ras ops 仅此拍非 0
            // 与 DUT 的 pred_ok_w 同步: 非期望批 (重定向后 1 拍 / 预测跳转后 1 拍 / stall 重复读出)
            // 的陈旧指令不得用其预测改写 pc (否则 pc 被劫持, 与 exp_pc 永久失步)
            // ★ 数据迟到 (imem_valid=0) 时 inst_data 同样是陈旧值, 同款门控
            m_predok = m_arr && !halt && imem_valid;
            // B2) 逐槽串行链 (低槽先定): head 链 → 预测/目标 → RAS op → 下一槽 head
            //     RAS op 只在"接收拍 + 首个预测跳转及之前"驱动 (截断后的槽是错误路径, 不动 RAS);
            //     预测/目标每槽都算 (DUT 亦然), 但 PC/exp 只跟随首个预测跳转
            m_h[0 * (RA + 1) +: (RA + 1)] = {1'b0, m_head};
            m_ptc = 1'b0; m_flow = 32'd0; pt_seen = 1'b0;
            for (li = 0; li < IW; li = li + 1) begin
                raw   = inst_data[li * 32 +: 32];
                pc_i  = m_pc_prev + 32'd4 * li;
                opc   = raw[6 : 0];
                hprev = m_h[li * (RA + 1) +: (RA + 1)];
                is_jal  = (opc == 7'b1101111);
                is_jalr = (opc == 7'b1100111);
                is_br   = (opc == 7'b1100011);
                is_call = is_jal && (raw[11 : 7] == 5'd1);
                is_ret  = is_jalr && (raw[11 : 7] == 5'd0) && (raw[19 : 15] == 5'd1);
                imm_b = {{20{raw[31]}}, raw[7], raw[30 : 25], raw[11 : 8], 1'b0};
                imm_j = {{12{raw[31]}}, raw[19 : 12], raw[20], raw[30 : 21], 1'b0};
                bidx  = (pc_i >> 2) % BHT;
                topv  = (hprev == {RA + 1{1'b0}}) ? 32'd0 : m_stack[hprev[RA - 1 : 0] - 1'b1];
                m_ptaken[li] = is_jal || (is_br && m_bht[bidx][1]) || is_ret;
                m_ptarget[li * 32 +: 32] = is_jal ? (pc_i + imm_j)
                                         : is_br ? (pc_i + imm_b)
                                         : is_ret ? topv
                                         : (pc_i + 32'd4);
                m_snap[li * RA +: RA] = hprev[RA - 1 : 0];
                m_top[li * 32 +: 32]  = topv;
                if (m_ptaken[li] && !m_ptc) begin       // 首个预测跳转决定 PC/exp
                    m_ptc  = 1'b1;
                    m_flow = m_ptarget[li * 32 +: 32];
                end
                m_push_ok[li] = m_fok && !pt_seen && is_call && (hprev != (RAS - 1));
                m_rops_ok[li] = m_push_ok[li];          // = 实际栈写
                m_rpv[li * 32 +: 32] = pc_i + 32'd4;
                if (m_push_ok[li])
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev + 1'b1;
                else if (m_fok && !pt_seen && is_ret && (hprev != {RA + 1{1'b0}}))
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev - 1'b1;
                else
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev;
                pt_seen = pt_seen || m_ptaken[li];
            end
        end
    endtask

    // ---- 模型推进一拍 (在 posedge 之后调用: 先应用上一拍组合量的时序效果, 再算本拍组合量) ----
    task model_step;
        integer li;
        reg pt;
        begin
            // ---- A) posedge 生效的时序更新 ----
            // A1) 批寄存器: redirect 清 > 接收 > 已发射清 > 保持
            if (redirect_valid) begin
                m_fvalid = {IW{1'b0}};
            end else if (m_cap) begin
                m_fraw = inst_data;                     // 到达数据 (上一拍地址的字)
                for (li = 0; li < IW; li = li + 1)
                    m_fpc[li * 32 +: 32] = m_pc_prev + 32'd4 * li;   // = 上一拍 imem_addr_d
                m_ftaken  = m_ptaken;
                m_ftarget = m_ptarget;
                m_fras    = m_snap;
                pt = 1'b0;
                for (li = 0; li < IW; li = li + 1) begin
                    m_fvalid[li] = !pt;                 // 批内首个预测跳转之后截断
                    pt = pt || m_ptaken[li];
                end
            end else if (m_fvalid != {IW{1'b0}} && !stall) begin
                m_fvalid = {IW{1'b0}};                  // 本拍批已发射
            end
            // A2) exp_pc 推进
            if (redirect_valid)   m_exp = redirect_pc;
            else if (m_cap)       m_exp = m_ptc ? m_flow : (m_exp + 32'd4 * IW);
            // A3) PC 推进 + 地址延迟 (m_pc_prev 更新后 imem 数据随之切换到本拍地址)
            //     预测目标优先于 stall 保持: 到达批被接收时 exp_pc 已跳到其目标, pc 必须跟随,
            //     否则 pc 之后只顺序推进, 到达流再也追不上 exp_pc = 永久失步 (F14)
            m_pc_prev = m_pc;
            // 数据没回来 → 不推进 pc (DUT 的 hold_w); redirect 不受此约束 (重定向必须随时能改 pc)
            m_pc = (!imem_valid && !redirect_valid && !halt) ? m_pc
                 : redirect_valid ? redirect_pc
                 : m_rew ? m_exp                    // 满批丢弃 → 回退到待交付批重取
                 : (m_predok && m_ptc) ? m_flow
                 : (stall || halt) ? m_pc : (m_pc + 32'd4 * IW);
            // A4) ras: restore > 本拍 ops (ops 为上一拍门控后的结果)
            if (ras_restore_valid) begin
                m_head = ras_restore_head;
            end else begin
                for (li = 0; li < IW; li = li + 1)
                    if (m_rops_ok[li])
                        m_stack[m_h[li * (RA + 1) +: RA]] = m_rpv[li * 32 +: 32];
                m_head = m_h[IW * (RA + 1) +: RA];
            end
            // A5) bht 更新 (新值基于旧值快照, 正序应用 → 同索引高槽 (更年轻) 覆盖)
            for (li = 0; li < IW; li = li + 1)
                if (bht_upd_req[li])
                    m_nv[li * 2 +: 2] = bht_upd_taken[li]
                                      ? ((m_bht[bht_upd_idx[li * BW +: BW]] < 2'b11)
                                         ? (m_bht[bht_upd_idx[li * BW +: BW]] + 2'd1)
                                         : m_bht[bht_upd_idx[li * BW +: BW]])
                                      : ((m_bht[bht_upd_idx[li * BW +: BW]] > 2'b00)
                                         ? (m_bht[bht_upd_idx[li * BW +: BW]] - 2'd1)
                                         : m_bht[bht_upd_idx[li * BW +: BW]]);
            for (li = 0; li < IW; li = li + 1)
                if (bht_upd_req[li])
                    m_bht[bht_upd_idx[li * BW +: BW]] = m_nv[li * 2 +: 2];

            // ---- B) 本拍组合量 (到达判定/预测/ras 链, 见 model_comb) ----
            model_comb;
        end
    endtask

    // ---- 检查: 组合输出 + 批输出 + bht/ras 状态 + 批内 pc 连续性 ----
    task check_all;
        integer li, bad;
        begin
            bad = 0;
            if (dut.pc_r !== m_pc) begin
                $display("FAIL: pc_r = %h expect %h (t=%0t)", dut.pc_r, m_pc, $time);
                bad = bad + 1;
            end
            if (dut.exp_pc_r !== m_exp) begin
                $display("FAIL: exp_pc_r = %h expect %h (t=%0t)", dut.exp_pc_r, m_exp, $time);
                bad = bad + 1;
            end
            for (li = 0; li < IW; li = li + 1)
                if (imem_addr[li * 32 +: 32] !== (m_pc + 32'd4 * li)) begin
                    $display("FAIL: imem_addr[%0d] = %h expect %h", li,
                             imem_addr[li * 32 +: 32], m_pc + 32'd4 * li);
                    bad = bad + 1;
                end
            if (f2i_valid !== m_fvalid) begin
                $display("FAIL: f2i_valid = %b expect %b", f2i_valid, m_fvalid);
                bad = bad + 1;
            end
            for (li = 0; li < IW; li = li + 1) begin
                if (f2i_raw[li * 32 +: 32] !== m_fraw[li * 32 +: 32]
                 || f2i_pc[li * 32 +: 32] !== m_fpc[li * 32 +: 32]
                 || f2i_pred_taken[li] !== m_ftaken[li]
                 || f2i_pred_target[li * 32 +: 32] !== m_ftarget[li * 32 +: 32]
                 || f2i_ras_snap[li * RA +: RA] !== m_fras[li * RA +: RA]) begin
                    $display("FAIL: f2i[%0d] mismatch (t=%0t)", li, $time);
                    if (f2i_raw[li * 32 +: 32] !== m_fraw[li * 32 +: 32]) $display("   raw %h != %h", f2i_raw[li * 32 +: 32], m_fraw[li * 32 +: 32]);
                    if (f2i_pc[li * 32 +: 32] !== m_fpc[li * 32 +: 32]) $display("   pc %h != %h", f2i_pc[li * 32 +: 32], m_fpc[li * 32 +: 32]);
                    if (f2i_pred_taken[li] !== m_ftaken[li]) $display("   taken %b != %b", f2i_pred_taken[li], m_ftaken[li]);
                    if (f2i_pred_target[li * 32 +: 32] !== m_ftarget[li * 32 +: 32]) $display("   target %h != %h", f2i_pred_target[li * 32 +: 32], m_ftarget[li * 32 +: 32]);
                    if (f2i_ras_snap[li * RA +: RA] !== m_fras[li * RA +: RA]) $display("   ras %h != %h", f2i_ras_snap[li * RA +: RA], m_fras[li * RA +: RA]);
                    bad = bad + 1;
                end
                // 批内 pc 必须逐槽 +4 (抓地址错位类缺陷)
                if (m_fvalid[li] && (f2i_pc[li * 32 +: 32] !== (f2i_pc[0 * 32 +: 32] + 32'd4 * li))) begin
                    $display("FAIL: batch pc[%0d] = %h not base+%0d*4 (base %h)", li,
                             f2i_pc[li * 32 +: 32], li, f2i_pc[0 * 32 +: 32]);
                    bad = bad + 1;
                end
            end
            for (li = 0; li < BHT; li = li + 1)
                if (dut.u_bht.counters_r[li] !== m_bht[li]) begin
                    $display("FAIL: bht[%0d] = %b expect %b", li,
                             dut.u_bht.counters_r[li], m_bht[li]);
                    bad = bad + 1;
                end
            if (dut.u_ras.head_r !== m_head) begin
                $display("FAIL: ras head = %0d expect %0d", dut.u_ras.head_r, m_head);
                bad = bad + 1;
            end
            for (li = 0; li < IW; li = li + 1) begin
                if (dut.u_ras.head_snap[li * RA +: RA] !== m_snap[li * RA +: RA]) begin
                    $display("FAIL: head_snap[%0d]", li);
                    bad = bad + 1;
                end
                if (dut.u_ras.top[li * 32 +: 32] !== m_top[li * 32 +: 32]) begin
                    $display("FAIL: ras top[%0d] = %h expect %h", li,
                             dut.u_ras.top[li * 32 +: 32], m_top[li * 32 +: 32]);
                    bad = bad + 1;
                end
            end
            errors = errors + bad;
        end
    endtask

    // ---- 推进一拍: 到 posedge (本拍激励此时已稳定) → 采样组合量 → 应用时序 → 逐项断言 ----
    // 组合量必须在 posedge 时刻采样: DUT 正是在此刻用 stall/redirect/halt 决定是否接收,
    // 若提前到上一拍 posedge 之后算, 本拍中途才施加的激励 (如 stall=1) 就看不到
    task tick;
        begin
            @(posedge clk);
            model_comb;
            #1;
            model_step;
            check_all;
        end
    endtask

    // ---- 断言当前批: valid 全 1 且 pc 自 base 起逐槽 +4 ----
    task expect_batch;
        input [31 : 0] base;
        integer li2;
        begin
            if (f2i_valid !== {IW{1'b1}}) begin
                $display("FAIL: expect batch @%h but valid=%b (t=%0t)", base, f2i_valid, $time);
                errors = errors + 1;
            end else
                for (li2 = 0; li2 < IW; li2 = li2 + 1)
                    if (f2i_pc[li2 * 32 +: 32] !== (base + 32'd4 * li2)) begin
                        $display("FAIL: expect batch @%h but pc[%0d]=%h", base, li2,
                                 f2i_pc[li2 * 32 +: 32]);
                        errors = errors + 1;
                    end
        end
    endtask

    // ---- 取指直到批首地址 == addr (最多 maxn 拍); 超时报错 ----
    task fetch_until;
        input [31 : 0] addr;
        input integer  maxn;
        integer n;
        begin
            n = 0;
            while ((n < maxn) && !((f2i_valid[0] === 1'b1) && (f2i_pc[31 : 0] === addr))) begin
                tick();
                n = n + 1;
            end
            if (!((f2i_valid[0] === 1'b1) && (f2i_pc[31 : 0] === addr))) begin
                $display("FAIL: address %h not delivered within %0d cycles (pc=%h exp=%h)",
                         addr, maxn, dut.pc_r, dut.exp_pc_r);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/front/tb_fetch.vcd");
        $dumpvars(0, tb_fetch);

        m_pc = 0;
        m_pc_prev = 0;
        m_exp = 0;
        m_fvalid = 0; m_fraw = 0; m_fpc = 0; m_ftaken = 0; m_ftarget = 0; m_fras = 0;
        m_cap = 0; m_ptc = 0; m_flow = 0; m_rops_ok = 0; m_rpv = 0;
        m_arr = 0; m_capok = 0; m_rew = 0; m_fok = 0;
        m_ptaken = 0; m_ptarget = 0; m_push_ok = 0; m_snap = 0; m_top = 0;
        for (i = 0; i < BHT; i = i + 1) m_bht[i] = 2'b01;
        for (i = 0; i < RAS; i = i + 1) m_stack[i] = 0;
        for (i = 0; i < IMEM_N; i = i + 1) imem[i] = NOP;
        m_head = 0;
        m_h = 0;

        clr_all();
        #23 rst_n = 1;
        #1;   // 第一个 posedge 之前: 求出复位拍的组合量 (供 F1 断言 ras/head_snap), 首个 tick 会重算
        model_comb;         // 复位期间 memory 已在读地址 0 → 首拍即交付批 0..4W-4

        // F1 复位: PC=0 (imem_addr=0,4,8,C), 无批输出, exp_pc=0
        check_all();
        if ((imem_addr[0 * 32 +: 32] !== 32'd0) || (f2i_valid !== {IW{1'b0}})
         || (dut.pc_r !== 32'd0) || (dut.exp_pc_r !== 32'd0)) begin
            $display("FAIL: F1 reset"); errors = errors + 1;
        end else begin
            $display("PASS: F1 reset");
        end

        // F2 顺序取指: 复位拍 memory 已在读地址 0 → 首拍即交付批 0/4/8/C (无请求延迟)
        tick();
        expect_batch(32'h0);
        if ((f2i_pred_taken !== {IW{1'b0}}) || (dut.pc_r !== 32'd16)) begin
            $display("FAIL: F2 first batch 0..12"); errors = errors + 1;
        end else begin
            $display("PASS: F2 first batch 0..12");
        end
        // 该批本拍被发射 → 次拍批寄存器空 (memory 读 1 拍 + 批寄存 1 拍的交付延迟)
        tick();
        if ((f2i_valid !== {IW{1'b0}}) || (dut.pc_r !== 32'd32)) begin
            $display("FAIL: F2b issued batch cleared"); errors = errors + 1;
        end else begin
            $display("PASS: F2b issued batch cleared");
        end
        // 稳态: 每拍交付一批, PC 恒领先交付批 2 批 (= 32)
        fetch_until(32'h10, 4);
        expect_batch(32'h10);
        if (dut.pc_r !== 32'd48) begin
            $display("FAIL: F2c steady pc=%h (expect 30)", dut.pc_r); errors = errors + 1;
        end else begin
            $display("PASS: F2c steady state one batch per cycle");
        end

        // F3 stall: 批保持; 到达的正是 exp_pc 却因满被丢弃 → pc 回退到 exp_pc 并停住,
        //   此后 memory 每拍重复读出 exp_pc (stall 期间不发起新请求)
        clr_all();
        stall = 1'b1;
        tick();
        saved_pc  = f2i_pc[31 : 0];              // 批 (保持不动)
        saved_pcr = dut.pc_r;                    // 已回退到 exp_pc
        if ((dut.pc_r !== dut.exp_pc_r) || (dut.pc_r !== saved_pcr)) begin
            $display("FAIL: F3 stall rewind (pc=%h exp=%h)", dut.pc_r, dut.exp_pc_r);
            errors = errors + 1;
        end
        tick();
        if ((f2i_pc[31 : 0] !== saved_pc) || (dut.pc_r !== saved_pcr)
         || (dut.exp_pc_r !== saved_pcr) || (imem_addr[0 * 32 +: 32] !== saved_pcr)) begin
            $display("FAIL: F3 stall (%h/%h exp=%h)", f2i_pc[31 : 0], dut.pc_r, dut.exp_pc_r);
            errors = errors + 1;
        end else begin
            $display("PASS: F3 stall rewinds pc to exp_pc and keeps batch");
        end
        // 撤 stall: 被回退重取的 exp_pc 批到达 → 立即接收 (批内基址 = 回退后的 pc)
        clr_all();
        tick();
        if ((f2i_valid !== {IW{1'b1}}) || (f2i_pc[31 : 0] !== saved_pcr)) begin
            $display("FAIL: F3b stall release (%b @%h)", f2i_valid, f2i_pc[31 : 0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F3b stall release delivers the re-fetched batch");
        end

        // F4 redirect: 清批 + 改 PC/exp_pc
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h100;
        tick();
        if ((imem_addr[0 * 32 +: 32] !== 32'h100) || (f2i_valid !== {IW{1'b0}})
         || (dut.exp_pc_r !== 32'h100)) begin
            $display("FAIL: F4 redirect"); errors = errors + 1;
        end else begin
            $display("PASS: F4 redirect clears batch");
        end

        // F5 halt: PC 停 (halt 与 stall 同拍拉高, 与 cpu_top 的 fetch_stall 一致)
        clr_all();
        halt = 1'b1; stall = 1'b1;
        tick();
        saved_pc  = f2i_pc[31 : 0];
        saved_pcr = dut.pc_r;
        tick();
        if ((f2i_pc[31 : 0] !== saved_pc) || (dut.pc_r !== saved_pcr)
         || (imem_addr[0 * 32 +: 32] !== saved_pcr)) begin
            $display("FAIL: F5 halt"); errors = errors + 1;
        end else begin
            $display("PASS: F5 halt stops fetch");
        end
        // F4b: 重定向后目标批在少数拍内交付 (restart 供后续 F6 使用)
        clr_all();
        fetch_until(32'h100, 6);
        if ((f2i_valid !== {IW{1'b1}}) || (f2i_pc[31 : 0] !== 32'h100)) begin
            $display("FAIL: F4b redirect target (%b @%h)", f2i_valid, f2i_pc[31 : 0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F4b redirect target delivered");
        end

        // F6 jal 预测: 0x10C 槽 3 jal rd=0 imm=8 → taken, target=0x10C+8=0x114
        imem[8'h43] = jal_enc(5'd0, 32'd8);         // 0x10C>>2 = 0x43
        redirect_valid = 1'b1; redirect_pc = 32'h100;
        tick();
        clr_all();
        fetch_until(32'h100, 8);
        if ((f2i_pred_taken[3] !== 1'b1)
         || (f2i_pred_target[3 * 32 +: 32] !== 32'h114)
         || (f2i_pred_taken[0] !== 1'b0)) begin
            $display("FAIL: F6 jal predict (v=%b t=%b tgt=%h exp_pc=%h)",
                     f2i_valid, f2i_pred_taken, f2i_pred_target[3 * 32 +: 32], dut.exp_pc_r);
            errors = errors + 1;
        end else begin
            $display("PASS: F6 jal always taken");
        end
        imem[8'h43] = NOP;
        // F6b/F6c: PC 在跳转批"到达拍"即跟随目标 (批交付同拍), 且批内跳转之后截断
        imem[8'h50 + 1] = jal_enc(5'd0, 32'd16);     // 0x140 槽 1 → target 0x144+16=0x154
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h140;
        tick();
        clr_all();
        fetch_until(32'h140, 8);
        if (dut.pc_r !== 32'h154) begin
            $display("FAIL: F6b pc follows jal target (%h)", dut.pc_r); errors = errors + 1;
        end else begin
            $display("PASS: F6b pc follows jal target");
        end
        if (f2i_valid !== 4'b0011) begin
            $display("FAIL: F6c batch truncation (%b)", f2i_valid); errors = errors + 1;
        end else begin
            $display("PASS: F6c batch truncated after predicted jump");
        end
        imem[8'h50 + 1] = NOP;
        clr_all();

        // F7 call/ret: 0x114 槽 1 call (rd=x1 imm=8) → 目标 0x11C, push 0x118
        //   批内截断 (valid=0011) 且 push 与接收同拍生效 (ras ops 只在接收拍驱动)
        imem[8'h45] = jal_enc(5'd1, 32'd8);          // 0x114>>2 = 0x45
        imem[8'h47] = jalr_enc(5'd0, 5'd1, 32'd0);   // 0x11C: ret (x1 → 回 0x118)
        redirect_valid = 1'b1; redirect_pc = 32'h110;
        tick();
        clr_all();
        fetch_until(32'h110, 8);
        if ((f2i_valid !== 4'b0011) || (f2i_pred_taken[1] !== 1'b1)
         || (f2i_pred_target[1 * 32 +: 32] !== 32'h11C)
         || (dut.u_ras.head_r !== 3'd1) || (dut.u_ras.stack[0] !== 32'h118)) begin
            $display("FAIL: F7a call push (valid=%b head=%0d stack0=%h)",
                     f2i_valid, dut.u_ras.head_r, dut.u_ras.stack[0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F7a call pushes pc+4");
        end
        // F7b: 0x11C 批槽 0 是 ret → 预测目标 = 栈顶 0x118, 接收拍弹栈 (head 回 0)
        fetch_until(32'h11C, 8);
        if ((f2i_pred_taken[0] !== 1'b1) || (f2i_pred_target[0 * 32 +: 32] !== 32'h118)
         || (dut.u_ras.head_r !== 3'd0)) begin
            $display("FAIL: F7b ret pop (%h head=%0d)", f2i_pred_target[0 * 32 +: 32], dut.u_ras.head_r);
            errors = errors + 1;
        end else begin
            $display("PASS: F7b ret predicts ras top and pops");
        end
        imem[8'h45] = NOP; imem[8'h47] = NOP;
        clr_all();

        // F8 空栈 ret 忽略: head=0 → 目标 0
        imem[8'h4C] = jalr_enc(5'd0, 5'd1, 32'd0);    // 0x130
        redirect_valid = 1'b1; redirect_pc = 32'h130;
        tick();
        clr_all();
        fetch_until(32'h130, 8);
        if (f2i_pred_target[0 * 32 +: 32] !== 32'h0) begin
            $display("FAIL: F8 empty ras pop (%h)", f2i_pred_target[0 * 32 +: 32]); errors = errors + 1;
        end else begin
            $display("PASS: F8 empty ras pop predicts 0");
        end
        imem[8'h4C] = NOP;
        clr_all();

        // F9a 弱不取: 分支 (idx=(0x200>>2)%32=0, counters=01) → 不预测
        imem[8'h80] = b_enc(5'd1, 5'd2, 32'd16);     // 0x200
        redirect_valid = 1'b1; redirect_pc = 32'h200;
        tick();
        clr_all();
        fetch_until(32'h200, 8);
        if (f2i_pred_taken[0] !== 1'b0) begin
            $display("FAIL: F9a weak not-taken"); errors = errors + 1;
        end else begin
            $display("PASS: F9a weak not-taken");
        end
        tick();                                      // 批发射, 走顺序路径 (0x210)
        imem[8'h80] = b_enc(5'd1, 5'd2, 32'd16);
        // F9b BHT 更新: idx=0 taken → 01→10
        clr_all();
        bht_upd_req = 4'b0001; bht_upd_idx[0 * BW +: BW] = 5'd0;
        bht_upd_taken = 4'b0001;
        tick();
        if (dut.u_bht.counters_r[0] !== 2'b10) begin
            $display("FAIL: F9b bht update (%b)", dut.u_bht.counters_r[0]); errors = errors + 1;
        end else begin
            $display("PASS: F9b bht saturate to strong taken");
        end
        // F9c 强取: 同地址再取 → taken, target=0x200+16=0x210
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h200;
        tick();
        clr_all();
        fetch_until(32'h200, 8);
        if ((f2i_pred_taken[0] !== 1'b1)
         || (f2i_pred_target[0 * 32 +: 32] !== 32'h210) || (dut.pc_r !== 32'h210)) begin
            $display("FAIL: F9c strong taken (%h)", f2i_pred_target[0 * 32 +: 32]); errors = errors + 1;
        end else begin
            $display("PASS: F9c strong taken");
        end
        imem[8'h80] = NOP;
        clr_all();

        // F10 同索引多槽: 4 槽同 idx, 旧值 01; 槽 0 not-taken(→00), 槽 1..3 taken(→10)
        // 正序应用 + 各槽新值基于旧值快照 → 高槽 (更年轻) 最后写, 结果 = 10
        clr_all();
        bht_upd_req = 4'b1111; bht_upd_idx = {5'd6, 5'd6, 5'd6, 5'd6};
        bht_upd_taken = 4'b1110;
        tick();
        if (dut.u_bht.counters_r[6] !== 2'b10) begin
            $display("FAIL: F10 same-idx high slot wins (%b)", dut.u_bht.counters_r[6]); errors = errors + 1;
        end else begin
            $display("PASS: F10 same-index update high slot wins");
        end

        // F11 满栈 push 丢弃: head 宽度 RA 位 → 满栈 = 7 (= RAS_SIZE-1), 第 8 次 push 丢弃
        clr_all();
        for (i = 0; i < 8; i = i + 1) begin
            imem[(32'h300 >> 2) + 3] = jal_enc(5'd1, 32'd4);
            redirect_valid = 1'b1; redirect_pc = 32'h300;
            tick();
            clr_all();
            fetch_until(32'h300, 8);
            tick();
        end
        if (dut.u_ras.head_r !== 3'd7) begin
            $display("FAIL: F11 full push drop (%0d)", dut.u_ras.head_r); errors = errors + 1;
        end else begin
            $display("PASS: F11 full ras drops push");
        end
        imem[(32'h300 >> 2) + 3] = NOP;
        // F11b 满栈期再来一个 call (不同地址, push 值 0x324 ≠ 栈内容) → 丢弃: head 仍 7 且不写栈
        imem[8'hC8] = jal_enc(5'd1, 32'd4);          // 0x320
        redirect_valid = 1'b1; redirect_pc = 32'h320;
        tick();
        clr_all();
        fetch_until(32'h320, 8);
        if ((dut.u_ras.head_r !== 3'd7) || (dut.u_ras.stack[0] !== 32'h310)) begin
            $display("FAIL: F11b full push drop (head=%0d stack0=%h)", dut.u_ras.head_r, dut.u_ras.stack[0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F11b full ras drops push without writing");
        end
        imem[8'hC8] = NOP;
        // 栈满, 恢复 head 到 0 后再测批内链
        ras_restore_valid = 1'b1; ras_restore_head = 3'd0;
        tick();
        clr_all();

        // F12 批内链: call,ret,call → head_snap 0,1,0,1 (模型对照)
        clr_all();
        imem[8'hC0] = jal_enc(5'd1, 32'd4);          // 0x300
        imem[8'hC1] = jalr_enc(5'd0, 5'd1, 32'd0);
        imem[8'hC2] = jal_enc(5'd1, 32'd4);
        imem[8'hC3] = NOP;
        redirect_valid = 1'b1; redirect_pc = 32'h300;
        tick();
        clr_all();
        fetch_until(32'h300, 8);
        if ((f2i_ras_snap[0 * RA +: RA] !== 3'd0)
         || (f2i_ras_snap[1 * RA +: RA] !== 3'd1)
         || (f2i_pred_taken[1] !== 1'b1)) begin
            $display("FAIL: F12 batch chain (%h %h)", f2i_ras_snap[0 * RA +: RA], f2i_ras_snap[1 * RA +: RA]);
            errors = errors + 1;
        end else begin
            $display("PASS: F12 batch call/ret/call chain");
        end
        imem[8'hC0] = NOP; imem[8'hC1] = NOP; imem[8'hC2] = NOP;
        clr_all();

        // F13 restore: 误预测恢复 head
        ras_restore_valid = 1'b1; ras_restore_head = 3'd5;
        tick();
        if (dut.u_ras.head_r !== 3'd5) begin
            $display("FAIL: F13 restore (%0d)", dut.u_ras.head_r); errors = errors + 1;
        end else begin
            $display("PASS: F13 ras restore head");
        end
        clr_all();
        tick();

        // F14 接收拍 stall (批寄存器空) + 到达批内有预测跳转: exp_pc 推进到跳转目标, pc 必须同拍跟随,
        //   否则 pc 只做顺序推进而 exp_pc 停在目标上 → 到达地址流再也追不上 exp_pc = 永久失步
        //   (cpu_top 冲刷期正是此场景: flushing_r 使 stall=1, 若重定向目标是 jal/ret 且批寄存器已空,
        //    该批会被接收且 exp_pc 跳到目标, 而旧实现让 pc 停在原地 → 取指跑飞)
        imem[8'hC0] = jal_enc(5'd0, -32'd16);        // 0x300: 回跳 -16 → 目标 0x2F0 (不在顺序路径上)
        clr_all();
        stall = 1'b1;                                 // 与冲刷期 fetch_stall 一致
        redirect_valid = 1'b1; redirect_pc = 32'h300;
        tick();                                       // 重定向沿: pc/exp_pc ← 0x300, 批清空
        redirect_valid = 1'b0;
        tick();                                       // 到达旧地址 ≠ exp_pc → 不接收 (批仍空)
        tick();                                       // 到达 0x300 == exp_pc 且批空 → 接收 (stall 中)
        if ((dut.exp_pc_r !== 32'h2F0) || (dut.pc_r !== 32'h2F0)) begin
            $display("FAIL: F14 stall-capture taken jump (pc=%h exp=%h)", dut.pc_r, dut.exp_pc_r);
            errors = errors + 1;
        end else begin
            $display("PASS: F14 capture during stall still follows predicted target");
        end
        clr_all();
        fetch_until(32'h2F0, 8);                      // 失步则目标批永远交付不了
        if ((f2i_valid !== {IW{1'b1}}) || (f2i_pc[31 : 0] !== 32'h2F0)) begin
            $display("FAIL: F14b target batch after stall capture (%b @%h)", f2i_valid, f2i_pc[31 : 0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F14b target batch delivered after stall capture");
        end
        // F15 变长取指延迟 (imem_valid): 数据没回来的拍 pc/exp_pc/地址/批输出必须全冻结,
        //   且总线上那条陈旧指令 (STALE) 不得改写 pc、不得误 push RAS、不得被当成到达批接收。
        //   固定 1 拍存储下 imem_valid 恒 1, 上面所有用例都碰不到这条路径。
        //   场景刻意做成"地址已对上、数据仍是旧的": 重定向到 0x300 后全程不给数据, 于是 imem_addr_d
        //   很快追上 exp_pc (arr_ok=1) 而 imem_valid 仍为 0 —— 正是 pred_ok_w 门控失误会暴露的那一拍
        for (i = 8'hC0; i <= 8'hFF; i = i + 1) imem[i] = NOP;   // 0x300 起 NOP 滑道
        clr_all();
        imem_valid = 1'b0;
        redirect_valid = 1'b1; redirect_pc = 32'h300;
        tick();                                        // 重定向不受 hold 约束: pc/exp_pc 立刻跟随
        redirect_valid = 1'b0;
        if ((dut.pc_r !== 32'h300) || (dut.exp_pc_r !== 32'h300) || (f2i_valid !== {IW{1'b0}})) begin
            $display("FAIL: F15a redirect during imem_valid=0 (pc=%h exp=%h valid=%b)",
                     dut.pc_r, dut.exp_pc_r, f2i_valid);
            errors = errors + 1;
        end else begin
            $display("PASS: F15a redirect takes effect while imem data is late");
        end
        saved_pc = dut.pc_r; saved_pcr = dut.exp_pc_r;
        saved_addr = imem_addr[31 : 0]; saved_ras = dut.u_ras.head_r;
        for (k = 0; k < 3; k = k + 1) begin
            tick();                                    // 迟到拍: 不接收/不推进/不回退/不动 RAS
            if ((dut.pc_r !== saved_pc) || (dut.exp_pc_r !== saved_pcr)
             || (imem_addr[31 : 0] !== saved_addr) || (f2i_valid !== {IW{1'b0}})
             || (dut.u_ras.head_r !== saved_ras)) begin
                $display("FAIL: F15b moved while imem_valid=0 (pc=%h exp=%h addr=%h valid=%b ras=%0d)",
                         dut.pc_r, dut.exp_pc_r, imem_addr[31 : 0], f2i_valid, dut.u_ras.head_r);
                errors = errors + 1;
            end
        end
        if (dut.arr_ok_w !== 1'b1) begin               // 断言用例确实打在要害上 (地址已对/数据是旧的)
            $display("FAIL: F15 case not exercising stale-data path (arr_ok=%b)", dut.arr_ok_w);
            errors = errors + 1;
        end else begin
            $display("PASS: F15b frozen while data late (arr_ok=1, stale word on bus)");
        end
        imem_valid = 1'b1;                             // 数据回来: 地址已对上, 下一拍即交付
        tick();
        if ((f2i_valid !== {IW{1'b1}}) || (f2i_pc[31 : 0] !== 32'h300)) begin
            $display("FAIL: F15c batch not delivered after data returns (%b @%h)",
                     f2i_valid, f2i_pc[31 : 0]);
            errors = errors + 1;
        end else begin
            $display("PASS: F15c batch delivered once data returns");
        end
        imem[8'hC0] = NOP;
        clr_all();
        tick();

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer i2, k2, rsel;
            for (i2 = 0; i2 < 300; i2 = i2 + 1) begin
                clr_all();
                for (k2 = 0; k2 < IW; k2 = k2 + 1) begin
                    rsel = {$random} % 10;
                    imem[((m_pc + 32'd4 * k2) >> 2) % IMEM_N]
                        = (rsel == 0) ? jal_enc({$random} % 32, rnd_imm4(512))
                        : (rsel == 1) ? jalr_enc({$random} % 32, {$random} % 32, rnd_imm4(512))
                        : (rsel == 2) ? b_enc({$random} % 32, {$random} % 32, rnd_imm4(512))
                        : NOP;
                end
                if (({$random} % 8) == 0) stall = 1'b1;
                if (({$random} % 12) == 0) begin
                    redirect_valid = 1'b1; redirect_pc = rnd_imm4(512);
                end
                if (({$random} % 30) == 0) halt = 1'b1;
                if (({$random} % 6) == 0) imem_valid = 1'b0;   // 变长取指延迟: 数据迟到
                for (k2 = 0; k2 < IW; k2 = k2 + 1) begin
                    bht_upd_req[k2] = (({$random} % 5) == 0);
                    bht_upd_idx[k2 * BW +: BW] = {$random} % BHT;
                    bht_upd_taken[k2] = {$random} & 1;
                end
                if (({$random} % 10) == 0) begin
                    ras_restore_valid = 1'b1; ras_restore_head = {$random} % RAS;
                end
                tick();
            end
        end

        if (errors == 0) begin
            $display("LARGE TESTS PASSED (300 cycles)");
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end
endmodule
