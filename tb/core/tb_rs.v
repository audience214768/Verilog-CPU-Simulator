// tb_rs: 段 1 小规模+极端 (分配装载/就绪判定/CDB 命中/年龄仲裁/同年龄低槽/互斥/
//        自清/flush>clear>push/空槽分散分配/满 RS/年龄回绕);
//        段 2 随机模型对照 (300 拍, 选择结果/free_count/全字段逐拍断言)
`timescale 1ns/1ps
module tb_rs;
    localparam IW  = 4;
    localparam RS  = 16;
    localparam PRF = 64;
    localparam ROB = 32;
    localparam LSQ = 16;
    localparam BHT = 32;
    localparam RAS = 8;
    localparam SRW = 4;   // clog2(16)
    localparam CSW = 5;   // clog2(17)
    localparam PW  = 6;
    localparam RW  = 5;
    localparam LW  = 4;
    localparam RA  = 3;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [IW - 1 : 0]           sel_valid;
    wire [IW * SRW - 1 : 0]     sel_idx;
    wire [CSW - 1 : 0]          free_count;
    wire [RS - 1 : 0]           entry_valid;
    wire [RS * 7 - 1 : 0]       entry_opcode;
    wire [RS * 3 - 1 : 0]       entry_func3;
    wire [RS * 7 - 1 : 0]       entry_func7;
    wire [RS * PW - 1 : 0]      entry_prs1, entry_prs2, entry_prd;
    wire [RS * 32 - 1 : 0]      entry_pc, entry_imm;
    wire [RS * LW - 1 : 0]      entry_lsq_tag;
    wire [RS * RW - 1 : 0]      entry_rob_tag;
    wire [RS - 1 : 0]           entry_pred_taken;
    wire [RS * 32 - 1 : 0]      entry_pred_target;
    wire [RS * RA - 1 : 0]      entry_ras_snap;
    reg  [PRF - 1 : 0]          rt_ready;
    reg  [(IW + 1) * PW - 1 : 0] cdb_tag;
    reg  [IW : 0]               cdb_slot_valid;
    reg  [RW - 1 : 0]           rob_head;
    reg  [IW - 1 : 0]           push_valid;
    reg  [IW * 7 - 1 : 0]       push_opcode;
    reg  [IW * 3 - 1 : 0]       push_func3;
    reg  [IW * 7 - 1 : 0]       push_func7;
    reg  [IW * PW - 1 : 0]      push_prs1, push_prs2, push_prd;
    reg  [IW * 32 - 1 : 0]      push_pc, push_imm;
    reg  [IW * LW - 1 : 0]      push_lsq_tag;
    reg  [IW * RW - 1 : 0]      push_rob_tag;
    reg  [IW - 1 : 0]           push_pred_taken;
    reg  [IW * 32 - 1 : 0]      push_pred_target;
    reg  [IW * RA - 1 : 0]      push_ras_snap;
    reg  [IW - 1 : 0]           clear_valid;
    reg  [IW * SRW - 1 : 0]     clear_idx;
    reg  [RS - 1 : 0]           flush_mask;

    rs #(.ISSUE_WIDTH(IW), .RS_SIZE(RS), .PRF_SIZE(PRF), .ROB_SIZE(ROB),
         .LSQ_SIZE(LSQ), .BHT_SIZE(BHT), .RAS_SIZE(RAS)) dut (
        .clk(clk), .rst_n(rst_n),
        .sel_valid(sel_valid), .sel_idx(sel_idx), .free_count(free_count),
        .entry_valid(entry_valid), .entry_opcode(entry_opcode), .entry_func3(entry_func3),
        .entry_func7(entry_func7), .entry_prs1(entry_prs1), .entry_prs2(entry_prs2),
        .entry_prd(entry_prd), .entry_pc(entry_pc), .entry_imm(entry_imm),
        .entry_lsq_tag(entry_lsq_tag), .entry_rob_tag(entry_rob_tag),
        .entry_pred_taken(entry_pred_taken), .entry_pred_target(entry_pred_target),
        .entry_ras_snap(entry_ras_snap),
        .rt_ready(rt_ready), .cdb_tag(cdb_tag), .cdb_slot_valid(cdb_slot_valid),
        .rob_head(rob_head),
        .push_valid(push_valid), .push_opcode(push_opcode), .push_func3(push_func3),
        .push_func7(push_func7), .push_prs1(push_prs1), .push_prs2(push_prs2),
        .push_prd(push_prd), .push_pc(push_pc), .push_imm(push_imm),
        .push_lsq_tag(push_lsq_tag), .push_rob_tag(push_rob_tag),
        .push_pred_taken(push_pred_taken), .push_pred_target(push_pred_target),
        .push_ras_snap(push_ras_snap),
        .clear_valid(clear_valid), .clear_idx(clear_idx), .flush_mask(flush_mask)
    );

    integer errors = 0;
    integer i, j, k;

    // ---- 模型 (与 DUT 同公式: 就绪/CDB 命中/年龄回绕/仲裁扫描/prec 分配) ----
    reg              m_valid [0 : RS - 1];
    reg [6 : 0]      m_opcode [0 : RS - 1];
    reg [2 : 0]      m_func3 [0 : RS - 1];
    reg [6 : 0]      m_func7 [0 : RS - 1];
    reg [PW - 1 : 0] m_prs1 [0 : RS - 1];
    reg [PW - 1 : 0] m_prs2 [0 : RS - 1];
    reg [PW - 1 : 0] m_prd [0 : RS - 1];
    reg [31 : 0]     m_pc [0 : RS - 1];
    reg [31 : 0]     m_imm [0 : RS - 1];
    reg [LW - 1 : 0] m_lsq [0 : RS - 1];
    reg [RW - 1 : 0] m_rob [0 : RS - 1];
    reg              m_ptaken [0 : RS - 1];
    reg [31 : 0]     m_ptarget [0 : RS - 1];
    reg [RA - 1 : 0] m_ras [0 : RS - 1];
    reg [RS * CSW - 1 : 0] m_prec;

    reg [IW - 1 : 0]       m_selv;
    reg [IW * SRW - 1 : 0] m_seli;

    task clr_all;
        begin
            rt_ready = 0;
            cdb_tag = 0; cdb_slot_valid = 0;
            rob_head = 0;
            push_valid = 0; push_opcode = 0; push_func3 = 0; push_func7 = 0;
            push_prs1 = 0; push_prs2 = 0; push_prd = 0;
            push_pc = 0; push_imm = 0; push_lsq_tag = 0; push_rob_tag = 0;
            push_pred_taken = 0; push_pred_target = 0; push_ras_snap = 0;
            clear_valid = 0; clear_idx = 0; flush_mask = 0;
        end
    endtask

    // 清空 RS: flush 全 1 一拍 (模型与 DUT 同步失效)
    task flush_all;
        begin
            clr_all();
            flush_mask = {RS{1'b1}};
            tick();
            check_all();
            clr_all();
        end
    endtask

    // 一拍: #1 → #8 落在 posedge → #1 → 模型更新 (新输入+旧状态) → 检查 (组合+全字段)
    task tick;
        integer li, qe;
        begin
            #1;
            #8;
            #1;
            // ---- 模型更新 (与 DUT posedge 同步: push → clear → flush) ----
            // prec 链 (旧状态空槽计数)
            for (li = 0; li < RS; li = li + 1) begin
                if (li == 0)
                    m_prec[0 * CSW +: CSW] = 0;
                else
                    m_prec[li * CSW +: CSW] = m_prec[(li - 1) * CSW +: CSW]
                                            + {{(CSW - 1){1'b0}}, !m_valid[li - 1]};
            end
            // push: 槽 k 分配 prec==k 的最低空条目 (唯一)
            for (li = 0; li < IW; li = li + 1) begin
                if (push_valid[li]) begin
                    for (qe = 0; qe < RS; qe = qe + 1) begin
                        if (!m_valid[qe] && m_prec[qe * CSW +: CSW] == li) begin
                            m_valid[qe]     = 1'b1;
                            m_opcode[qe]    = push_opcode[li * 7 +: 7];
                            m_func3[qe]     = push_func3[li * 3 +: 3];
                            m_func7[qe]     = push_func7[li * 7 +: 7];
                            m_prs1[qe]      = push_prs1[li * PW +: PW];
                            m_prs2[qe]      = push_prs2[li * PW +: PW];
                            m_prd[qe]       = push_prd[li * PW +: PW];
                            m_pc[qe]        = push_pc[li * 32 +: 32];
                            m_imm[qe]       = push_imm[li * 32 +: 32];
                            m_lsq[qe]       = push_lsq_tag[li * LW +: LW];
                            m_rob[qe]       = push_rob_tag[li * RW +: RW];
                            m_ptaken[qe]    = push_pred_taken[li];
                            m_ptarget[qe]   = push_pred_target[li * 32 +: 32];
                            m_ras[qe]       = push_ras_snap[li * RA +: RA];
                        end
                    end
                end
            end
            // clear: 选中条目自清 (后写覆盖 push)
            for (li = 0; li < IW; li = li + 1)
                if (clear_valid[li])
                    m_valid[clear_idx[li * SRW +: SRW]] = 1'b0;
            // flush: 窗口失效 (最高优先级)
            for (li = 0; li < RS; li = li + 1)
                if (flush_mask[li])
                    m_valid[li] = 1'b0;
        end
    endtask

    // 检查: 模型扫描 (当前状态+当前输入) vs DUT 组合 + 全字段
    task check_all;
        integer li, lk, le, lj, bad, qe;
        reg [RW - 1 : 0] age;
        reg [RS - 1 : 0] picked;
        reg              st_v;
        reg [RW - 1 : 0] st_age;
        reg [SRW - 1 : 0] st_i;
        reg              rdy1, rdy2;
        begin
            bad = 0;
            // ---- 模型仲裁扫描 (与 DUT 同公式: 级 k 排除前级选中, 同年龄低槽赢) ----
            picked = 0;
            for (lk = 0; lk < IW; lk = lk + 1) begin
                st_v = 1'b0; st_age = 0; st_i = 0;
                for (le = 0; le < RS; le = le + 1) begin
                    age = m_rob[le] - rob_head;          // RW 位回绕
                    if (m_valid[le] && !flush_mask[le] && !picked[le]) begin
                        rdy1 = (m_prs1[le] == 0);
                        rdy2 = (m_prs2[le] == 0);
                        for (lj = 0; lj <= IW; lj = lj + 1) begin
                            if (cdb_slot_valid[lj]) begin
                                if (cdb_tag[lj * PW +: PW] == m_prs1[le]) rdy1 = 1'b1;
                                if (cdb_tag[lj * PW +: PW] == m_prs2[le]) rdy2 = 1'b1;
                            end
                        end
                        if (!rdy1 && rt_ready[m_prs1[le]]) rdy1 = 1'b1;
                        if (!rdy2 && rt_ready[m_prs2[le]]) rdy2 = 1'b1;
                        if (rdy1 && rdy2) begin
                            if (!st_v || (age < st_age)
                             || ((age == st_age) && (le < st_i))) begin
                                st_v = 1'b1; st_age = age; st_i = le;
                            end
                        end
                    end
                end
                m_selv[lk] = st_v;
                m_seli[lk * SRW +: SRW] = st_i;
                if (st_v) picked[st_i] = 1'b1;
            end
            if (sel_valid !== m_selv || sel_idx !== m_seli) begin
                $display("FAIL: sel = %b/%h expect %b/%h (t=%0t)",
                         sel_valid, sel_idx, m_selv, m_seli, $time);
                bad = bad + 1;
            end
            // free_count
            qe = 0;
            for (le = 0; le < RS; le = le + 1) qe = qe + !m_valid[le];
            if (free_count !== qe[CSW - 1 : 0]) begin
                $display("FAIL: free_count = %0d expect %0d (t=%0t)",
                         free_count, qe, $time);
                bad = bad + 1;
            end
            // 全字段
            for (le = 0; le < RS; le = le + 1) begin
                if (entry_valid[le] !== m_valid[le]
                 || entry_opcode[le * 7 +: 7] !== m_opcode[le]
                 || entry_func3[le * 3 +: 3] !== m_func3[le]
                 || entry_func7[le * 7 +: 7] !== m_func7[le]
                 || entry_prs1[le * PW +: PW] !== m_prs1[le]
                 || entry_prs2[le * PW +: PW] !== m_prs2[le]
                 || entry_prd[le * PW +: PW] !== m_prd[le]
                 || entry_pc[le * 32 +: 32] !== m_pc[le]
                 || entry_imm[le * 32 +: 32] !== m_imm[le]
                 || entry_lsq_tag[le * LW +: LW] !== m_lsq[le]
                 || entry_rob_tag[le * RW +: RW] !== m_rob[le]
                 || entry_pred_taken[le] !== m_ptaken[le]
                 || entry_pred_target[le * 32 +: 32] !== m_ptarget[le]
                 || entry_ras_snap[le * RA +: RA] !== m_ras[le]) begin
                    $display("FAIL: entry[%0d] field mismatch (t=%0t)", le, $time);
                    bad = bad + 1;
                end
            end
            errors = errors + bad;
        end
    endtask

    initial begin
        $dumpfile("sim/core/tb_rs.vcd");
        $dumpvars(0, tb_rs);

        // 模型初始化为空
        for (i = 0; i < RS; i = i + 1) begin
            m_valid[i] = 0; m_opcode[i] = 0; m_func3[i] = 0; m_func7[i] = 0;
            m_prs1[i] = 0; m_prs2[i] = 0; m_prd[i] = 0;
            m_pc[i] = 0; m_imm[i] = 0; m_lsq[i] = 0; m_rob[i] = 0;
            m_ptaken[i] = 0; m_ptarget[i] = 0; m_ras[i] = 0;
        end
        m_selv = 0; m_seli = 0;
        clr_all();
        #23 rst_n = 1;
        #3;
        // R1 复位: 全空, 无选择
        tick();
        check_all();
        if (free_count !== 5'd16 || sel_valid !== 4'b0000) begin
            $display("FAIL: R1 reset"); errors = errors + 1;
        end else begin
            $display("PASS: R1 reset");
        end

        // R2 单 push (prs=0 立即就绪): 装载正确 + 下拍选中 + free=15
        clr_all();
        push_valid = 4'b0001;
        push_opcode = {4{7'h33}}; push_func3 = {4{3'd0}}; push_func7 = {4{7'h01}};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}}; push_prd = {4{6'd40}};
        push_rob_tag = {4{5'd3}}; push_pc = {4{32'h100}}; push_imm = {4{32'h8}};
        push_lsq_tag = {4{4'd2}}; push_pred_taken = 4'b0001;
        push_pred_target = {4{32'h104}}; push_ras_snap = {4{3'd5}};
        tick();
        check_all();
        if (sel_valid !== 4'b0001 || sel_idx[0 * SRW +: SRW] !== 4'd0
         || free_count !== 5'd15) begin
            $display("FAIL: R2 select ready entry"); errors = errors + 1;
        end else begin
            $display("PASS: R2 single push selects next cycle");
        end

        flush_all();
        // R3 批 push 4 (rob 4..7): 顺序分配 0..3, 全就绪 → sel 0..3 按年龄
        clr_all();
        push_valid = 4'b1111;
        push_opcode = {7'h13, 7'h33, 7'h13, 7'h33};
        push_rob_tag = {5'd7, 5'd6, 5'd5, 5'd4};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        push_prd = {6'd43, 6'd42, 6'd41, 6'd40};
        tick();
        check_all();
        if (sel_valid !== 4'b1111
         || sel_idx[0 * SRW +: SRW] !== 4'd0
         || sel_idx[1 * SRW +: SRW] !== 4'd1
         || sel_idx[2 * SRW +: SRW] !== 4'd2
         || sel_idx[3 * SRW +: SRW] !== 4'd3) begin
            $display("FAIL: R3 batch select by age"); errors = errors + 1;
        end else begin
            $display("PASS: R3 batch push alloc 0..3 + select all");
        end

        flush_all();
        // R4 年龄仲裁: 槽 0 rob=20, 槽 1 rob=3 (head=0) → 选条目 1 (rob 3 更老)
        clr_all();
        push_valid = 4'b0011;
        push_rob_tag = {5'd0, 5'd3, 5'd0, 5'd20};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick();
        check_all();
        if (sel_valid !== 4'b0011
         || sel_idx[0 * SRW +: SRW] !== 4'd1
         || sel_idx[1 * SRW +: SRW] !== 4'd0) begin
            $display("FAIL: R4 age arbitration"); errors = errors + 1;
        end else begin
            $display("PASS: R4 older tag wins");
        end

        flush_all();
        // R5 同年龄: rob 相同 → 低槽赢
        clr_all();
        push_valid = 4'b0011;
        push_rob_tag = {4{5'd9}};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick();
        check_all();
        if (sel_valid !== 4'b0011
         || sel_idx[0 * SRW +: SRW] !== 4'd0
         || sel_idx[1 * SRW +: SRW] !== 4'd1) begin
            $display("FAIL: R5 same-age lower slot"); errors = errors + 1;
        end else begin
            $display("PASS: R5 same age -> lower slot wins");
        end

        flush_all();
        // R6 不就绪: prs1=5 无 cdb 无 rt_ready → 不选; rt_ready[5]=1 → 选
        clr_all();
        push_valid = 4'b0001;
        push_prs1 = {4{6'd5}}; push_prs2 = {4{6'd0}};
        push_rob_tag = {4{5'd7}};
        tick();
        check_all();
        if (sel_valid !== 4'b0000) begin
            $display("FAIL: R6a not ready"); errors = errors + 1;
        end else begin
            $display("PASS: R6a prs=5 not ready");
        end
        clr_all();
        rt_ready[5] = 1'b1;
        tick();
        check_all();
        if (sel_valid !== 4'b0001 || sel_idx[0 * SRW +: SRW] !== 4'd0) begin
            $display("FAIL: R6b rt_ready"); errors = errors + 1;
        end else begin
            $display("PASS: R6b rt_ready makes ready");
        end

        // R7 CDB 命中: rt_ready[5]=0, cdb_tag[0]=5 → 选; 清 cdb → 不选
        clr_all();
        rt_ready[5] = 1'b0;
        cdb_slot_valid[0] = 1'b1; cdb_tag[0 * PW +: PW] = 6'd5;
        tick();
        check_all();
        if (sel_valid !== 4'b0001) begin
            $display("FAIL: R7a cdb hit"); errors = errors + 1;
        end else begin
            $display("PASS: R7a cdb broadcast makes ready");
        end
        cdb_slot_valid[0] = 1'b0;
        tick();
        check_all();
        if (sel_valid !== 4'b0000) begin
            $display("FAIL: R7b no cdb"); errors = errors + 1;
        end else begin
            $display("PASS: R7b no cdb -> not ready");
        end

        flush_all();
        // R8 clear 自清: 选中条目失效; 同拍 clear+push 同条目 → clear 赢
        clr_all();
        push_valid = 4'b0001;
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        push_rob_tag = {4{5'd3}};
        tick();
        check_all();
        clr_all();
        clear_valid = 4'b0001; clear_idx[0 * SRW +: SRW] = 4'd0;
        tick();
        check_all();
        if (entry_valid[0] !== 1'b0 || free_count !== 5'd16) begin
            $display("FAIL: R8 clear self"); errors = errors + 1;
        end else begin
            $display("PASS: R8 clear invalidates entry");
        end
        // clear+push 同拍 (push 分配到刚清空的条目 0, clear 再清它 → 空)
        clr_all();
        push_valid = 4'b0001; push_rob_tag = {4{5'd3}};
        clear_valid = 4'b0001; clear_idx[0 * SRW +: SRW] = 4'd0;
        tick();
        check_all();
        if (entry_valid[0] !== 1'b0) begin
            $display("FAIL: R8b clear>push"); errors = errors + 1;
        end else begin
            $display("PASS: R8b clear beats push");
        end

        flush_all();
        // R9 flush > push: flush 清条目; flush+push 同条目 → flush 赢
        clr_all();
        push_valid = 4'b0001; push_rob_tag = {4{5'd3}};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick();
        check_all();
        flush_mask[0] = 1'b1;
        tick();
        check_all();
        if (entry_valid[0] !== 1'b0) begin
            $display("FAIL: R9 flush"); errors = errors + 1;
        end else begin
            $display("PASS: R9 flush invalidates");
        end
        clr_all();
        push_valid = 4'b0001; push_rob_tag = {4{5'd3}};
        flush_mask[0] = 1'b1;
        tick();
        check_all();
        if (entry_valid[0] !== 1'b0) begin
            $display("FAIL: R9b flush>push"); errors = errors + 1;
        end else begin
            $display("PASS: R9b flush beats push");
        end

        flush_all();
        // R10 年龄回绕: head=30, 槽 0 rob=2 (age 4) 与 槽 1 rob=1 (age 3) → 选条目 1
        clr_all();
        rob_head = 5'd30;
        push_valid = 4'b0011;
        push_rob_tag = {5'd0, 5'd0, 5'd1, 5'd2};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick();
        check_all();
        if (sel_valid !== 4'b0011
         || sel_idx[0 * SRW +: SRW] !== 4'd1
         || sel_idx[1 * SRW +: SRW] !== 4'd0) begin
            $display("FAIL: R10 age wrap"); errors = errors + 1;
        end else begin
            $display("PASS: R10 age wraps with rob_head");
        end

        flush_all();
        // R11 分散空槽: 条目 0,2 有效 (1 空) → 批 push 2 分配 1,3 (prec 链跨空)
        clr_all();
        rob_head = 5'd0;
        push_valid = 4'b0011;
        push_rob_tag = {5'd0, 5'd0, 5'd1, 5'd0};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick(); check_all();                          // 条目 0,1 有效
        clr_all();
        push_valid = 4'b0001;
        push_rob_tag = {5'd0, 5'd0, 5'd0, 5'd2};
        tick(); check_all();                          // 条目 2 有效 → 0,1,2
        clr_all();
        clear_valid = 4'b0010; clear_idx = {4'd3, 4'd2, 4'd1, 4'd0};
        tick(); check_all();                          // 清条目 1 → 0,2 有效
        clr_all();
        push_valid = 4'b0011;
        push_rob_tag = {5'd0, 5'd0, 5'd9, 5'd8};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick(); check_all();                          // 分配条目 1,3
        if (entry_rob_tag[1 * RW +: RW] !== 5'd8
         || entry_rob_tag[3 * RW +: RW] !== 5'd9
         || entry_valid[0] !== 1'b1 || entry_valid[2] !== 1'b1) begin
            $display("FAIL: R11 scattered alloc"); errors = errors + 1;
        end else begin
            $display("PASS: R11 scatter alloc via prec chain");
        end

        flush_all();
        // R12 满 RS: push 不分配 (free=0 保持, 字段不变)
        clr_all();
        push_valid = 4'b1111;
        push_rob_tag = {5'd0, 5'd15, 5'd14, 5'd13};
        push_prs1 = {4{6'd0}}; push_prs2 = {4{6'd0}};
        tick(); check_all();
        tick(); check_all();
        tick(); check_all();
        tick(); check_all();
        if (free_count !== 5'd0) begin
            $display("FAIL: R12 full"); errors = errors + 1;
        end else begin
            $display("PASS: R12 RS full");
        end
        push_valid = 4'b0001; push_rob_tag = {4{5'd1}};
        tick(); check_all();
        if (free_count !== 5'd0 || entry_rob_tag[0 * RW +: RW] !== 5'd13) begin
            $display("FAIL: R12b push on full"); errors = errors + 1;
        end else begin
            $display("PASS: R12b push on full ignored");
        end

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer i2, k2, j2;
            for (i2 = 0; i2 < 300; i2 = i2 + 1) begin
                clr_all();
                rob_head = ({$random} % 32);          // 随机回绕
                // push 批 (前缀, 仅 free 足够; free_count 组合 = 当前有效)
                if (free_count > 0) begin
                    push_valid[0] = 1'b1;
                    if (free_count > 1 && ({$random} & 1)) push_valid[1] = 1'b1;
                    if (free_count > 2 && ({$random} & 1)) push_valid[2] = 1'b1;
                    if (free_count > 3 && ({$random} & 1)) push_valid[3] = 1'b1;
                end
                for (k2 = 0; k2 < IW; k2 = k2 + 1) begin
                    push_opcode[k2 * 7 +: 7]   = {$random} % 128;
                    push_func3[k2 * 3 +: 3]    = {$random} % 8;
                    push_func7[k2 * 7 +: 7]    = {$random} % 128;
                    push_prs1[k2 * PW +: PW]   = (({$random} % 8) == 0)
                                               ? 6'd0 : (6'd1 + ({$random} % (PRF - 1)));
                    push_prs2[k2 * PW +: PW]   = (({$random} % 8) == 0)
                                               ? 6'd0 : (6'd1 + ({$random} % (PRF - 1)));
                    push_prd[k2 * PW +: PW]    = {$random} % PRF;
                    push_pc[k2 * 32 +: 32]     = {$random};
                    push_imm[k2 * 32 +: 32]    = {$random};
                    push_lsq_tag[k2 * LW +: LW] = {$random} % LSQ;
                    push_rob_tag[k2 * RW +: RW] = {$random} % ROB;
                    push_pred_taken[k2]        = {$random} & 1;
                    push_pred_target[k2 * 32 +: 32] = {$random};
                    push_ras_snap[k2 * RA +: RA] = {$random} % RAS;
                end
                // rt_ready: 1/3 概率随机翻转 3 位
                if (({$random} % 3) == 0) begin
                    rt_ready[{$random} % PRF] = {$random} & 1;
                    rt_ready[{$random} % PRF] = {$random} & 1;
                    rt_ready[{$random} % PRF] = {$random} & 1;
                end
                // cdb: 每槽 1/3 概率有效, tag 随机 (撞 prs 概率 ~1/64)
                for (j2 = 0; j2 <= IW; j2 = j2 + 1) begin
                    cdb_slot_valid[j2] = (({$random} % 3) == 0);
                    cdb_tag[j2 * PW +: PW] = {$random} % PRF;
                end
                // flush_mask: 1/16 概率随机
                if (({$random} % 16) == 0)
                    flush_mask = {$random};
                // clear: 上一拍选择自清
                clear_valid = m_selv;
                clear_idx = m_seli;
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
