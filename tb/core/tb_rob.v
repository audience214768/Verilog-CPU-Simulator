// tb_rob: 段 1 小规模+极端 (push 批/环形回绕/set_ready/set_head 释放/set_last 截断与清空/
//        优先级 set_last>set_head>set_ready>push/满判据/empty 判据/越界槽位回绕);
//        段 2 随机模型对照 (300 拍, 指针/条目全字段逐拍断言)
`timescale 1ns/1ps
module tb_rob;
    localparam IW  = 4;
    localparam RB  = 32;
    localparam PRF = 64;
    localparam LQ  = 16;
    localparam PW  = 6;
    localparam LW  = 4;
    localparam RW  = 5;
    localparam RCW = 6;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [RW - 1 : 0]      head, last;
    wire               empty, full;
    wire [RCW - 1 : 0]     free_count;
    wire [RB - 1 : 0]    ready;
    wire [RB * 7 - 1 : 0]  opcode;
    wire [RB * 5 - 1 : 0]  rd;
    wire [RB * PW - 1 : 0] new_pnum, old_pnum;
    wire [RB * LW - 1 : 0] lsq_tag;
    wire [RB * 32 - 1 : 0] ins_raw;
    reg  [IW - 1 : 0]     push_valid;
    reg  [IW * 7 - 1 : 0]  push_opcode;
    reg  [IW * 5 - 1 : 0]  push_rd;
    reg  [IW * PW - 1 : 0] push_new, push_old;
    reg  [IW * LW - 1 : 0] push_lsq_tag;
    reg  [IW * 32 - 1 : 0] push_ins_raw;
    reg                set_head_valid;
    reg  [RW - 1 : 0]  set_head_val;
    reg                set_last_valid;
    reg  [RW - 1 : 0]  set_last_val;
    reg  [RB - 1 : 0]  set_ready_req;

    rob #(.ISSUE_WIDTH(IW), .ROB_SIZE(RB), .PRF_SIZE(PRF), .LSQ_SIZE(LQ)) dut (
        .clk(clk), .rst_n(rst_n),
        .head(head), .last(last), .empty(empty), .full(full), .free_count(free_count),
        .ready(ready), .opcode(opcode), .rd(rd),
        .new_pnum(new_pnum), .old_pnum(old_pnum), .lsq_tag(lsq_tag), .ins_raw(ins_raw),
        .push_valid(push_valid), .push_opcode(push_opcode), .push_rd(push_rd),
        .push_new(push_new), .push_old(push_old), .push_lsq_tag(push_lsq_tag),
        .push_ins_raw(push_ins_raw),
        .set_head_valid(set_head_valid), .set_head_val(set_head_val),
        .set_last_valid(set_last_valid), .set_last_val(set_last_val),
        .set_ready_req(set_ready_req)
    );

    integer errors = 0;
    integer i, j, k;

    // ---- 模型 (与实现同公式: 窗口 = [head, last); 空/满由 free 区分) ----
    reg [RW - 1 : 0]  m_head, m_last;
    reg [RCW - 1 : 0] m_free;
    reg              m_ready [0 : RB - 1];
    reg [6 : 0]      m_op [0 : RB - 1];
    reg [4 : 0]      m_rd [0 : RB - 1];
    reg [PW - 1 : 0] m_new [0 : RB - 1];
    reg [PW - 1 : 0] m_old [0 : RB - 1];
    reg [LW - 1 : 0] m_lsq [0 : RB - 1];
    reg [31 : 0]     m_raw [0 : RB - 1];

    // push 前缀计数 (0..IW)
    function [RCW - 1 : 0] pcnt;
        input [IW - 1 : 0] v;
        integer q;
        begin
            pcnt = 0;
            for (q = 0; q < IW; q = q + 1) pcnt = pcnt + v[q];
        end
    endfunction
    function [RCW - 1 : 0] ppre;
        input [IW - 1 : 0] v;
        input integer s;
        integer q;
        begin
            ppre = 0;
            for (q = 0; q < s; q = q + 1) ppre = ppre + v[q];
        end
    endfunction

    task model_apply;
        reg [RCW - 1 : 0] d_old, d_new;
        reg [RW - 1 : 0]  d_new_rw, d_h_rw;
        integer li, lk;
        begin
            // push 条目写 (与指针更新独立: flush 同拍也写条目, 但窗口截断将其丢弃)
            for (lk = 0; lk < IW; lk = lk + 1) begin
                if (push_valid[lk]) begin
                    li = (m_last + ppre(push_valid, lk)) & (RB - 1);
                    m_op[li]  = push_opcode[lk * 7 +: 7];
                    m_rd[li]  = push_rd[lk * 5 +: 5];
                    m_new[li] = push_new[lk * PW +: PW];
                    m_old[li] = push_old[lk * PW +: PW];
                    m_lsq[li] = push_lsq_tag[lk * LW +: LW];
                    m_raw[li] = push_ins_raw[lk * 32 +: 32];
                    m_ready[li] = 1'b0;
                end
            end
            if (set_last_valid) begin
                d_old = RB - m_free;                 // 窗口大小 (empty→0, full→RB)
                d_new_rw = set_last_val - m_head;    // RW 位回绕后再零扩展
                d_new = {1'b0, d_new_rw};
                if (d_new <= d_old) begin
                    m_last = set_last_val;
                    m_free = RB - d_new;
                end else begin
                    m_head = set_last_val + 1;
                    m_last = set_last_val + 1;
                    m_free = RB;
                end
            end else begin
                m_last = m_last + pcnt(push_valid);
                m_free = m_free - pcnt(push_valid);
                if (set_head_valid) begin
                    d_h_rw = set_head_val - m_head;  // RW 回绕 = 释放数
                    m_free = m_free + d_h_rw;
                    m_head = set_head_val;
                end
            end
            // set_ready: 后写覆盖 push 的 ready=0
            for (li = 0; li < RB; li = li + 1)
                if (set_ready_req[li])
                    m_ready[li] = 1'b1;
        end
    endtask

    task check_all;
        integer bad, li;
        begin
            bad = 0;
            if (head !== m_head || last !== m_last || free_count !== m_free) begin
                $display("FAIL: h/l/f = %0d/%0d/%0d expect %0d/%0d/%0d",
                         head, last, free_count, m_head, m_last, m_free);
                bad = bad + 1;
            end
            if (empty !== (m_free == RB) || full !== (m_free == 0)) begin
                $display("FAIL: empty=%0b full=%0b expect %0b/%0b", empty, full, (m_free == RB), (m_free == 0));
                bad = bad + 1;
            end
            for (li = 0; li < RB; li = li + 1) begin
                if (ready[li] !== m_ready[li]
                 || opcode[li * 7 +: 7] !== m_op[li] || rd[li * 5 +: 5] !== m_rd[li]
                 || new_pnum[li * PW +: PW] !== m_new[li] || old_pnum[li * PW +: PW] !== m_old[li]
                 || lsq_tag[li * LW +: LW] !== m_lsq[li] || ins_raw[li * 32 +: 32] !== m_raw[li]) begin
                    $display("FAIL: entry[%0d] ready/op/rd/new/old/lsq/raw mismatch", li);
                    bad = bad + 1;
                end
            end
            errors = errors + bad;
        end
    endtask

    task clr;
        begin
            push_valid = 0; push_opcode = 0; push_rd = 0;
            push_new = 0; push_old = 0; push_lsq_tag = 0; push_ins_raw = 0;
            set_head_valid = 0; set_head_val = 0;
            set_last_valid = 0; set_last_val = 0;
            set_ready_req = 0;
        end
    endtask

    // 一拍: 驱动后 #1 → #8 落在 posedge → #1 等 DUT 更新
    task tick;
        begin
            model_apply();
            #1;
            #8;
            #1;
        end
    endtask

    initial begin
        $dumpfile("sim/core/tb_rob.vcd");
        $dumpvars(0, tb_rob);
        $monitor("%0t: push_valid=%b set_head=%b set_last=%b | last_r=%0d free_r=%0d head_r=%0d",
                 $time, push_valid, set_head_valid, set_last_valid,
                 dut.last_r, dut.free_r, dut.head_r);

        // ---- 段 1: 小规模 + 极端 ----
        clr();
        #23 rst_n = 1;
        #3;
        // C1 复位
        m_head = 0; m_last = 0; m_free = RB;
        for (i = 0; i < RB; i = i + 1) begin
            m_ready[i] = 0; m_op[i] = 0; m_rd[i] = 0;
            m_new[i] = 0; m_old[i] = 0; m_lsq[i] = 0; m_raw[i] = 0;
        end
        check_all();

        // C2 单 push (条目 0)
        push_valid = 4'b0001; push_opcode = {4{7'h13}}; push_rd = {4{5'd3}};
        push_new = {4{6'd40}}; push_old = {4{6'd3}}; push_ins_raw = {4{32'h00A00093}};
        tick();
        check_all();
        if (new_pnum[0 * PW +: PW] !== 6'd40) begin
            $display("FAIL: C2 entry0 new_pnum"); errors = errors + 1;
        end else begin
            $display("PASS: C2 single push");
        end

        // C3 push 批 (3 条, 槽 1..3) + set_ready 置位条目 0
        clr();
        push_valid = 4'b0111;
        push_opcode = {7'h13, 7'h33, 7'h13, 7'h00};
        push_rd     = {5'd5, 5'd4, 5'd3, 5'd0};
        push_new    = {6'd43, 6'd42, 6'd41, 6'd0};
        push_old    = {6'd5, 6'd4, 6'd3, 6'd0};
        set_ready_req[0] = 1'b1;
        tick();
        check_all();
        if (ready[0] !== 1'b1 || ready[1] !== 1'b0) begin
            $display("FAIL: C3 set_ready"); errors = errors + 1;
        end else begin
            $display("PASS: C3 batch push + set_ready");
        end

        // C4 set_head 提交 2 条 (head=2, 释放)
        clr();
        set_head_valid = 1'b1; set_head_val = 5'd2;
        tick();
        check_all();
        if (head !== 5'd2 || free_count !== 6'd30) begin
            $display("FAIL: C4 set_head"); errors = errors + 1;
        end else begin
            $display("PASS: C4 set_head release");
        end

        // C5 set_last 窗口内截断: [2,4) 截到 [2,3), head 保持
        clr();
        set_last_valid = 1'b1; set_last_val = 5'd3;
        tick();
        check_all();
        if (head !== 5'd2 || last !== 5'd3 || free_count !== 6'd31) begin
            $display("FAIL: C5 truncate keep"); errors = errors + 1;
        end else begin
            $display("PASS: C5 truncate keep head");
        end

        // C6 set_last 截到 head 之前 → 清空, head=last=val+1=2, free=32
        clr();
        set_last_valid = 1'b1; set_last_val = 5'd1;
        tick();
        check_all();
        if (head !== 5'd2 || last !== 5'd2 || empty !== 1'b1) begin
            $display("FAIL: C6 clear"); errors = errors + 1;
        end else begin
            $display("PASS: C6 clear (head/last converge)");
        end

        // C7 push 8×4 到满: free 32→0, last 回绕 2→...→2, 末批槽位 30,31,32,33→(30,31,0,1)
        clr();
        push_valid = 4'b1111;
        for (i = 0; i < 8; i = i + 1) begin
            for (k = 0; k < IW; k = k + 1) begin
                push_new[k * PW +: PW] = (i * 4 + k + 100) % PRF;
                push_ins_raw[k * 32 +: 32] = i * 4 + k;
            end
            tick();
            check_all();
        end
        if (full !== 1'b1 || free_count !== 6'd0 || last !== 5'd2) begin            $display("FAIL: C7 full"); errors = errors + 1;
        end else begin
            $display("PASS: C7 fill to full (last wraps)");
        end

        // C8 满窗口内 set_last 截断到 31 (head 保持, free=3), 再 push 3 → 槽 31,0,1 回绕
        clr();
        set_last_valid = 1'b1; set_last_val = 5'd31;
        tick();
        check_all();
        if (last !== 5'd31 || free_count !== 6'd3) begin
            $display("FAIL: C8 truncate from full"); errors = errors + 1;
        end
        clr();
        push_valid = 4'b0111;
        push_new = {6'd0, 6'd61, 6'd62, 6'd63};     // 槽 0←63, 槽 1←62, 槽 2←61
        tick();
        check_all();
        if (new_pnum[31 * PW +: PW] !== 6'd63
         || new_pnum[0 * PW +: PW] !== 6'd62
         || new_pnum[1 * PW +: PW] !== 6'd61
         || full !== 1'b1) begin
            $display("FAIL: C8 wrap push slots 31,0,1"); errors = errors + 1;
        end else begin
            $display("PASS: C8 truncate from full + wrap push");
        end

        // C9a 满窗口 set_last 截到 head 之后跨回绕点 (val=0 < head=2): 窗口 [2,0)=30 槽, free=2
        clr();
        set_last_valid = 1'b1; set_last_val = 5'd0;
        tick();
        check_all();
        if (last !== 5'd0 || free_count !== 6'd2 || head !== 5'd2) begin
            $display("FAIL: C9a truncate across wrap (h/l/f=%0d/%0d/%0d expect 2/0/2)",
                     head, last, free_count); errors = errors + 1;
        end

        // C9b set_ready+push 同条目 (槽 0): push 清 0 后 set_ready 置 1 → 赢
        clr();
        push_valid = 4'b0001; push_opcode = {4{7'h33}}; push_new = {4{6'd50}};
        set_ready_req[0] = 1'b1;
        tick();
        check_all();
        if (ready[0] !== 1'b1 || opcode[0 * 7 +: 7] !== 7'h33) begin
            $display("FAIL: C9 set_ready>push"); errors = errors + 1;
        end else begin
            $display("PASS: C9 set_ready beats push (same entry)");
        end

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer d_old, r;
            for (i = 0; i < 300; i = i + 1) begin
                clr();
                d_old = RB - m_free;                     // 窗口大小
                // push 批 (prefix, 0..3 条; 仅 free 足够)
                if (m_free > 0) begin
                    push_valid[0] = 1'b1;
                    if (m_free > 1 && ({$random} & 1)) push_valid[1] = 1'b1;
                    if (m_free > 2 && ({$random} & 1)) push_valid[2] = 1'b1;
                    if (m_free > 3 && ({$random} & 1)) push_valid[3] = 1'b1;
                end
                for (k = 0; k < IW; k = k + 1) begin
                    push_opcode[k * 7 +: 7]   = {$random} % 128;
                    push_rd[k * 5 +: 5]       = {$random} % 32;
                    push_new[k * PW +: PW]    = {$random} % PRF;
                    push_old[k * PW +: PW]    = {$random} % PRF;
                    push_lsq_tag[k * LW +: LW] = {$random} % LQ;
                    push_ins_raw[k * 32 +: 32] = {$random};
                end
                // set_ready 随机掩码
                for (k = 0; k < RB; k = k + 1)
                    set_ready_req[k] = ({$random} % 97) == 0;
                // set_head: 窗口内任意提交点 (含推进到 last → 清空)
                if (({$random} % 13) == 0) begin
                    set_head_valid = 1'b1;
                    set_head_val = m_head + ({$random} % (d_old + 1));
                end
                // set_last: 窗口内任意截断点 (含 head → 清空; 满窗口覆盖全槽)
                if (({$random} % 17) == 0) begin
                    set_last_valid = 1'b1;
                    set_last_val = m_head + ({$random} % (d_old + 1));
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
