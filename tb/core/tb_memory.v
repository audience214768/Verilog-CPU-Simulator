// tb_memory: 段 1 小规模+极端 (init 字节写/取指同步读+小端打包/load 倒计时 LATENCY/
//        宽度 1-2-4 字节/LATENCY=1 与 6 边界/飞行槽满与释放/idx 回传/store 直写/init 覆盖 sw);
//        段 2 随机模型对照 (300 拍, inst_data/done/busy 逐拍断言)
`timescale 1ns/1ps
module tb_memory;
    localparam IW  = 2;
    localparam MSZ = 65536;
    localparam LAT = 3;
    localparam INF = 4;
    localparam LSQ = 16;
    localparam LW  = 4;
    localparam CNTW = 2;   // clog2(LAT+1)

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // 主实例 (LATENCY=3)
    wire [IW * 32 - 1 : 0] inst_data;
    reg  [IW * 32 - 1 : 0] imem_addr;
    reg  ld_start_valid;
    reg  [31 : 0] ld_start_addr;
    reg  [1 : 0]  ld_start_width;
    reg  [LW - 1 : 0] ld_start_idx;
    wire ld_done_valid, ld_busy;
    wire [LW - 1 : 0] ld_done_idx;
    wire [31 : 0] ld_done_data;
    reg  sw_valid;
    reg  [31 : 0] sw_addr, sw_data;
    reg  [1 : 0]  sw_width;
    reg  init_valid;
    reg  [31 : 0] init_addr;
    reg  [7 : 0]  init_data;
    memory #(.ISSUE_WIDTH(IW), .MEM_SIZE(MSZ), .MEM_LATENCY(LAT),
             .MEM_INFLIGHT(INF), .LSQ_SIZE(LSQ)) dut (
        .clk(clk), .rst_n(rst_n),
        .inst_data(inst_data), .imem_addr(imem_addr),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx), .ld_done_data(ld_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .init_valid(init_valid), .init_addr(init_addr), .init_data(init_data)
    );

    // 边界实例: LATENCY=1 (最短) / 6 (满槽条件 LATENCY > INFLIGHT)
    wire [31 : 0] d1_data;
    wire d1_valid, d1_busy;
    wire [LW - 1 : 0] d1_idx;
    wire [31 : 0] d1_ok;
    reg  d1_start;
    reg  [31 : 0] d1_addr;
    memory #(.ISSUE_WIDTH(1), .MEM_SIZE(MSZ), .MEM_LATENCY(1),
             .MEM_INFLIGHT(INF), .LSQ_SIZE(LSQ)) u_mem1 (
        .clk(clk), .rst_n(rst_n),
        .inst_data(d1_data), .imem_addr(32'd0),
        .ld_start_valid(d1_start), .ld_start_addr(d1_addr),
        .ld_start_width(2'b10), .ld_start_idx(4'd0),
        .ld_done_valid(d1_valid), .ld_done_idx(d1_idx), .ld_done_data(d1_ok),
        .ld_busy(d1_busy),
        .sw_valid(1'b0), .sw_addr(32'd0), .sw_data(32'd0), .sw_width(2'b00),
        .init_valid(1'b0), .init_addr(32'd0), .init_data(8'd0)
    );
    wire [31 : 0] d2_data;
    wire d2_valid, d2_busy;
    wire [LW - 1 : 0] d2_idx;
    wire [31 : 0] d2_ok;
    reg  d2_start;
    reg  [31 : 0] d2_addr;
    reg  [LW - 1 : 0] d2_idx_in;
    memory #(.ISSUE_WIDTH(1), .MEM_SIZE(MSZ), .MEM_LATENCY(6),
             .MEM_INFLIGHT(INF), .LSQ_SIZE(LSQ)) u_mem2 (
        .clk(clk), .rst_n(rst_n),
        .inst_data(d2_data), .imem_addr(32'd0),
        .ld_start_valid(d2_start), .ld_start_addr(d2_addr),
        .ld_start_width(2'b10), .ld_start_idx(d2_idx_in),
        .ld_done_valid(d2_valid), .ld_done_idx(d2_idx), .ld_done_data(d2_ok),
        .ld_busy(d2_busy),
        .sw_valid(1'b0), .sw_addr(32'd0), .sw_data(32'd0), .sw_width(2'b00),
        .init_valid(1'b0), .init_addr(32'd0), .init_data(8'd0)
    );

    integer errors = 0;
    integer i;

    // ---- 模型 (主实例) ----
    reg [7 : 0] m_mem [0 : MSZ - 1];
    reg [INF - 1 : 0]   m_sv;
    reg [INF * CNTW - 1 : 0] m_cnt;
    reg [INF * 32 - 1 : 0] m_sa;
    reg [INF * 2 - 1 : 0] m_sw;
    reg [INF * LW - 1 : 0] m_si;
    reg [IW * 32 - 1 : 0] m_imem_r;
    reg m_dv;
    reg [LW - 1 : 0] m_di;
    reg [31 : 0] m_dd;

    function [31 : 0] rdx;
        input [31 : 0] a;
        begin
            rdx = {m_mem[a + 3], m_mem[a + 2], m_mem[a + 1], m_mem[a]};
        end
    endfunction
    function [31 : 0] rdw;
        input [31 : 0] a;
        input [1 : 0]  w;
        begin
            rdw = (w == 2'b10) ? rdx(a)
                : (w == 2'b01) ? {16'd0, m_mem[a + 1], m_mem[a]}
                : {24'd0, m_mem[a]};
        end
    endfunction

    task clr_all;
        begin
            imem_addr = 0; ld_start_valid = 0; ld_start_addr = 0;
            ld_start_width = 2'b00; ld_start_idx = 0;
            sw_valid = 0; sw_addr = 0; sw_data = 0; sw_width = 2'b00;
            init_valid = 0; init_addr = 0; init_data = 8'd0;
            d1_start = 0; d1_addr = 0;
            d2_start = 0; d2_addr = 0; d2_idx_in = 0;
        end
    endtask

    // tick 内时序: 模型先按旧状态算 free (发起选择), 再倒计时/完成, 再发起 (旧 free),
    // 再写 mem (sw 先 init 后), 再寄存取指地址 — 与 DUT posedge 完全一致
    task tick;
        integer s2;
        reg [INF - 1 : 0] m_free;
        reg m_taken;
        begin
            #1;
            #8;
            #1;
            m_free = 0;
            for (s2 = 0; s2 < INF; s2 = s2 + 1)
                m_free[s2] = !m_sv[s2] || (m_cnt[s2 * CNTW +: CNTW] == 1);
            m_dv = 0;
            for (s2 = 0; s2 < INF; s2 = s2 + 1) begin
                if (m_sv[s2]) begin
                    if (m_cnt[s2 * CNTW +: CNTW] == 1) begin
                        m_sv[s2] = 1'b0;
                        m_dv = 1'b1;
                        m_di = m_si[s2 * LW +: LW];
                        m_dd = rdw(m_sa[s2 * 32 +: 32], m_sw[s2 * 2 +: 2]);
                    end else begin
                        m_cnt[s2 * CNTW +: CNTW] = m_cnt[s2 * CNTW +: CNTW] - 1'b1;
                    end
                end
            end
            m_taken = 1'b0;
            if (ld_start_valid) begin
                for (s2 = 0; s2 < INF; s2 = s2 + 1) begin
                    if (!m_taken && m_free[s2]) begin
                        m_sv[s2] = 1'b1;
                        m_cnt[s2 * CNTW +: CNTW] = LAT[CNTW - 1 : 0];
                        m_sa[s2 * 32 +: 32] = ld_start_addr;
                        m_sw[s2 * 2 +: 2]  = ld_start_width;
                        m_si[s2 * LW +: LW] = ld_start_idx;
                        m_taken = 1'b1;
                    end
                end
            end
            if (sw_valid) begin
                m_mem[sw_addr] = sw_data[7 : 0];
                if (sw_width != 2'b00) m_mem[sw_addr + 1] = sw_data[15 : 8];
                if (sw_width == 2'b10) begin
                    m_mem[sw_addr + 2] = sw_data[23 : 16];
                    m_mem[sw_addr + 3] = sw_data[31 : 24];
                end
            end
            if (init_valid) m_mem[init_addr] = init_data;
            m_imem_r = imem_addr;
        end
    endtask

    task check_all;
        integer li, bad;
        reg [INF - 1 : 0] m_free2;
        begin
            bad = 0;
            for (li = 0; li < IW; li = li + 1)
                if (inst_data[li * 32 +: 32] !== rdx(m_imem_r[li * 32 +: 32])) begin
                    $display("FAIL: inst_data[%0d] = %h expect %h", li,
                             inst_data[li * 32 +: 32], rdx(m_imem_r[li * 32 +: 32]));
                    bad = bad + 1;
                end
            if (ld_done_valid !== m_dv
             || (m_dv && (ld_done_idx !== m_di || ld_done_data !== m_dd))) begin
                $display("FAIL: ld_done v=%b idx=%h data=%h expect v=%b idx=%h data=%h",
                         ld_done_valid, ld_done_idx, ld_done_data, m_dv, m_di, m_dd);
                bad = bad + 1;
            end
            m_free2 = 0;
            for (li = 0; li < INF; li = li + 1)
                m_free2[li] = !m_sv[li] || (m_cnt[li * CNTW +: CNTW] == 1);
            if (ld_busy !== !(|m_free2)) begin
                $display("FAIL: ld_busy = %b expect %b", ld_busy, !(|m_free2));
                bad = bad + 1;
            end
            errors = errors + bad;
        end
    endtask

    initial begin
        $dumpfile("sim/core/tb_memory.vcd");
        $dumpvars(0, tb_memory);

        for (i = 0; i < MSZ; i = i + 1) m_mem[i] = 8'd0;
        m_sv = 0; m_cnt = 0; m_sa = 0; m_sw = 0; m_si = 0; m_imem_r = 0;
        m_dv = 0; m_di = 0; m_dd = 0;

        clr_all();
        #23 rst_n = 1;
        #1;

        // M1: init 字节写 + 取指同步读 (延迟 1 拍) + 小端打包
        init_valid = 1'b1;
        init_addr = 32'h100; init_data = 8'h11; tick();
        init_addr = 32'h101; init_data = 8'h22; tick();
        init_addr = 32'h102; init_data = 8'h33; tick();
        init_addr = 32'h103; init_data = 8'h44; tick();
        clr_all();
        imem_addr = 32'h100;
        tick();
        check_all();
        if (inst_data[0 * 32 +: 32] !== 32'h44332211) begin
            $display("FAIL: M1 inst pack (got %h)", inst_data[0 * 32 +: 32]);
            errors = errors + 1;
        end else begin
            $display("PASS: M1 init + fetch sync read");
        end

        // M2: 地址寄存 1 拍 (posedge 后改地址, inst_data 保持旧地址到下一拍)
        clr_all();
        imem_addr = 32'h200;
        if (inst_data[0 * 32 +: 32] !== 32'h44332211) begin
            $display("FAIL: M2 addr reg delay (got %h)", inst_data[0 * 32 +: 32]);
            errors = errors + 1;
        end
        tick();
        check_all();
        if (inst_data[0 * 32 +: 32] !== 32'h0) begin
            $display("FAIL: M2 new addr read (got %h)", inst_data[0 * 32 +: 32]);
            errors = errors + 1;
        end else begin
            $display("PASS: M2 imem addr registered 1 cycle");
        end

        // M3: load 倒计时 (LATENCY=3): 发起后第 1/2 拍无完成, 第 3 拍完成
        clr_all();
        init_valid = 1'b1; init_addr = 32'h300; init_data = 8'hAA; tick();
        init_addr = 32'h301; init_data = 8'hBB; tick();
        init_addr = 32'h302; init_data = 8'hCC; tick();
        init_addr = 32'h303; init_data = 8'hDD; tick();
        clr_all();
        ld_start_valid = 1'b1; ld_start_addr = 32'h300;
        ld_start_width = 2'b10; ld_start_idx = 4'd0;
        tick();
        ld_start_valid = 1'b0;
        check_all();
        if (ld_done_valid) begin
            $display("FAIL: M3 done too early"); errors = errors + 1;
        end
        tick(); tick();
        check_all();
        if (ld_done_valid) begin
            $display("FAIL: M3 done too early (t+2)"); errors = errors + 1;
        end
        tick();
        check_all();
        if (!ld_done_valid || ld_done_idx !== 4'd0 || ld_done_data !== 32'hDDCCBBAA) begin
            $display("FAIL: M3 load done (v=%b i=%h d=%h)", ld_done_valid,
                     ld_done_idx, ld_done_data);
            errors = errors + 1;
        end else begin
            $display("PASS: M3 load latency 3");
        end

        // M4: 宽度 1/2 字节零扩展
        clr_all();
        init_valid = 1'b1; init_addr = 32'h400; init_data = 8'h7F; tick();
        init_addr = 32'h401; init_data = 8'h80; tick();
        clr_all();
        ld_start_valid = 1'b1; ld_start_addr = 32'h400;
        ld_start_width = 2'b00; ld_start_idx = 4'd1;
        tick();
        ld_start_valid = 1'b0;
        tick(); tick(); tick();
        check_all();
        if (!ld_done_valid || ld_done_data !== 32'h0000007F) begin
            $display("FAIL: M4a width 1 (d=%h)", ld_done_data); errors = errors + 1;
        end
        clr_all();
        ld_start_valid = 1'b1; ld_start_addr = 32'h400;
        ld_start_width = 2'b01; ld_start_idx = 4'd1;
        tick();
        ld_start_valid = 1'b0;
        tick(); tick(); tick();
        check_all();
        if (!ld_done_valid || ld_done_data !== 32'h0000807F) begin
            $display("FAIL: M4b width 2 (d=%h)", ld_done_data); errors = errors + 1;
        end else begin
            $display("PASS: M4 load widths 1/2");
        end

        // M5: 飞行槽满 (LATENCY=6 > INFLIGHT=4): 4 连发后 busy,
        //      cnt 到 1 (到期拍) 时释放, 再 1 拍后完成
        clr_all();
        d2_start = 1'b1;
        d2_addr = 32'h500;
        d2_idx_in = 4'd0; tick();
        d2_idx_in = 4'd1; tick();
        d2_idx_in = 4'd2; tick();
        d2_idx_in = 4'd3; tick();
        d2_start = 1'b0;
        check_all();
        if (!d2_busy) begin
            $display("FAIL: M5 inflight full"); errors = errors + 1;
        end
        tick();
        check_all();
        if (!d2_busy) begin
            $display("FAIL: M5 full before cnt=1"); errors = errors + 1;
        end
        tick();
        check_all();
        if (d2_busy) begin
            $display("FAIL: M5 busy not released at cnt=1"); errors = errors + 1;
        end
        tick();
        check_all();
        if (!d2_valid || d2_idx !== 4'd0 || d2_ok !== 32'h0) begin
            $display("FAIL: M5 first done (v=%b i=%h d=%h)", d2_valid, d2_idx, d2_ok);
            errors = errors + 1;
        end else begin
            $display("PASS: M5 inflight slots full/release/done");
        end

        // M6: LATENCY=1 边界 (发起拍后 1 拍完成)
        clr_all();
        d1_start = 1'b1; d1_addr = 32'h600; tick();
        d1_start = 1'b0;
        if (d1_valid) begin
            $display("FAIL: M6 latency1 too early"); errors = errors + 1;
        end
        tick();
        check_all();
        if (!d1_valid || d1_ok !== 32'h0) begin
            $display("FAIL: M6 latency1 (v=%b d=%h)", d1_valid, d1_ok);
            errors = errors + 1;
        end else begin
            $display("PASS: M6 latency=1 edge");
        end

        // M7: 乱序槽 idx 回传 (两个 load 交错)
        clr_all();
        init_valid = 1'b1; init_addr = 32'h700; init_data = 8'h01; tick();
        init_addr = 32'h701; init_data = 8'h02; tick();
        init_addr = 32'h702; init_data = 8'h03; tick();
        init_addr = 32'h703; init_data = 8'h04; tick();
        clr_all();
        ld_start_valid = 1'b1; ld_start_addr = 32'h700;
        ld_start_width = 2'b10; ld_start_idx = 4'd2;
        tick();
        ld_start_idx = 4'd5;
        tick();
        ld_start_valid = 1'b0;
        tick(); tick();
        check_all();
        if (!ld_done_valid || ld_done_idx !== 4'd2) begin
            $display("FAIL: M7a first done idx (i=%h)", ld_done_idx);
            errors = errors + 1;
        end
        tick();
        check_all();
        if (!ld_done_valid || ld_done_idx !== 4'd5) begin
            $display("FAIL: M7b second done idx (i=%h)", ld_done_idx);
            errors = errors + 1;
        end else begin
            $display("PASS: M7 slot idx passback");
        end

        // M8: store 直写后 load 读到新值
        clr_all();
        sw_valid = 1'b1; sw_addr = 32'h800; sw_data = 32'hA5A5A5A5; sw_width = 2'b10;
        tick();
        sw_valid = 1'b0;
        ld_start_valid = 1'b1; ld_start_addr = 32'h800;
        ld_start_width = 2'b10; ld_start_idx = 4'd0;
        tick();
        ld_start_valid = 1'b0;
        tick(); tick(); tick();
        check_all();
        if (!ld_done_valid || ld_done_data !== 32'hA5A5A5A5) begin
            $display("FAIL: M8 store then load (d=%h)", ld_done_data);
            errors = errors + 1;
        end else begin
            $display("PASS: M8 store direct write");
        end

        // M9: 同拍 sw + init 同地址 → init 后写赢
        clr_all();
        sw_valid = 1'b1; sw_addr = 32'h900; sw_data = 32'h0; sw_width = 2'b00;
        init_valid = 1'b1; init_addr = 32'h900; init_data = 8'h5A;
        tick();
        sw_valid = 1'b0; init_valid = 1'b0;
        ld_start_valid = 1'b1; ld_start_addr = 32'h900;
        ld_start_width = 2'b00; ld_start_idx = 4'd0;
        tick();
        ld_start_valid = 1'b0;
        tick(); tick(); tick();
        check_all();
        if (!ld_done_valid || ld_done_data !== 32'h0000005A) begin
            $display("FAIL: M9 init over sw (d=%h)", ld_done_data);
            errors = errors + 1;
        end else begin
            $display("PASS: M9 init wins over sw same cycle");
        end

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 随机模型对照 (300 拍) ----
        begin : sec2
            integer i2;
            for (i2 = 0; i2 < 300; i2 = i2 + 1) begin
                clr_all();
                imem_addr[0 * 32 +: 32] = ({$random} & 32'h3FFF) * 4;
                imem_addr[1 * 32 +: 32] = imem_addr[0 * 32 +: 32] + 4;
                if (({$random} & 3) == 0) begin
                    init_valid = 1'b1;
                    init_addr = ({$random} & 32'h3FFF) * 4 + ({$random} & 3);
                    init_data = {$random} & 8'hFF;
                end
                if (({$random} & 3) == 0) begin
                    sw_valid = 1'b1;
                    sw_addr = ({$random} & 32'h3FFF) * 4;
                    sw_data = {$random};
                    sw_width = (($random) & 3) == 0 ? 2'b01 : 2'b10;
                end
                if (!ld_busy && (($random) & 1) == 0) begin
                    ld_start_valid = 1'b1;
                    ld_start_addr = ({$random} & 32'h3FFF) * 4;
                    ld_start_width = (($random) & 3) == 0 ? 2'b00
                                   : (($random) & 1) == 0 ? 2'b01 : 2'b10;
                    ld_start_idx = {$random} & (LSQ - 1);
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
