// tb_lsq: 段 1 小规模+极端 (空态/push+set_addr 后发起/store 未执行阻塞 load/年龄仲裁/
//        低槽优先/flush 洞与 head 跳过/连续 flush 跳过/满态/环形回绕/同拍 push+invalidate/
//        同拍 push+set/字节合并最年轻优先/head 处 store 前递/符号扩展/store 不产 load_cdb/
//        done 抑制再发起/ld_busy 门控); 段 2 随机模型对照 (300 拍)
`timescale 1ns/1ps
module tb_lsq;
    localparam W   = 2;
    localparam LSQ = 16;
    localparam ROB = 32;
    localparam PRF = 64;
    localparam LW  = 4;
    localparam LCW = 5;
    localparam RW  = 5;
    localparam PW  = 6;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // DUT
    wire [LW - 1 : 0] head, last;
    wire full;
    wire [LCW - 1 : 0] free_count;
    wire [LSQ - 1 : 0] valid, is_load, addr_ready, data_ready;
    wire [LSQ * 32 - 1 : 0] addr, data;
    wire [LSQ * RW - 1 : 0] rob_tag;
    wire [LSQ * PW - 1 : 0] prs2_or_prd;
    wire [LSQ * 2 - 1 : 0]  width;
    wire [LSQ - 1 : 0] is_unsigned;
    reg  [RW - 1 : 0] rob_head;
    reg  [W - 1 : 0]  push_valid;
    reg  [W * RW - 1 : 0] push_rob_tag;
    reg  [W * PW - 1 : 0] push_prs2_or_prd;
    reg  [W * 2 - 1 : 0]  push_width;
    reg  [W - 1 : 0]  push_is_unsigned, push_is_load;
    reg  [W - 1 : 0]  set_addr_req, set_data_req;
    reg  [W * LW - 1 : 0] set_addr_idx, set_data_idx;
    reg  [W * 32 - 1 : 0] set_addr_val, set_data_val;
    reg  [LSQ - 1 : 0] flush_mask, invalidate;
    reg               mem_done_valid, ld_busy;
    reg  [LW - 1 : 0] mem_done_idx;
    reg  [31 : 0]     mem_done_data;
    wire              ld_start_valid;
    wire [31 : 0]     ld_start_addr;
    wire [1 : 0]      ld_start_width;
    wire [LW - 1 : 0] ld_start_idx;
    wire              load_cdb_valid, load_cdb_rob_wr;
    wire [PW - 1 : 0] load_cdb_prd;
    wire [RW - 1 : 0] load_cdb_rob_tag;
    wire [31 : 0]     load_cdb_result;
    lsq #(.ISSUE_WIDTH(W), .LSQ_SIZE(LSQ), .PRF_SIZE(PRF), .ROB_SIZE(ROB)) dut (
        .clk(clk), .rst_n(rst_n),
        .head(head), .last(last), .full(full), .free_count(free_count),
        .valid(valid), .is_load(is_load), .addr_ready(addr_ready), .data_ready(data_ready),
        .addr(addr), .data(data), .rob_tag(rob_tag), .prs2_or_prd(prs2_or_prd),
        .width(width), .is_unsigned(is_unsigned),
        .rob_head(rob_head),
        .push_valid(push_valid), .push_rob_tag(push_rob_tag),
        .push_prs2_or_prd(push_prs2_or_prd), .push_width(push_width),
        .push_is_unsigned(push_is_unsigned), .push_is_load(push_is_load),
        .set_addr_req(set_addr_req), .set_addr_idx(set_addr_idx), .set_addr_val(set_addr_val),
        .set_data_req(set_data_req), .set_data_idx(set_data_idx), .set_data_val(set_data_val),
        .flush_mask(flush_mask), .invalidate(invalidate),
        .mem_done_valid(mem_done_valid), .mem_done_idx(mem_done_idx),
        .mem_done_data(mem_done_data),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_busy(ld_busy),
        .load_cdb_valid(load_cdb_valid), .load_cdb_prd(load_cdb_prd),
        .load_cdb_result(load_cdb_result), .load_cdb_rob_tag(load_cdb_rob_tag),
        .load_cdb_rob_wr(load_cdb_rob_wr)
    );

    integer errors = 0;

    // ---- 模型 ----
    reg [LSQ - 1 : 0] m_valid, m_is_load, m_ardy, m_drdy, m_done, m_unsg;
    reg [LSQ * 32 - 1 : 0] m_addr, m_data;
    reg [LSQ * RW - 1 : 0] m_rob;
    reg [LSQ * PW - 1 : 0] m_preg;
    reg [LSQ * 2 - 1 : 0]  m_wid;
    reg [LW - 1 : 0] m_head, m_last;
    reg [LCW - 1 : 0] m_free;
    // 期望值 (tick 后重算)
    reg              e_ldv;
    reg [LW - 1 : 0] e_pidx;
    reg [31 : 0]     e_la;
    reg [1 : 0]      e_lw;
    reg              e_ok;
    reg [PW - 1 : 0] e_prd;
    reg [RW - 1 : 0] e_rob;
    reg [31 : 0]     e_res;

    // 字节合并 (镜像 DUT found-flag 语义): 找距离 < dd 且重叠的最年轻未提交 store
    function [7 : 0] mbyte;
        input [7 : 0]   b;
        input [31 : 0]  la;
        input [LW : 0]  dd;
        integer j;
        reg [LW - 1 : 0] bj;
        reg [LW : 0]     dj;
        reg [7 : 0]      bo;
        reg              found;
        begin
            found = 1'b0;
            bj = {LW{1'b0}};
            dj = {LW + 1{1'b0}};
            for (j = 0; j < LSQ; j = j + 1) begin
                if (m_valid[j] && !m_is_load[j] && m_ardy[j] && m_drdy[j]
                 && (((j - m_head) & (LSQ - 1)) < dd)
                 && ((la + b) >= m_addr[j * 32 +: 32])
                 && ((la + b) < (m_addr[j * 32 +: 32]
                               + ((m_wid[j * 2 +: 2] == 2'b10) ? 32'd4
                                  : (m_wid[j * 2 +: 2] == 2'b01) ? 32'd2 : 32'd1)))) begin
                    if (!found || (((j - m_head) & (LSQ - 1)) >= dj)) begin
                        found = 1'b1;
                        dj = (j - m_head) & (LSQ - 1);
                        bj = j;
                    end
                end
            end
            bo = (la + b - m_addr[bj * 32 +: 32]) * 8;
            mbyte = found ? m_data[bj * 32 + bo +: 8] : mem_done_data[b * 8 +: 8];
        end
    endfunction

    task clr_all;
        begin
            rob_head = 0;
            push_valid = 0; push_rob_tag = 0; push_prs2_or_prd = 0;
            push_width = 0; push_is_unsigned = 0; push_is_load = 0;
            set_addr_req = 0; set_addr_idx = 0; set_addr_val = 0;
            set_data_req = 0; set_data_idx = 0; set_data_val = 0;
            flush_mask = 0; invalidate = 0;
            mem_done_valid = 0; mem_done_idx = 0; mem_done_data = 0;
            ld_busy = 0;
        end
    endtask

    // 复位 DUT + 模型 (用例间重开窗口)
    task do_reset;
        begin
            clr_all();
            rst_n = 1'b0;
            #1; #8; #1;
            rst_n = 1'b1;
            #1; #8; #1;
            m_valid = 0; m_is_load = 0; m_ardy = 0; m_drdy = 0; m_done = 0; m_unsg = 0;
            m_addr = 0; m_data = 0; m_rob = 0; m_preg = 0; m_wid = 0;
            m_head = 0; m_last = 0; m_free = LSQ[LCW - 1 : 0];
        end
    endtask

    // tick: 驱动 → posedge → 模型更新 (镜像 DUT posedge 顺序与指针公式)
    task tick;
        integer s, k2;
        reg [LW : 0]     pwin;
        reg [LCW - 1 : 0] fskip, pcnt, off;
        reg [LSQ - 1 : 0] pv, pl;
        reg [LW - 1 : 0] ph, pls;
        reg [LCW - 1 : 0] pf;
        reg [LW : 0]     win;
        reg [LSQ : 0]    sok;
        reg [LSQ - 1 : 0] cand;
        reg              bad;
        reg [7 : 0]      b0, b1, b2, b3;
        reg [31 : 0]     la;
        reg [LW : 0]     dd;
        begin
            #1;
            #8;
            #1;
            // ---- 快照 pre 状态 (flush_skip/done 条件/psum 用) ----
            pv = m_valid;
            pl = m_is_load;
            ph = m_head;
            pls = m_last;
            pf = m_free;
            pwin = (pls - ph) & (LSQ - 1);
            fskip = 0;
            for (k2 = 0; (k2 < LSQ) && (k2 < pwin)
                     && flush_mask[(ph + k2) & (LSQ - 1)]; k2 = k2 + 1)
                fskip = fskip + 1'b1;
            pcnt = push_valid[0] + push_valid[1];
            // ---- 1) flush / invalidate 失效 ----
            m_valid = m_valid & ~flush_mask & ~invalidate;
            // ---- 2) push (last + psum; psum[1] = push_valid[0]) ----
            for (s = 0; s < W; s = s + 1) begin
                if (push_valid[s]) begin
                    off = (s == 0) ? 0 : push_valid[0];
                    m_valid[(pls + off) & (LSQ - 1)] = 1'b1;
                    m_is_load[(pls + off) & (LSQ - 1)] = push_is_load[s];
                    m_ardy[(pls + off) & (LSQ - 1)] = 1'b0;
                    m_drdy[(pls + off) & (LSQ - 1)] = 1'b0;
                    m_done[(pls + off) & (LSQ - 1)] = 1'b0;
                    m_rob[((pls + off) & (LSQ - 1)) * RW +: RW] = push_rob_tag[s * RW +: RW];
                    m_preg[((pls + off) & (LSQ - 1)) * PW +: PW] = push_prs2_or_prd[s * PW +: PW];
                    m_wid[((pls + off) & (LSQ - 1)) * 2 +: 2] = push_width[s * 2 +: 2];
                    m_unsg[(pls + off) & (LSQ - 1)] = push_is_unsigned[s];
                end
            end
            // ---- 3) set_addr / set_data ----
            for (s = 0; s < W; s = s + 1) begin
                if (set_addr_req[s]) begin
                    m_addr[set_addr_idx[s * LW +: LW] * 32 +: 32] = set_addr_val[s * 32 +: 32];
                    m_ardy[set_addr_idx[s * LW +: LW]] = 1'b1;
                end
                if (set_data_req[s]) begin
                    m_data[set_data_idx[s * LW +: LW] * 32 +: 32] = set_data_val[s * 32 +: 32];
                    m_drdy[set_data_idx[s * LW +: LW]] = 1'b1;
                end
            end
            // ---- 4) load 完成标记 (用 pre 有效性) ----
            if (mem_done_valid && pv[mem_done_idx] && pl[mem_done_idx])
                m_done[mem_done_idx] = 1'b1;
            // ---- 5) 指针更新 ----
            m_head = ph + fskip + (|invalidate);
            m_last = pls + pcnt;
            m_free = pf - pcnt + fskip + (|invalidate);
            // ---- 期望 (post 状态): 发起链 ----
            win = (m_last - m_head) & (LSQ - 1);
            sok[0] = 1'b1;
            for (k2 = 0; k2 < LSQ; k2 = k2 + 1) begin
                bad = m_valid[(m_head + k2) & (LSQ - 1)]
                   && !m_is_load[(m_head + k2) & (LSQ - 1)]
                   && !(m_ardy[(m_head + k2) & (LSQ - 1)] && m_drdy[(m_head + k2) & (LSQ - 1)]);
                sok[k2 + 1] = sok[k2] && !(bad && (k2 < win));
                cand[k2] = (k2 < win) && m_valid[(m_head + k2) & (LSQ - 1)]
                       && m_is_load[(m_head + k2) & (LSQ - 1)]
                       && m_ardy[(m_head + k2) & (LSQ - 1)]
                       && !m_done[(m_head + k2) & (LSQ - 1)] && sok[k2];
            end
            e_ldv = (|cand) && !ld_busy;
            e_pidx = 0;
            for (k2 = LSQ - 1; k2 >= 0; k2 = k2 - 1)
                if (cand[k2]) e_pidx = k2[LW - 1 : 0];
            e_la = m_addr[e_pidx * 32 +: 32];
            e_lw = m_wid[e_pidx * 2 +: 2];
            // ---- 期望: load_cdb ----
            e_ok = mem_done_valid && m_valid[mem_done_idx] && m_is_load[mem_done_idx];
            e_prd = m_preg[mem_done_idx * PW +: PW];
            e_rob = m_rob[mem_done_idx * RW +: RW];
            la = m_addr[mem_done_idx * 32 +: 32];
            dd = (mem_done_idx - m_head) & (LSQ - 1);
            b0 = mbyte(8'd0, la, dd);
            b1 = mbyte(8'd1, la, dd);
            b2 = mbyte(8'd2, la, dd);
            b3 = mbyte(8'd3, la, dd);
            e_res = (m_wid[mem_done_idx * 2 +: 2] == 2'b10) ? {b3, b2, b1, b0}
                  : (m_wid[mem_done_idx * 2 +: 2] == 2'b01)
                    ? (m_unsg[mem_done_idx] ? {16'd0, b1, b0} : {{16{b1[7]}}, b1, b0})
                    : (m_unsg[mem_done_idx] ? {24'd0, b0} : {{24{b0[7]}}, b0});
        end
    endtask

    task check_all;
        integer bad;
        begin
            bad = 0;
            if (head !== m_head || last !== m_last
             || full !== (m_free == 0) || free_count !== m_free) begin
                $display("FAIL: ptrs h=%0d l=%0d full=%b free=%0d expect h=%0d l=%0d free=%0d",
                         head, last, full, free_count, m_head, m_last, m_free);
                bad = bad + 1;
            end
            if (valid !== m_valid || is_load !== m_is_load
             || addr_ready !== m_ardy || data_ready !== m_drdy) begin
                $display("FAIL: masks v=%h il=%h ar=%h dr=%h expect v=%h il=%h ar=%h dr=%h",
                         valid, is_load, addr_ready, data_ready, m_valid, m_is_load, m_ardy, m_drdy);
                bad = bad + 1;
            end
            if (addr !== m_addr || data !== m_data || rob_tag !== m_rob
             || prs2_or_prd !== m_preg || width !== m_wid || is_unsigned !== m_unsg) begin
                $display("FAIL: content arrays");
                bad = bad + 1;
            end
            if (ld_start_valid !== e_ldv
             || (e_ldv && (ld_start_idx !== e_pidx
                        || ld_start_addr !== e_la || ld_start_width !== e_lw))) begin
                $display("FAIL: issue v=%b idx=%0d a=%h w=%b expect v=%b idx=%0d a=%h w=%b",
                         ld_start_valid, ld_start_idx, ld_start_addr, ld_start_width,
                         e_ldv, e_pidx, e_la, e_lw);
                bad = bad + 1;
            end
            if (load_cdb_valid !== e_ok || load_cdb_prd !== e_prd
             || load_cdb_rob_tag !== e_rob || load_cdb_rob_wr !== e_ok
             || load_cdb_result !== e_res) begin
                $display("FAIL: cdb v=%b prd=%0d tag=%0d wr=%b r=%h expect v=%b prd=%0d tag=%0d r=%h",
                         load_cdb_valid, load_cdb_prd, load_cdb_rob_tag, load_cdb_rob_wr,
                         load_cdb_result, e_ok, e_prd, e_rob, e_res);
                bad = bad + 1;
            end
            errors = errors + bad;
        end
    endtask

    // 驱动帮助: push 一个 load / store; set addr / data
    task push_load;
        input [RW - 1 : 0] t;
        input [PW - 1 : 0] p;
        input [1 : 0]      w;
        input              u;
        begin
            push_valid[0] = 1'b1;
            push_rob_tag[0 * RW +: RW] = t;
            push_prs2_or_prd[0 * PW +: PW] = p;
            push_width[0 * 2 +: 2] = w;
            push_is_unsigned[0] = u;
            push_is_load[0] = 1'b1;
        end
    endtask
    task push_store;
        input [RW - 1 : 0] t;
        input [PW - 1 : 0] p;
        input [1 : 0]      w;
        begin
            push_valid[0] = 1'b1;
            push_rob_tag[0 * RW +: RW] = t;
            push_prs2_or_prd[0 * PW +: PW] = p;
            push_width[0 * 2 +: 2] = w;
            push_is_unsigned[0] = 1'b0;
            push_is_load[0] = 1'b0;
        end
    endtask
    task set_a;
        input [LW - 1 : 0] ix;
        input [31 : 0]     v;
        begin
            set_addr_req[0] = 1'b1;
            set_addr_idx[0 * LW +: LW] = ix;
            set_addr_val[0 * 32 +: 32] = v;
        end
    endtask
    task set_d;
        input [LW - 1 : 0] ix;
        input [31 : 0]     v;
        begin
            set_data_req[0] = 1'b1;
            set_data_idx[0 * LW +: LW] = ix;
            set_data_val[0 * 32 +: 32] = v;
        end
    endtask

    initial begin
        $dumpfile("sim/core/tb_lsq.vcd");
        $dumpvars(0, tb_lsq);

        m_valid = 0; m_is_load = 0; m_ardy = 0; m_drdy = 0; m_done = 0; m_unsg = 0;
        m_addr = 0; m_data = 0; m_rob = 0; m_preg = 0; m_wid = 0;
        m_head = 0; m_last = 0; m_free = LSQ[LCW - 1 : 0];
        e_ldv = 0; e_pidx = 0; e_la = 0; e_lw = 0; e_ok = 0; e_prd = 0; e_rob = 0; e_res = 0;

        clr_all();
        #23 rst_n = 1;
        #1;

        // L1: 复位空态
        check_all();
        if (head !== 0 || last !== 0 || full !== 1'b0 || free_count !== 16) begin
            $display("FAIL: L1 reset state"); errors = errors + 1;
        end else begin
            $display("PASS: L1 reset empty");
        end

        // L2: push 一个 load → 无 addr 不可发起
        clr_all();
        push_load(3, 7, 2'b10, 1'b0);
        tick();
        check_all();
        if (last !== 1 || free_count !== 15 || valid[0] !== 1'b1
         || is_load[0] !== 1'b1 || addr_ready[0] !== 1'b0 || ld_start_valid !== 1'b0) begin
            $display("FAIL: L2 push load"); errors = errors + 1;
        end else begin
            $display("PASS: L2 push load, not issuable without addr");
        end

        // L3: set_addr → 可发起; ld_busy 门控
        clr_all();
        set_a(0, 32'h100);
        tick();
        check_all();
        if (addr_ready[0] !== 1'b1 || addr[0 * 32 +: 32] !== 32'h100
         || ld_start_valid !== 1'b1 || ld_start_idx !== 4'd0
         || ld_start_addr !== 32'h100 || ld_start_width !== 2'b10) begin
            $display("FAIL: L3a issue after set_addr"); errors = errors + 1;
        end
        ld_busy = 1'b1;
        tick();
        check_all();
        if (ld_start_valid !== 1'b0) begin
            $display("FAIL: L3b ld_busy gates"); errors = errors + 1;
        end
        ld_busy = 1'b0;
        tick();
        check_all();
        if (ld_start_valid !== 1'b1) begin
            $display("FAIL: L3c re-issue after busy"); errors = errors + 1;
        end else begin
            $display("PASS: L3 set_addr issue + ld_busy gating");
        end

        // L4: mem_done → load_cdb + done 抑制再发起
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd0; mem_done_data = 32'hDEADBEEF;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_prd !== 6'd7 || load_cdb_rob_tag !== 5'd3
         || load_cdb_rob_wr !== 1'b1 || load_cdb_result !== 32'hDEADBEEF) begin
            $display("FAIL: L4a load_cdb"); errors = errors + 1;
        end
        clr_all();
        tick();
        check_all();
        if (ld_start_valid !== 1'b0 || load_cdb_valid !== 1'b0) begin
            $display("FAIL: L4b done stops issue"); errors = errors + 1;
        end else begin
            $display("PASS: L4 load_cdb + done");
        end

        // L5: 未执行 store 阻塞年轻 load; 执行后放行
        do_reset();
        clr_all();
        push_store(1, 0, 2'b10);
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 2;
        push_prs2_or_prd[1 * PW +: PW] = 8;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_unsigned[1] = 1'b0;
        push_is_load[1] = 1'b1;
        tick();
        check_all();
        if (ld_start_valid !== 1'b0) begin
            $display("FAIL: L5a store blocks load"); errors = errors + 1;
        end
        clr_all();
        set_a(0, 32'h100); set_d(0, 32'hABCDEF00);
        set_addr_req[1] = 1'b1;
        set_addr_idx[1 * LW +: LW] = 4'd1;
        set_addr_val[1 * 32 +: 32] = 32'h100;
        tick();
        check_all();
        if (ld_start_valid !== 1'b1 || ld_start_idx !== 4'd1) begin
            $display("FAIL: L5b store executed unblocks (v=%b idx=%0d)",
                     ld_start_valid, ld_start_idx);
            errors = errors + 1;
        end else begin
            $display("PASS: L5 store ordering");
        end

        // L6: 年龄仲裁 — 老 load 无 addr 时年轻 load 发起; 老 load 就绪后老优先
        do_reset();
        clr_all();
        push_load(10, 10, 2'b10, 1'b0);   // 槽0, 老
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 11;
        push_prs2_or_prd[1 * PW +: PW] = 11;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        tick();
        clr_all();
        set_addr_req[1] = 1'b1;
        set_addr_idx[1 * LW +: LW] = 4'd1;
        set_addr_val[1 * 32 +: 32] = 32'h200;
        tick();
        check_all();
        if (ld_start_valid !== 1'b1 || ld_start_idx !== 4'd1) begin
            $display("FAIL: L6a younger issues (v=%b idx=%0d)", ld_start_valid, ld_start_idx);
            errors = errors + 1;
        end
        clr_all();
        set_a(0, 32'h200);
        tick();
        check_all();
        if (ld_start_valid !== 1'b1 || ld_start_idx !== 4'd0) begin
            $display("FAIL: L6b oldest wins (v=%b idx=%0d)", ld_start_valid, ld_start_idx);
            errors = errors + 1;
        end else begin
            $display("PASS: L6 age arbitration");
        end

        // L7: flush 洞 (非 head) + invalidate 推进 head
        do_reset();
        clr_all();
        push_load(0, 1, 2'b10, 1'b0);
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 1;
        push_prs2_or_prd[1 * PW +: PW] = 2;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        tick();   // 槽0,1
        clr_all();
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 2;
        push_prs2_or_prd[1 * PW +: PW] = 3;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        tick();   // 槽2
        clr_all();
        flush_mask = 16'h0002;   // 洞在距离 1 (非 head)
        invalidate = 16'h0001;   // head 处失效
        tick();
        check_all();
        if (valid[1] !== 1'b0 || head !== 4'd1 || free_count !== 14) begin
            $display("FAIL: L7 flush hole (v=%h h=%0d free=%0d)", valid, head, free_count);
            errors = errors + 1;
        end
        clr_all();
        invalidate = 16'h0002;   // head 推进到洞 → 跳过
        tick();
        check_all();
        if (head !== 4'd2 || free_count !== 15) begin
            $display("FAIL: L7 skip hole (h=%0d free=%0d)", head, free_count);
            errors = errors + 1;
        end else begin
            $display("PASS: L7 flush hole + head skip");
        end

        // L8: 连续 flush 在 head → flush_skip 一步跳过
        do_reset();
        clr_all();
        push_load(0, 1, 2'b10, 1'b0);
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 1;
        push_prs2_or_prd[1 * PW +: PW] = 2;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        tick();
        clr_all();
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 2;
        push_prs2_or_prd[1 * PW +: PW] = 3;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        tick();
        clr_all();
        flush_mask = 16'h0003;   // 距离 0,1 全 flush
        tick();
        check_all();
        if (head !== 4'd2 || last !== 4'd3 || free_count !== 15) begin
            $display("FAIL: L8 flush skip (h=%0d l=%0d free=%0d)", head, last, free_count);
            errors = errors + 1;
        end else begin
            $display("PASS: L8 consecutive flush skip");
        end

        // L9: 同拍 push + invalidate → free 净变化 0
        do_reset();
        clr_all();
        push_load(0, 1, 2'b10, 1'b0);
        tick();
        clr_all();
        push_load(1, 2, 2'b10, 1'b0);
        invalidate = 16'h0001;
        tick();
        check_all();
        if (head !== 4'd1 || last !== 4'd2 || free_count !== 15) begin
            $display("FAIL: L9 push+invalidate (h=%0d l=%0d free=%0d)", head, last, free_count);
            errors = errors + 1;
        end else begin
            $display("PASS: L9 push + invalidate same cycle");
        end

        // L10: 满态 full (8 拍 × 2 push = 16)
        do_reset();
        begin : l10
            integer i2;
            for (i2 = 0; i2 < 8; i2 = i2 + 1) begin
                clr_all();
                push_valid[0] = 1'b1; push_valid[1] = 1'b1;
                push_rob_tag[0 * RW +: RW] = i2 * 2;
                push_rob_tag[1 * RW +: RW] = i2 * 2 + 1;
                push_prs2_or_prd[0 * PW +: PW] = i2 * 2 + 1;
                push_prs2_or_prd[1 * PW +: PW] = i2 * 2 + 2;
                push_width[0 * 2 +: 2] = 2'b10;
                push_width[1 * 2 +: 2] = 2'b10;
                push_is_load[0] = 1'b1; push_is_load[1] = 1'b1;
                tick();
            end
        end
        clr_all();
        check_all();
        if (!full || free_count !== 0 || last !== 4'd0 || valid !== 16'hFFFF) begin
            $display("FAIL: L10 full (full=%b free=%0d last=%0d v=%h)", full, free_count, last, valid);
            errors = errors + 1;
        end else begin
            $display("PASS: L10 full state (ring wraps)");
        end

        // L11: 字节合并前向 — 最年轻重叠 store 赢, 不重叠字节用 mem
        do_reset();
        clr_all();
        push_store(1, 0, 2'b10);          // 槽0: store A @0x40 4B
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 2;
        push_prs2_or_prd[1 * PW +: PW] = 0;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_unsigned[1] = 1'b0;
        push_is_load[1] = 1'b0;           // 槽1: store B @0x42 4B (年轻)
        tick();
        clr_all();
        push_load(7, 5, 2'b10, 1'b0);     // 槽2: load @0x40 4B
        tick();
        clr_all();
        set_a(0, 32'h40); set_d(0, 32'hAABBCCDD);
        set_addr_req[1] = 1'b1;
        set_addr_idx[1 * LW +: LW] = 4'd1;
        set_addr_val[1 * 32 +: 32] = 32'h42;
        set_data_req[1] = 1'b1;
        set_data_idx[1 * LW +: LW] = 4'd1;
        set_data_val[1 * 32 +: 32] = 32'h11223344;
        tick();
        clr_all();
        set_a(2, 32'h40);
        tick();
        check_all();
        if (ld_start_valid !== 1'b1 || ld_start_idx !== 4'd2) begin
            $display("FAIL: L11 load not issuable"); errors = errors + 1;
        end
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd2; mem_done_data = 32'hDEADBEEF;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_result !== 32'h3344CCDD) begin
            $display("FAIL: L11 merge (r=%h)", load_cdb_result);
            errors = errors + 1;
        end else begin
            $display("PASS: L11 byte merge youngest store wins");
        end

        // L11b: head 处 (距离 0) store 也前递 — found 标志语义
        do_reset();
        clr_all();
        push_store(5, 0, 2'b10);          // 槽0 = head: store @0x80 4B
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 6;
        push_prs2_or_prd[1 * PW +: PW] = 1;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_unsigned[1] = 1'b0;
        push_is_load[1] = 1'b1;           // 槽1: load @0x80
        tick();
        clr_all();
        set_a(0, 32'h80); set_d(0, 32'hCAFEBABE);
        set_addr_req[1] = 1'b1;
        set_addr_idx[1 * LW +: LW] = 4'd1;
        set_addr_val[1 * 32 +: 32] = 32'h80;
        tick();
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd1; mem_done_data = 32'h0;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_prd !== 6'd1 || load_cdb_result !== 32'hCAFEBABE) begin
            $display("FAIL: L11b head store forwards (r=%h)", load_cdb_result);
            errors = errors + 1;
        end else begin
            $display("PASS: L11b head-entry store forwarding");
        end

        // L12: 符号扩展 (00=1 字节 lb/lbu; 01=2 字节 lh/lhu)
        do_reset();
        clr_all();
        push_load(7, 20, 2'b00, 1'b0);    // 槽0: signed lb
        tick();
        clr_all();
        set_a(0, 32'h90);
        tick();
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd0; mem_done_data = 32'h00000080;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_result !== 32'hFFFFFF80) begin
            $display("FAIL: L12a signed ext (r=%h)", load_cdb_result);
            errors = errors + 1;
        end
        clr_all();
        push_load(8, 21, 2'b00, 1'b1);    // 槽1: unsigned lbu
        tick();
        clr_all();
        set_a(1, 32'h90);
        tick();
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd1; mem_done_data = 32'h00000080;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_result !== 32'h00000080) begin
            $display("FAIL: L12b unsigned (r=%h)", load_cdb_result);
            errors = errors + 1;
        end
        clr_all();
        push_load(9, 22, 2'b01, 1'b0);    // 槽2: signed lh (2 字节)
        tick();
        clr_all();
        set_a(2, 32'h90);
        tick();
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd2; mem_done_data = 32'h0000FF80;
        tick();
        check_all();
        if (!load_cdb_valid || load_cdb_result !== 32'hFFFFFF80) begin
            $display("FAIL: L12c signed lh (r=%h)", load_cdb_result);
            errors = errors + 1;
        end else begin
            $display("PASS: L12 sign extension signed/unsigned");
        end

        // L13: store 的 mem_done 不产 load_cdb; 不置 done
        do_reset();
        clr_all();
        push_store(9, 0, 2'b10);          // 槽0: store
        tick();
        clr_all();
        set_a(0, 32'h100); set_d(0, 32'h12345678);
        tick();
        clr_all();
        mem_done_valid = 1'b1; mem_done_idx = 4'd0; mem_done_data = 32'h0;
        tick();
        check_all();
        if (load_cdb_valid !== 1'b0 || m_done[0] !== 1'b0) begin
            $display("FAIL: L13 store no cdb"); errors = errors + 1;
        end else begin
            $display("PASS: L13 store ignores mem_done");
        end

        // L14: 同拍 push + set → 新条目直接就绪
        do_reset();
        clr_all();
        push_load(10, 22, 2'b10, 1'b0);
        push_valid[1] = 1'b1;
        push_rob_tag[1 * RW +: RW] = 11;
        push_prs2_or_prd[1 * PW +: PW] = 23;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[1] = 1'b1;
        set_a(0, 32'h200);
        tick();
        check_all();
        if (valid[0] !== 1'b1 || addr_ready[0] !== 1'b1
         || ld_start_valid !== 1'b1 || ld_start_idx !== 4'd0) begin
            $display("FAIL: L14 push+set same cycle (v=%b ar=%b lsv=%b idx=%0d)",
                     valid[0], addr_ready[0], ld_start_valid, ld_start_idx);
            errors = errors + 1;
        end else begin
            $display("PASS: L14 push + set_addr same cycle");
        end

        // L15: 环形回绕 — 满态后 invalidate×3 + push 3 → 指针回绕
        do_reset();
        begin : l15
            integer i2;
            for (i2 = 0; i2 < 8; i2 = i2 + 1) begin
                clr_all();
                push_valid[0] = 1'b1; push_valid[1] = 1'b1;
                push_rob_tag[0 * RW +: RW] = i2 * 2;
                push_rob_tag[1 * RW +: RW] = i2 * 2 + 1;
                push_prs2_or_prd[0 * PW +: PW] = i2 * 2 + 1;
                push_prs2_or_prd[1 * PW +: PW] = i2 * 2 + 2;
                push_width[0 * 2 +: 2] = 2'b10;
                push_width[1 * 2 +: 2] = 2'b10;
                push_is_load[0] = 1'b1; push_is_load[1] = 1'b1;
                tick();
            end
        end
        clr_all();
        invalidate = 16'h0001; tick();
        clr_all();
        invalidate = 16'h0002; tick();
        clr_all();
        invalidate = 16'h0004; tick();   // head=3, free=3
        clr_all();
        push_valid[0] = 1'b1; push_valid[1] = 1'b1;
        push_rob_tag[0 * RW +: RW] = 30;
        push_rob_tag[1 * RW +: RW] = 31;
        push_prs2_or_prd[0 * PW +: PW] = 30;
        push_prs2_or_prd[1 * PW +: PW] = 31;
        push_width[0 * 2 +: 2] = 2'b10;
        push_width[1 * 2 +: 2] = 2'b10;
        push_is_load[0] = 1'b1; push_is_load[1] = 1'b1;
        tick();   // 槽0,1
        clr_all();
        push_load(32, 32, 2'b10, 1'b0);
        tick();   // 槽2
        clr_all();
        check_all();
        if (last !== 4'd3 || head !== 4'd3 || free_count !== 0 || full !== 1'b1
         || valid !== 16'hFFFF) begin
            $display("FAIL: L15 wrap (h=%0d l=%0d free=%0d v=%h)", head, last, free_count, valid);
            errors = errors + 1;
        end else begin
            $display("PASS: L15 ring wrap");
        end

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer i2, s2, k2;
            reg [LSQ - 1 : 0] winm;
            for (i2 = 0; i2 < 300; i2 = i2 + 1) begin
                clr_all();
                // 随机 flush (窗口内随机距离起的子集)
                if (($random & 7) == 0) begin
                    k2 = {$random} & 15;
                    winm = (last - head) & (LSQ - 1);
                    for (s2 = k2; s2 < LSQ; s2 = s2 + 1)
                        if (s2 < winm) flush_mask[(head + s2) & (LSQ - 1)] = 1'b1;
                end
                // 随机 invalidate (head 处, cpu_top 语义)
                if (($random & 7) == 1) invalidate[head] = 1'b1;
                // 随机 push (按 free_count 门控)
                if (free_count >= 2 && (($random & 1) == 0)) begin
                    push_valid[0] = 1'b1;
                    push_rob_tag[0 * RW +: RW] = {$random} & 31;
                    push_prs2_or_prd[0 * PW +: PW] = 1 + ({$random} & 62);
                    push_width[0 * 2 +: 2] = (($random) & 3) == 0 ? 2'b00
                                           : (($random) & 3) == 0 ? 2'b01 : 2'b10;
                    push_is_unsigned[0] = ($random) & 1;
                    push_is_load[0] = ($random) & 1;
                    if ((($random) & 1) == 0) begin
                        push_valid[1] = 1'b1;
                        push_rob_tag[1 * RW +: RW] = {$random} & 31;
                        push_prs2_or_prd[1 * PW +: PW] = 1 + ({$random} & 62);
                        push_width[1 * 2 +: 2] = (($random) & 3) == 0 ? 2'b00
                                               : (($random) & 3) == 0 ? 2'b01 : 2'b10;
                        push_is_unsigned[1] = ($random) & 1;
                        push_is_load[1] = ($random) & 1;
                    end
                end else if (free_count >= 1 && (($random) & 3) == 0) begin
                    push_valid[0] = 1'b1;
                    push_rob_tag[0 * RW +: RW] = {$random} & 31;
                    push_prs2_or_prd[0 * PW +: PW] = 1 + ({$random} & 62);
                    push_width[0 * 2 +: 2] = (($random) & 3) == 0 ? 2'b00
                                           : (($random) & 3) == 0 ? 2'b01 : 2'b10;
                    push_is_unsigned[0] = ($random) & 1;
                    push_is_load[0] = ($random) & 1;
                end
                // 随机 set_addr / set_data
                if ((($random) & 3) == 0) begin
                    set_addr_req[0] = 1'b1;
                    set_addr_idx[0 * LW +: LW] = {$random} & 15;
                    set_addr_val[0 * 32 +: 32] = ({$random} & 32'h3FFF) * 4;
                end
                if ((($random) & 3) == 1) begin
                    set_data_req[0] = 1'b1;
                    set_data_idx[0 * LW +: LW] = {$random} & 15;
                    set_data_val[0 * 32 +: 32] = {$random};
                end
                // 随机 mem_done (偏置指向有效 load)
                if ((($random) & 3) == 0) begin
                    mem_done_valid = 1'b1;
                    if ((($random) & 1) == 0) begin
                        mem_done_idx = {$random} & 15;
                    end else begin
                        mem_done_idx = 0;
                        for (s2 = 0; s2 < LSQ; s2 = s2 + 1)
                            if (m_valid[s2] && m_is_load[s2]) mem_done_idx = s2[LW - 1 : 0];
                    end
                    mem_done_data = {$random};
                end
                // 随机 ld_busy
                if ((($random) & 7) == 0) ld_busy = 1'b1;
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
