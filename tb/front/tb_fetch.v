// tb_fetch: 段 1 小规模+极端 (PC 顺序推进/stall 保持/redirect 清批/halt 停取指/
//        jal 恒 taken/BHT 弱取判定与饱和更新/call-push ret-pop 链/满 push 丢 空 pop 忽略/
//        RAS restore/同索引 BHT 低槽赢);
//        段 2 随机模型对照 (300 拍, PC/批输出/counters/top/head_snap 逐拍断言)
`timescale 1ns/1ps
module tb_fetch;
    localparam IW  = 4;
    localparam BHT = 32;
    localparam RAS = 8;
    localparam RA  = 3;
    localparam BW  = 5;

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
    reg  [IW * 32 - 1 : 0] inst_data;
    reg                 stall, redirect_valid, halt;
    reg  [31 : 0]         redirect_pc;

    fetch #(.ISSUE_WIDTH(IW), .BHT_SIZE(BHT), .RAS_SIZE(RAS)) dut (
        .clk(clk), .rst_n(rst_n),
        .f2i_valid(f2i_valid), .f2i_raw(f2i_raw), .f2i_pc(f2i_pc),
        .f2i_pred_taken(f2i_pred_taken), .f2i_pred_target(f2i_pred_target),
        .f2i_ras_snap(f2i_ras_snap), .imem_addr(imem_addr),
        .bht_upd_req(bht_upd_req), .bht_upd_idx(bht_upd_idx), .bht_upd_taken(bht_upd_taken),
        .ras_restore_valid(ras_restore_valid), .ras_restore_head(ras_restore_head),
        .inst_data(inst_data), .stall(stall),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc), .halt(halt)
    );

    integer errors = 0;
    integer i, j, k;

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

    // ---- 模型 ----
    // memory 同步读 1 拍: 批的 pc/预测基于"上一拍取指地址" (imem_addr_d),
    // 本拍地址由上一 tick 保存到 m_pc_prev; 复位后第一拍批不采样 (first_r)
    reg [31 : 0]     m_pc;
    reg [31 : 0]     m_pc_prev;
    reg              m_first;
    reg [1 : 0]      m_bht [0 : BHT - 1];
    reg [31 : 0]     m_stack [0 : RAS - 1];
    reg [RA - 1 : 0] m_head;
    reg [IW - 1 : 0]      m_fvalid;
    reg [IW * 32 - 1 : 0] m_fraw, m_fpc, m_ftarget;
    reg [IW - 1 : 0]      m_ftaken;
    reg [IW * RA - 1 : 0] m_fras;
    reg                   m_ptc;                 // 批内前缀 OR (预测 taken)
    reg [31 : 0]          m_flow;                // 流式目标 (最后一个 taken 槽)
    reg [(IW + 1) * (RA + 1) - 1 : 0] m_h;        // ras 链 (每拍重算)
    reg [IW - 1 : 0]      m_push_ok;
    reg [2 * IW - 1 : 0]  m_nv;                    // bht 每槽新值 (基于旧值快照)

    task clr_all;
        begin
            bht_upd_req = 0; bht_upd_idx = 0; bht_upd_taken = 0;
            ras_restore_valid = 0; ras_restore_head = 0;
            inst_data = 0; stall = 0; redirect_valid = 0; halt = 0;
            redirect_pc = 0;
        end
    endtask

    // 一拍: #1 → #8 posedge → #1 → 模型同步更新 → 检查 (组合 + 批输出)
    task tick;
        integer li;
        reg [RA : 0] hprev, hcur;
        reg [RA - 1 : 0] topi, sidx;
        reg [31 : 0] raw, pc_i, imm_b, imm_j, topv;
        reg [6 : 0]  opc;
        reg [BW - 1 : 0] bidx;
        reg is_push, is_pop, is_jal, is_jalr, is_br, is_call, is_ret;
        reg bht_taken, fetch_ok;
        begin
            #1;
            #8;
            #1;
            fetch_ok = !stall && !redirect_valid && !halt;
            // ---- 1) ras 链 (当前 ops = fetch 门控后的 call/ret) ----
            m_h[0 * (RA + 1) +: (RA + 1)] = {1'b0, m_head};
            for (li = 0; li < IW; li = li + 1) begin
                raw   = inst_data[li * 32 +: 32];
                hprev = m_h[li * (RA + 1) +: (RA + 1)];
                is_push = fetch_ok && (raw[6 : 0] == 7'b1101111)
                       && (raw[11 : 7] == 5'd1);
                is_pop  = fetch_ok && (raw[6 : 0] == 7'b1100111)
                       && (raw[11 : 7] == 5'd0)
                       && (raw[19 : 15] == 5'd1);
                m_push_ok[li] = is_push && (hprev != RAS[RA : 0]);
                if (is_push && (hprev != RAS[RA : 0]))
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev + 1'b1;
                else if (is_pop && (hprev != {RA + 1{1'b0}}))
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev - 1'b1;
                else
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev;
            end
            // ---- 2) 批状态 (采样拍) 与预测 (批地址 = 上一拍取指地址, 同 DUT);
            //         复位后第一拍不采样 (保持复位态) ----
            if (fetch_ok && !m_first) begin
                for (li = 0; li < IW; li = li + 1) begin
                    m_fraw[li * 32 +: 32]  = inst_data[li * 32 +: 32];
                    m_fpc[li * 32 +: 32]   = m_pc_prev + 32'd4 * li;
                    raw  = inst_data[li * 32 +: 32];
                    pc_i = m_pc_prev + 32'd4 * li;
                    opc  = raw[6 : 0];
                    is_jal  = (opc == 7'b1101111);
                    is_jalr = (opc == 7'b1100111);
                    is_br   = (opc == 7'b1100011);
                    is_call = is_jal && (raw[11 : 7] == 5'd1);
                    is_ret  = is_jalr && (raw[11 : 7] == 5'd0) && (raw[19 : 15] == 5'd1);
                    imm_b = {{20{raw[31]}}, raw[7], raw[30 : 25], raw[11 : 8], 1'b0};
                    imm_j = {{12{raw[31]}}, raw[19 : 12], raw[20], raw[30 : 21], 1'b0};
                    bidx = (pc_i >> 2) % BHT;
                    bht_taken = m_bht[bidx][1];
                    m_ftaken[li] = is_jal || (is_br && bht_taken) || is_ret;
                    hcur = m_h[li * (RA + 1) +: (RA + 1)];
                    topi = hcur[RA - 1 : 0] - 1'b1;
                    topv = (hcur == {RA + 1{1'b0}}) ? 32'd0 : m_stack[topi];
                    m_ftarget[li * 32 +: 32] = is_jal ? (pc_i + imm_j)
                                             : is_br ? (pc_i + imm_b)
                                             : is_ret ? topv
                                             : (pc_i + 32'd4);
                    m_fras[li * RA +: RA] = hcur[RA - 1 : 0];
                end
                // valid 截断: 批内首个预测跳转 (含) 之后无效
                m_ptc = 1'b0;
                for (li = 0; li < IW; li = li + 1) begin
                    m_fvalid[li] = !m_ptc;
                    m_ptc = m_ptc || m_ftaken[li];
                end
            end else if (stall || halt) begin
                // 批保持
            end else begin
                m_fvalid = {IW{1'b0}};
            end
            // ---- 3) ras 应用 (restore > ops; push 值 = 批地址 pc+4, 与取指同拍) ----
            if (ras_restore_valid) begin
                m_head = ras_restore_head;
            end else begin
                for (li = 0; li < IW; li = li + 1)
                    if (m_push_ok[li]) begin
                        sidx = m_h[li * (RA + 1) +: RA];
                        m_stack[sidx] = m_pc_prev + 32'd4 * li + 32'd4;
                    end
                m_head = m_h[IW * (RA + 1) +: RA];
            end
            // 保存本拍取指地址供下一 tick 的批地址使用 (memory 1 拍延迟)
            m_pc_prev = m_pc;
            m_first = 1'b0;
            // ---- 3b) 组合链用新 head 重新锚定 (posedge 后组合值, 检查用) ----
            m_h[0 * (RA + 1) +: (RA + 1)] = {1'b0, m_head};
            for (li = 0; li < IW; li = li + 1) begin
                raw   = inst_data[li * 32 +: 32];
                hprev = m_h[li * (RA + 1) +: (RA + 1)];
                is_push = fetch_ok && (raw[6 : 0] == 7'b1101111)
                       && (raw[11 : 7] == 5'd1);
                is_pop  = fetch_ok && (raw[6 : 0] == 7'b1100111)
                       && (raw[11 : 7] == 5'd0)
                       && (raw[19 : 15] == 5'd1);
                if (is_push && (hprev != RAS[RA : 0]))
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev + 1'b1;
                else if (is_pop && (hprev != {RA + 1{1'b0}}))
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev - 1'b1;
                else
                    m_h[(li + 1) * (RA + 1) +: (RA + 1)] = hprev;
            end
            // ---- 4) PC 更新 (跟随最后一个预测跳转目标) ----
            m_ptc = 1'b0; m_flow = 32'd0;
            for (li = 0; li < IW; li = li + 1)
                if (m_ftaken[li]) begin
                    m_flow = m_ftarget[li * 32 +: 32];
                    m_ptc = 1'b1;
                end
            m_pc = redirect_valid ? redirect_pc
                 : (stall || halt) ? m_pc
                 : m_ptc ? m_flow : (m_pc + 32'd4 * IW);
            // ---- 5) bht 更新 (nv 基于旧值快照, 倒序应用低槽赢) ----
            for (li = 0; li < IW; li = li + 1) begin
                if (bht_upd_req[li])
                    m_nv[li * 2 +: 2] = bht_upd_taken[li]
                                      ? ((m_bht[bht_upd_idx[li * BW +: BW]] < 2'b11)
                                         ? (m_bht[bht_upd_idx[li * BW +: BW]] + 2'd1)
                                         : m_bht[bht_upd_idx[li * BW +: BW]])
                                      : ((m_bht[bht_upd_idx[li * BW +: BW]] > 2'b00)
                                         ? (m_bht[bht_upd_idx[li * BW +: BW]] - 2'd1)
                                         : m_bht[bht_upd_idx[li * BW +: BW]]);
            end
            for (li = IW - 1; li >= 0; li = li - 1)
                if (bht_upd_req[li])
                    m_bht[bht_upd_idx[li * BW +: BW]] = m_nv[li * 2 +: 2];
        end
    endtask

    // 检查: 组合输出 (imem_addr/bht counters/ras head_snap) + 批输出
    task check_all;
        integer li, bad;
        begin
            bad = 0;
            if (dut.pc_r !== m_pc) begin
                $display("DBG pc_r=%h m_pc=%h t=%0t st=%b rd=%b hl=%b", dut.pc_r, m_pc, $time,
                         stall, redirect_valid, halt);
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
            end
            for (li = 0; li < BHT; li = li + 1)
                if (dut.u_bht.counters_r[li] !== m_bht[li]) begin
                    $display("FAIL: bht[%0d] = %b expect %b", li,
                             dut.u_bht.counters_r[li], m_bht[li]);
                    bad = bad + 1;
                end
            for (li = 0; li < IW; li = li + 1)
                if (dut.u_ras.head_snap[li * RA +: RA]
                    !== m_h[li * (RA + 1) +: RA]) begin
                    $display("FAIL: head_snap[%0d]", li);
                    bad = bad + 1;
                end
            errors = errors + bad;
        end
    endtask

    initial begin
        $dumpfile("sim/front/tb_fetch.vcd");
        $dumpvars(0, tb_fetch);

        m_pc = 0;
        m_pc_prev = 0;
        m_first = 1'b1;
        for (i = 0; i < BHT; i = i + 1) m_bht[i] = 2'b01;
        for (i = 0; i < RAS; i = i + 1) m_stack[i] = 0;
        m_head = 0;
        m_h = 0;
        m_fvalid = 0; m_fraw = 0; m_fpc = 0; m_ftaken = 0; m_ftarget = 0; m_fras = 0;

        clr_all();
        #23 rst_n = 1;
        #1;   // 第一个 posedge (t=25) 之前检查复位状态

        // F1 复位: PC=0 (imem_addr=0,4,8,C), 无批输出
        check_all();
        if (imem_addr[0 * 32 +: 32] !== 32'd0 || f2i_valid !== {IW{1'b0}}) begin
            $display("FAIL: F1 reset"); errors = errors + 1;
        end else begin
            $display("PASS: F1 reset");
        end

        // F2 顺序取指: 预热拍 (复位后第一拍批不采样, halt 保 PC) 后
        // PC 0→16, 批输出 0/4/8/12 (NOP 无预测)
        inst_data = {4{32'h00000013}};
        halt = 1'b1;    // 预热: 批保持复位态, PC 不推进
        tick();
        check_all();
        halt = 1'b0;
        if (f2i_valid !== {IW{1'b0}}) begin
            $display("FAIL: F2 pre-batch (first cycle)");
            errors = errors + 1;
        end
        tick();
        check_all();
        if (f2i_valid !== {IW{1'b1}} || f2i_pc !== {32'hC, 32'h8, 32'h4, 32'h0}
         || f2i_pred_taken !== {IW{1'b0}}) begin
            $display("FAIL: F2 sequential fetch"); errors = errors + 1;
        end else begin
            $display("PASS: F2 sequential fetch pc 0..12");
        end

        // F3 stall: PC 与批保持
        clr_all();
        stall = 1'b1;
        tick();
        check_all();
        if (imem_addr !== {32'h1C, 32'h18, 32'h14, 32'h10}
         || f2i_pc !== {32'hC, 32'h8, 32'h4, 32'h0}) begin
            $display("FAIL: F3 stall"); errors = errors + 1;
        end else begin
            $display("PASS: F3 stall keeps PC and batch");
        end

        // F4 redirect: 清批 + 改 PC
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h100;
        tick();
        check_all();
        if (imem_addr[0 * 32 +: 32] !== 32'h100 || f2i_valid !== {IW{1'b0}}) begin
            $display("FAIL: F4 redirect"); errors = errors + 1;
        end else begin
            $display("PASS: F4 redirect clears batch");
        end

        // F5 halt: PC 停
        clr_all();
        halt = 1'b1;
        tick();
        check_all();
        if (imem_addr[0 * 32 +: 32] !== 32'h100 || f2i_valid !== {IW{1'b0}}) begin
            $display("FAIL: F5 halt"); errors = errors + 1;
        end else begin
            $display("PASS: F5 halt stops fetch");
        end

        // F6 jal 预测: pc=0x100, 槽3 jal rd=0 imm=8 → taken=1 target=0x10C+8=0x114
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h100;
        tick();
        check_all();
        clr_all();
        inst_data = {jal_enc(5'd0, 32'd8), 32'h00000013, 32'h00000013, 32'h00000013};
        tick();
        check_all();
        if (f2i_pred_taken[3] !== 1'b1
         || f2i_pred_target[3 * 32 +: 32] !== 32'h114
         || f2i_pred_taken[0] !== 1'b0) begin
            $display("FAIL: F6 jal predict");
            errors = errors + 1;
        end else begin
            $display("PASS: F6 jal always taken");
        end

        // F7 call/ret RAS: pc=0x110, 槽3 call (rd=1 imm=8) → push 0x120; 下批 ret → target=0x120
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h110;
        tick();
        check_all();
        clr_all();
        inst_data = {4{32'h00000000}};   // 预热: 批为旧地址 (redirect 前), pc 推进
        tick();
        check_all();
        inst_data = {3{32'h00000013}};
        inst_data[3 * 32 +: 32] = jal_enc(5'd1, 32'd8);
        tick();
        check_all();
        if (dut.u_ras.head_r !== 3'd1 || dut.u_ras.stack[0] !== 32'h120) begin
            $display("FAIL: F7a call push"); errors = errors + 1;
        end else begin
            $display("PASS: F7a call pushes pc+4");
        end
        clr_all();
        inst_data = {3{32'h00000013}};
        inst_data[3 * 32 +: 32] = jalr_enc(5'd0, 5'd1, 32'd0);   // ret
        tick();
        check_all();
        if (f2i_pred_taken[3] !== 1'b1
         || f2i_pred_target[3 * 32 +: 32] !== 32'h120) begin
            $display("FAIL: F7b ret pop"); errors = errors + 1;
        end else begin
            $display("PASS: F7b ret predicts ras top");
        end

        // F8 空栈 ret 忽略: head=0 → top=0
        clr_all();
        inst_data = {3{32'h00000013}};
        inst_data[3 * 32 +: 32] = jalr_enc(5'd0, 5'd1, 32'd0);
        tick();
        check_all();
        if (f2i_pred_target[3 * 32 +: 32] !== 32'h0) begin
            $display("FAIL: F8 empty pop"); errors = errors + 1;
        end else begin
            $display("PASS: F8 empty ras pop predicts 0");
        end

        // F9a 弱不取: pc=0x118 分支在槽3 (idx=(0x118>>2)%32=6, counters=01) → 不预测
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h10C;
        tick();
        check_all();
        clr_all();
        inst_data = {b_enc(5'd1, 5'd2, 32'd16), 32'h00000013, 32'h00000013, 32'h00000013};
        tick();
        check_all();
        if (f2i_pred_taken[3] !== 1'b0) begin
            $display("FAIL: F9a weak not-taken"); errors = errors + 1;
        end else begin
            $display("PASS: F9a weak not-taken");
        end

        // F9b BHT 更新: idx=6 taken → 01→10
        clr_all();
        bht_upd_req = 4'b0001; bht_upd_idx[0 * BW +: BW] = 5'd6;
        bht_upd_taken = 4'b0001;
        tick();
        check_all();
        if (dut.u_bht.counters_r[6] !== 2'b10) begin
            $display("FAIL: F9b bht update"); errors = errors + 1;
        end else begin
            $display("PASS: F9b bht saturate to strong taken");
        end

        // F9c 强取: 分支再取 (idx=6, counters=10) → taken, target=0x118+16=0x128
        clr_all();
        redirect_valid = 1'b1; redirect_pc = 32'h10C;
        tick();
        check_all();
        clr_all();
        inst_data = {4{32'h00000000}};   // 预热: 批为旧地址, pc 推进
        tick();
        check_all();
        inst_data = {b_enc(5'd1, 5'd2, 32'd16), 32'h00000013, 32'h00000013, 32'h00000013};
        tick();
        check_all();
        if (f2i_pred_taken[3] !== 1'b1
         || f2i_pred_target[3 * 32 +: 32] !== 32'h128) begin
            $display("FAIL: F9c strong taken");
            errors = errors + 1;
        end else begin
            $display("PASS: F9c strong taken");
        end

        // F10 同索引多槽: idx=6 槽0 not-taken 低槽赢 → 10→01
        clr_all();
        bht_upd_req = 4'b1111; bht_upd_idx = {5'd6, 5'd6, 5'd6, 5'd6};
        bht_upd_taken = 4'b1110;                    // 槽 0 not-taken, 1..3 taken
        tick();
        check_all();
        if (dut.u_bht.counters_r[6] !== 2'b01) begin
            $display("FAIL: F10 same-idx low slot wins"); errors = errors + 1;
        end else begin
            $display("PASS: F10 same-index update low slot wins");
        end

        // F11 满栈 push 丢弃: 8 次 call 填满后 head 回绕 0, 第 9 次丢弃
        clr_all();
        for (i = 0; i < 8; i = i + 1) begin
            inst_data = {3{32'h00000013}};
            inst_data[3 * 32 +: 32] = jal_enc(5'd1, 32'd4);
            tick();
            check_all();
        end
        if (dut.u_ras.head_r !== 3'd0) begin
            $display("FAIL: F11 full push drop"); errors = errors + 1;
        end else begin
            $display("PASS: F11 full ras drops push");
        end

        // F12 批内链: call,ret,call → head_snap 0,1,0,1; ret target 用栈顶 (模型对照)
        clr_all();
        inst_data[0 * 32 +: 32] = jal_enc(5'd1, 32'd4);        // call
        inst_data[1 * 32 +: 32] = jalr_enc(5'd0, 5'd1, 32'd0); // ret
        inst_data[2 * 32 +: 32] = jal_enc(5'd1, 32'd4);        // call
        inst_data[3 * 32 +: 32] = 32'h00000013;
        tick();
        check_all();
        if (f2i_ras_snap[0 * RA +: RA] !== 3'd0
         || f2i_ras_snap[1 * RA +: RA] !== 3'd1
         || f2i_pred_taken[1] !== 1'b1) begin
            $display("FAIL: F12 batch chain"); errors = errors + 1;
        end else begin
            $display("PASS: F12 batch call/ret/call chain");
        end

        // F13 restore: 误预测恢复 head
        clr_all();
        ras_restore_valid = 1'b1; ras_restore_head = 3'd5;
        tick();
        check_all();
        if (dut.u_ras.head_r !== 3'd5) begin
            $display("FAIL: F13 restore"); errors = errors + 1;
        end else begin
            $display("PASS: F13 ras restore head");
        end

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer i2, k2;
            for (i2 = 0; i2 < 300; i2 = i2 + 1) begin
                clr_all();
                for (k2 = 0; k2 < IW; k2 = k2 + 1) begin
                    case ({$random} % 10)
                        0: inst_data[k2 * 32 +: 32] = jal_enc({$random} % 32, ($random % 4096) - 2048);
                        1: inst_data[k2 * 32 +: 32] = jalr_enc({$random} % 32, {$random} % 32, ($random % 2048) - 1024);
                        2: inst_data[k2 * 32 +: 32] = b_enc({$random} % 32, {$random} % 32, ($random % 4096) - 2048);
                        default: inst_data[k2 * 32 +: 32] = 32'h00000013;
                    endcase
                end
                if (({$random} % 8) == 0) stall = 1'b1;
                if (({$random} % 12) == 0) begin
                    redirect_valid = 1'b1; redirect_pc = {$random};
                end
                if (({$random} % 30) == 0) halt = 1'b1;
                for (k2 = 0; k2 < IW; k2 = k2 + 1) begin
                    bht_upd_req[k2] = (({$random} % 5) == 0);
                    bht_upd_idx[k2 * BW +: BW] = {$random} % BHT;
                    bht_upd_taken[k2] = {$random} & 1;
                end
                if (({$random} % 10) == 0) begin
                    ras_restore_valid = 1'b1; ras_restore_head = {$random} % RAS;
                end
                tick();
                check_all();
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
