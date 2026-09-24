// tb_axi_lite_master: AXI4-Lite 主机 (纯协议层) 单元测试
// 从机模型严格照 scripts/sim.cpp 的 Memory 写: 每通道 16 深 FIFO / 每拍至多 1 读 + 1 写 /
//   两通道都挂起时 LFSR 随机定先后 / 握手后次拍才可服务, 再 +LATENCY 拍响应 /
//   R 按 AR 序、B 按 AW 序 / AW 与 W 按位置配对 (aw.front() 配 w.front()) /
//   读恒返整 4 字节小端字 / 非 4 对齐 ⇒ SLVERR, 越界 ⇒ DECERR /
//   0x80000000 且 wstrb=4'hf ⇒ 停机 (WDATA 为退出值且不写内存), 同址但 wstrb≠0x0f ⇒ SLVERR 且不停机
// 每拍无条件断言 AXI 硬规则: VALID 拉起后未握手前必须保持, 且载荷不得变化
// 用例: T1 单读 / T2 单写+读回 / T3 子字写 / T4 15 条连读 + 满时 ready 拉低 / T5 通道反压 /
//       T6 SLVERR+DECERR 透传 / T7 停机 / T8 同址错选通不停机 / T9 AW/W 先后序不错位 /
//       T10 写 FIFO 满 / T11 复位打断后恢复
// 失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
`timescale 1ns/1ps
module tb_axi_lite_master;
    localparam RD_DEPTH = 16;
    localparam WR_DEPTH = 8;
    localparam RD_TW    = 4;
    localparam WR_TW    = 3;
    localparam LATENCY  = 10;                      // 官方口径: 从机响应延迟
    localparam DEPTH    = 16;                      // 从机每通道 FIFO 深度
    localparam EXIT_ADDRESS = 32'h8000_0000;
    localparam [63:0] RAM_BYTES = 64'h1000_0000;   // 256MiB (sim.cpp 的 RAM_BYTES)
    localparam MEM_BYTES = 4096;                   // TB 实际建模的字节数 (越界会显式报错)
    localparam QMASK = 63;                         // 从机队列数组掩码 (64 项)

    reg clk = 1'b0;
    wire rst_n;
    always #5 clk = ~clk;
    reg reset;                                     // 高有效 (对应官方顶层 reset)
    assign rst_n = ~reset;

    // ---- 主机侧请求 (TB 驱动) ----
    reg  rd_req_valid, wr_req_valid, rd_resp_ready, wr_resp_ready;
    reg  [31:0] rd_req_addr, wr_req_addr, wr_req_data;
    reg  [RD_TW-1:0] rd_req_tag;
    reg  [WR_TW-1:0] wr_req_tag;
    reg  [3:0] wr_req_strb;
    wire rd_req_ready, rd_resp_valid, wr_req_ready, wr_resp_valid;
    wire [31:0] rd_resp_data;
    wire [1:0]  rd_resp_resp, wr_resp_resp;
    wire [RD_TW-1:0] rd_resp_tag;
    wire [WR_TW-1:0] wr_resp_tag;
    // ---- AXI 引脚 ----
    wire [31:0] araddr, awaddr, wdata, rdata;
    wire [3:0]  wstrb;
    wire arvalid, awvalid, wvalid, rvalid, bvalid, rready, bready;
    wire [1:0]  rresp, bresp;
    reg  arready, awready, wready, rvalid_s, bvalid_s;
    reg  [31:0] rdata_s;
    reg  [1:0]  rresp_s, bresp_s;
    reg  tb_hold_ar, tb_hold_aw, tb_hold_w, tb_hold_r, tb_hold_b;   // 反压注入

    axi_lite_master #(
        .RD_DEPTH(RD_DEPTH), .WR_DEPTH(WR_DEPTH), .RD_TW(RD_TW), .WR_TW(WR_TW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_req_addr(rd_req_addr), .rd_req_tag(rd_req_tag),
        .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready),
        .rd_resp_data(rd_resp_data), .rd_resp_resp(rd_resp_resp), .rd_resp_tag(rd_resp_tag),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_addr(wr_req_addr), .wr_req_data(wr_req_data),
        .wr_req_strb(wr_req_strb), .wr_req_tag(wr_req_tag),
        .wr_resp_valid(wr_resp_valid), .wr_resp_ready(wr_resp_ready),
        .wr_resp_resp(wr_resp_resp), .wr_resp_tag(wr_resp_tag),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );
    assign rdata = rdata_s;
    assign rresp = rresp_s;
    assign rvalid = rvalid_s;
    assign bresp = bresp_s;
    assign bvalid = bvalid_s;

    integer errors = 0;
    integer i, k;

    // ================= 从机模型 (照 sim.cpp 的 Memory) =================
    reg [7:0] mem_bytes [0 : MEM_BYTES - 1];
    reg [31:0] ar_q [0 : QMASK];
    reg [31:0] aw_q [0 : QMASK];
    reg [31:0] w_dq [0 : QMASK];
    reg [3:0]  w_sq [0 : QMASK];
    reg [31:0] r_dq [0 : QMASK];
    reg [1:0]  r_pq [0 : QMASK];
    integer    r_tq [0 : QMASK];
    reg [1:0]  b_pq [0 : QMASK];
    reg [31:0] b_rq [0 : QMASK];
    integer    b_tq [0 : QMASK];
    reg        b_eq [0 : QMASK];
    integer ar_cnt, aw_cnt, w_cnt, r_cnt, b_cnt;
    integer ar_head, aw_head, w_head, r_head, b_head;
    integer ar_tail, aw_tail, w_tail, r_tail, b_tail;
    integer cycle;
    reg [31:0] rnd;
    reg done;
    reg [31:0] result;

    // sim.cpp: 非 4 对齐 ⇒ SLVERR(2); address+4 > 256MiB ⇒ DECERR(3); 否则 OKAY(0)
    function [1:0] response;
        input [31:0] address;
        reg   [63:0] a64;
        begin
            a64 = {32'd0, address};
            response = (address[1:0] != 2'b00) ? 2'd2
                     : ((a64 + 64'd4) > RAM_BYTES) ? 2'd3 : 2'd0;
        end
    endfunction

    // 整 4 字节小端字 (仅对 aligned 且在建模范围内的地址调用)
    function [31:0] mem_word;
        input [31:0] a;
        begin
            mem_word = {mem_bytes[a + 3], mem_bytes[a + 2], mem_bytes[a + 1], mem_bytes[a]};
        end
    endfunction

    // sim.cpp drive(): 每拍开始 (clock=0) 按队列现状驱动从机组合输出
    task slave_drive;
        begin
            arready  = !reset && (ar_cnt < DEPTH) && !tb_hold_ar;
            awready  = !reset && (aw_cnt < DEPTH) && !tb_hold_aw;
            wready   = !reset && (w_cnt  < DEPTH) && !tb_hold_w;
            rvalid_s = !reset && (r_cnt > 0) && (r_tq[r_head] <= cycle) && !tb_hold_r;
            rdata_s  = (r_cnt > 0) ? r_dq[r_head] : 32'd0;
            rresp_s  = (r_cnt > 0) ? r_pq[r_head] : 2'd0;
            bvalid_s = !reset && (b_cnt > 0) && (b_tq[b_head] <= cycle) && !tb_hold_b;
            bresp_s  = (b_cnt > 0) ? b_pq[b_head] : 2'd0;
        end
    endtask

    // 从机服务一次读 (sim.cpp read())
    task slave_do_read;
        reg [31:0] a; reg [1:0] st; reg [31:0] d;
        integer bi;
        begin
            a = ar_q[ar_head]; st = response(a); d = 32'd0;
            ar_head = (ar_head + 1) & QMASK; ar_cnt = ar_cnt - 1;
            if (st == 2'd0) begin
                if ((a + 4) > MEM_BYTES) begin
                    $display("TB ERROR: modeled RAM too small for address %h", a);
                    errors = errors + 1;
                end else begin
                    for (bi = 0; bi < 4; bi = bi + 1)
                        d = d | ({24'd0, mem_bytes[a + bi]} << (8 * bi));
                end
            end
            r_dq[r_tail] = d; r_pq[r_tail] = st; r_tq[r_tail] = cycle + LATENCY;
            r_tail = (r_tail + 1) & QMASK; r_cnt = r_cnt + 1;
        end
    endtask

    // 从机服务一次写 (sim.cpp write()): AW 与 W 按位置配对
    task slave_do_write;
        reg [31:0] a; reg [31:0] d; reg [3:0] s; reg [1:0] st; reg ex;
        integer bi;
        begin
            a = aw_q[aw_head]; d = w_dq[w_head]; s = w_sq[w_head];
            aw_head = (aw_head + 1) & QMASK; aw_cnt = aw_cnt - 1;
            w_head  = (w_head + 1) & QMASK;  w_cnt  = w_cnt - 1;
            ex = (a == EXIT_ADDRESS) && (s == 4'hf);
            st = (a == EXIT_ADDRESS) ? (ex ? 2'd0 : 2'd2) : response(a);
            if (st == 2'd0 && !ex) begin
                if ((a + 4) > MEM_BYTES) begin
                    $display("TB ERROR: modeled RAM too small for address %h", a);
                    errors = errors + 1;
                end else begin
                    for (bi = 0; bi < 4; bi = bi + 1)
                        if (s[bi]) mem_bytes[a + bi] = d >> (8 * bi);
                end
            end
            b_pq[b_tail] = st; b_rq[b_tail] = d; b_tq[b_tail] = cycle + LATENCY; b_eq[b_tail] = ex;
            b_tail = (b_tail + 1) & QMASK; b_cnt = b_cnt + 1;
        end
    endtask

    // sim.cpp step(): 用 posedge 前的引脚值推进从机 (握手在此判定)
    task slave_step;
        reg do_read, do_write, write_first;
        reg [31:0] rn;
        begin
            if (reset) begin
                ar_cnt = 0; aw_cnt = 0; w_cnt = 0; r_cnt = 0; b_cnt = 0;
                ar_head = 0; aw_head = 0; w_head = 0; r_head = 0; b_head = 0;
                ar_tail = 0; aw_tail = 0; w_tail = 0; r_tail = 0; b_tail = 0;
                cycle = 0; rnd = 32'd1; done = 1'b0; result = 32'd0;
            end else begin
                cycle = cycle + 1;
                if (rvalid && rready) begin r_head = (r_head + 1) & QMASK; r_cnt = r_cnt - 1; end
                if (bvalid && bready) begin
                    if (b_eq[b_head]) begin done = 1'b1; result = b_rq[b_head]; end
                    b_head = (b_head + 1) & QMASK; b_cnt = b_cnt - 1;
                end
                do_read  = (ar_cnt > 0) && (r_cnt < DEPTH);
                do_write = (aw_cnt > 0) && (w_cnt > 0) && (b_cnt < DEPTH);
                write_first = 1'b0;
                if (do_read && do_write) begin
                    rn = rnd ^ (rnd << 13); rn = rn ^ (rn >> 17); rn = rn ^ (rn << 5);
                    rnd = rn;
                    write_first = rn[0];
                end
                if (do_write && write_first) slave_do_write;
                if (do_read) slave_do_read;
                if (do_write && !write_first) slave_do_write;
                // 新收下的请求次拍才可服务
                if (arvalid && arready) begin
                    ar_q[ar_tail] = araddr; ar_tail = (ar_tail + 1) & QMASK; ar_cnt = ar_cnt + 1;
                end
                if (awvalid && awready) begin
                    aw_q[aw_tail] = awaddr; aw_tail = (aw_tail + 1) & QMASK; aw_cnt = aw_cnt + 1;
                end
                if (wvalid && wready) begin
                    w_dq[w_tail] = wdata; w_sq[w_tail] = wstrb;
                    w_tail = (w_tail + 1) & QMASK; w_cnt = w_cnt + 1;
                end
                if ((ar_cnt > DEPTH) || (aw_cnt > DEPTH) || (w_cnt > DEPTH)) begin
                    $display("FAIL: slave fifo overflow (ar=%0d aw=%0d w=%0d)", ar_cnt, aw_cnt, w_cnt);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ================= 每拍采样 + AXI 硬规则断言 =================
    reg s_rd_hs, s_wr_hs, s_ar_hs, s_aw_hs, s_w_hs, s_r_hs, s_b_hs;
    reg s_rdresp_hs, s_wrresp_hs;
    reg [31:0] s_araddr, s_awaddr, s_wdata, s_rdata, s_rd_data;
    reg [3:0]  s_wstrb;
    reg [1:0]  s_rresp, s_rd_resp, s_wr_resp;
    reg [RD_TW-1:0] s_rd_tag;
    reg [WR_TW-1:0] s_wr_tag;
    reg p_arvalid, p_awvalid, p_wvalid, p_rvalid, p_bvalid;
    reg p_arready, p_awready, p_wready, p_rready, p_bready;
    reg [31:0] p_araddr, p_awaddr, p_wdata, p_rdata;
    reg [3:0]  p_wstrb;
    reg [1:0]  p_rresp;
    // 握手拍锁存的响应 (posedge 后 DUT 指针已前进, 端口值不再可信, 必须当场存下)
    reg [31:0] cap_rd_data;
    reg [1:0]  cap_rd_resp, cap_wr_resp;
    reg [RD_TW-1:0] cap_rd_tag;
    reg [WR_TW-1:0] cap_wr_tag;

    task tb_sample;
        begin
            s_rd_hs     = rd_req_valid && rd_req_ready;
            s_wr_hs     = wr_req_valid && wr_req_ready;
            s_ar_hs     = arvalid && arready;
            s_aw_hs     = awvalid && awready;
            s_w_hs      = wvalid && wready;
            s_r_hs      = rvalid && rready;
            s_b_hs      = bvalid && bready;
            s_rdresp_hs = rd_resp_valid && rd_resp_ready;
            s_wrresp_hs = wr_resp_valid && wr_resp_ready;
            s_araddr  = araddr;  s_awaddr = awaddr;  s_wdata = wdata;  s_wstrb = wstrb;
            s_rdata   = rdata;   s_rresp  = rresp;
            s_rd_resp = rd_resp_resp; s_rd_tag = rd_resp_tag; s_rd_data = rd_resp_data;
            s_wr_resp = wr_resp_resp; s_wr_tag = wr_resp_tag;
        end
    endtask

    // VALID 一旦拉起, 握手前必须保持, 且载荷不变 (AXI 硬规则; 每拍无条件查)
    task protocol_check;
        begin
            if (p_arvalid && !p_arready && (!arvalid || (araddr !== p_araddr))) begin
                $display("FAIL: AR valid/addr changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_awvalid && !p_awready && (!awvalid || (awaddr !== p_awaddr))) begin
                $display("FAIL: AW valid/addr changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_wvalid && !p_wready && (!wvalid || (wdata !== p_wdata) || (wstrb !== p_wstrb))) begin
                $display("FAIL: W valid/payload changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            // 从机侧 (模型的义务, 顺带查模型): R/B 未握手前必须保持
            if (p_rvalid && !p_rready && (!rvalid || (rdata !== p_rdata) || (rresp !== p_rresp))) begin
                $display("FAIL: R valid/payload changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_bvalid && !p_bready && !bvalid) begin
                $display("FAIL: B valid dropped before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            p_arvalid = arvalid; p_arready = arready; p_araddr = araddr;
            p_awvalid = awvalid; p_awready = awready; p_awaddr = awaddr;
            p_wvalid  = wvalid;  p_wready  = wready;  p_wdata  = wdata; p_wstrb = wstrb;
            p_rvalid  = rvalid;  p_rready  = rready;  p_rdata  = rdata; p_rresp = rresp;
            p_bvalid  = bvalid;  p_bready  = bready;
        end
    endtask

    // 一拍 = clock=0 (drive) → 采样 → step → posedge → 检查
    task tick;
        begin
            @(negedge clk);
            slave_drive;
            #1;
            tb_sample;
            protocol_check;
            slave_step;
            @(posedge clk);
            #1;
        end
    endtask

    task clr_req;
        begin
            rd_req_valid = 0; wr_req_valid = 0;
            rd_req_addr = 0; rd_req_tag = 0;
            wr_req_addr = 0; wr_req_data = 0; wr_req_strb = 0; wr_req_tag = 0;
            rd_resp_ready = 1; wr_resp_ready = 1;
            tb_hold_ar = 0; tb_hold_aw = 0; tb_hold_w = 0; tb_hold_r = 0; tb_hold_b = 0;
        end
    endtask

    task expect;
        input cond;
        input [1023:0] msg;
        begin
            if (!cond) begin
                $display("FAIL: %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // 推一条读请求 (握手后立刻撤 valid, 保证只被收下一次)
    task push_read;
        input [31:0] a;
        input [RD_TW-1:0] t;
        reg hit;
        begin
            rd_req_valid = 1'b1; rd_req_addr = a; rd_req_tag = t;
            hit = 1'b0;
            while (!hit) begin
                tick();
                hit = s_rd_hs;
            end
            rd_req_valid = 1'b0;
        end
    endtask

    task push_write;
        input [31:0] a, d;
        input [3:0]  s;
        input [WR_TW-1:0] t;
        reg hit;
        begin
            wr_req_valid = 1'b1; wr_req_addr = a; wr_req_data = d;
            wr_req_strb = s; wr_req_tag = t;
            hit = 1'b0;
            while (!hit) begin
                tick();
                hit = s_wr_hs;
            end
            wr_req_valid = 1'b0;
        end
    endtask

    // 取一条读响应: 命中拍当场锁存 (posedge 后指针已前进, 端口值不再对应当前事务);
    // 注意调用方**不要**再补 tick() —— 同一拍组合上就已经是下一条目的数据, 补一拍会多吞一条响应
    task wait_rd_resp;
        input integer maxn;
        reg hit;
        begin
            hit = 1'b0;
            for (k = 0; (k < maxn) && !hit; k = k + 1) begin
                tick();
                if (s_rdresp_hs) begin
                    hit = 1'b1;
                    cap_rd_data = s_rd_data; cap_rd_resp = s_rd_resp; cap_rd_tag = s_rd_tag;
                end
            end
            expect(hit, "read response never returned");
        end
    endtask

    task wait_wr_resp;
        input integer maxn;
        reg hit;
        begin
            hit = 1'b0;
            for (k = 0; (k < maxn) && !hit; k = k + 1) begin
                tick();
                if (s_wrresp_hs) begin
                    hit = 1'b1;
                    cap_wr_resp = s_wr_resp; cap_wr_tag = s_wr_tag;
                end
            end
            expect(hit, "write response never returned");
        end
    endtask

    // 冲净所有在途响应 (有限拍, 防空转)
    task drain;
        begin
            rd_resp_ready = 1'b1; wr_resp_ready = 1'b1;
            for (k = 0; k < 60; k = k + 1) tick();
        end
    endtask

    // ================= 用例 =================
    integer acc;
    initial begin
        $dumpfile("sim/core/tb_axi_lite_master.vcd");
        $dumpvars(0, tb_axi_lite_master);

        // 从机模型上电初值 (第一拍 drive 之前就要有效)
        ar_cnt = 0; aw_cnt = 0; w_cnt = 0; r_cnt = 0; b_cnt = 0;
        ar_head = 0; aw_head = 0; w_head = 0; r_head = 0; b_head = 0;
        ar_tail = 0; aw_tail = 0; w_tail = 0; r_tail = 0; b_tail = 0;
        cycle = 0; rnd = 32'd1; done = 1'b0; result = 32'd0;
        for (i = 0; i < MEM_BYTES; i = i + 1) mem_bytes[i] = i[7:0];
        clr_req();
        reset = 1'b1;
        for (i = 0; i < 3; i = i + 1) tick();
        reset = 1'b0;
        tick();

        // ---- T1 单读: 数据/响应/tag 均正确 ----
        push_read(32'h0000_0100, 4'd3);
        wait_rd_resp(40);
        expect(cap_rd_data === mem_word(32'h0000_0100), "T1 rd data");
        expect(cap_rd_resp === 2'd0, "T1 rd resp OKAY");
        expect(cap_rd_tag === 4'd3, "T1 rd tag");
        if ((cap_rd_data === mem_word(32'h0000_0100)) && (cap_rd_resp === 2'd0) && (cap_rd_tag === 4'd3))
            $display("PASS: T1 single read (data/resp/tag)");

        // ---- T2 单写 + 读回 ----
        push_write(32'h0000_0200, 32'hDEAD_BEEF, 4'hf, 3'd5);
        wait_wr_resp(40);
        expect(cap_wr_resp === 2'd0, "T2 bresp OKAY");
        expect(cap_wr_tag === 3'd5, "T2 b tag");
        expect(mem_bytes[32'h0000_0200] === 8'hEF, "T2 mem byte0");
        expect(mem_bytes[32'h0000_0203] === 8'hDE, "T2 mem byte3");
        if ((cap_wr_resp === 2'd0) && (cap_wr_tag === 3'd5) && (mem_bytes[32'h0000_0203] === 8'hDE))
            $display("PASS: T2 single write + memory");
        push_read(32'h0000_0200, 4'd0);
        wait_rd_resp(40);
        expect(cap_rd_data === 32'hDEAD_BEEF, "T2b read-back");
        if (cap_rd_data === 32'hDEAD_BEEF) $display("PASS: T2b write read-back");

        // ---- T3 子字写: 只有 wstrb 指到的字节被改 (wstrb[i] ↔ address+i, 取 wdata[8i+:8]) ----
        push_write(32'h0000_0204, 32'hAABB_CCDD, 4'b0010, 3'd1);   // 只写 0x205 ← wdata[15:8] = 0xCC
        wait_wr_resp(40);
        expect(mem_bytes[32'h0000_0205] === 8'hCC, "T3 byte1 = wdata[15:8]");
        expect(mem_bytes[32'h0000_0204] === 8'h04, "T3 byte0 untouched");
        expect(mem_bytes[32'h0000_0206] === 8'h06, "T3 byte2 untouched");
        if ((mem_bytes[32'h0000_0205] === 8'hCC) && (mem_bytes[32'h0000_0204] === 8'h04))
            $display("PASS: T3 sub-word write strobe");

        // ---- T4 15 条连读 (响应先不取走): 满后 ready 必须拉低, 取走时顺序/tag/数据逐条正确 ----
        rd_resp_ready = 1'b0;
        for (k = 0; k < (RD_DEPTH - 1); k = k + 1) push_read(32'h0000_0300 + 4 * k, k[RD_TW-1:0]);
        tick();
        expect(rd_req_ready === 1'b0, "T4 rd_req_ready low when fifo full");
        if (rd_req_ready === 1'b0) $display("PASS: T4 read fifo full deasserts ready");
        begin : t4
            integer m, bad4; bad4 = 0;
            rd_resp_ready = 1'b1;
            for (m = 0; m < (RD_DEPTH - 1); m = m + 1) begin
                wait_rd_resp(80);
                if ((cap_rd_tag !== m[RD_TW-1:0])
                 || (cap_rd_data !== mem_word(32'h0000_0300 + 4 * m))) bad4 = bad4 + 1;
            end
            expect(bad4 == 0, "T4 responses out of order or wrong data");
            if (bad4 == 0) $display("PASS: T4 15 outstanding reads in order");
        end

        // ---- T5 通道反压: 从机不给 ready 时 VALID 必须保持且载荷不变 (protocol_check 逐拍查);
        //      主机自身的请求 FIFO 与总线反压解耦 ⇒ 请求照收 (rd_req_ready 只看自己满没满), 只是发不上总线 ----
        tb_hold_ar = 1'b1; tb_hold_aw = 1'b1; tb_hold_w = 1'b1;
        push_read(32'h0000_0400, 4'hA);
        push_write(32'h0000_0404, 32'h1234_5678, 4'hf, 3'd2);
        for (k = 0; k < 6; k = k + 1) tick();
        expect(s_ar_hs === 1'b0, "T5 AR handshake while arready low");
        expect(s_aw_hs === 1'b0, "T5 AW handshake while awready low");
        expect(s_w_hs  === 1'b0, "T5 W handshake while wready low");
        expect(arvalid === 1'b1, "T5 AR valid must stay high while stalled");
        expect(awvalid === 1'b1, "T5 AW valid must stay high while stalled");
        expect(wvalid  === 1'b1, "T5 W valid must stay high while stalled");
        tb_hold_ar = 1'b0; tb_hold_aw = 1'b0; tb_hold_w = 1'b0;
        tick();
        expect(s_ar_hs === 1'b1, "T5 AR handshake after release");
        expect(s_aw_hs === 1'b1, "T5 AW handshake after release");
        expect(s_w_hs  === 1'b1, "T5 W handshake after release");
        if ((s_ar_hs === 1'b1) && (s_aw_hs === 1'b1) && (s_w_hs === 1'b1))
            $display("PASS: T5 VALID stability under channel backpressure");
        // 两条响应几乎同时到: 等读响应期间必须压住写响应, 否则它会被静默取走 (ready 恒 1)
        wr_resp_ready = 1'b0;
        wait_rd_resp(60);
        wr_resp_ready = 1'b1;
        wait_wr_resp(60);

        // ---- T6 SLVERR / DECERR 透传 ----
        push_read(32'h0000_0102, 4'd1);            // 非 4 对齐 ⇒ SLVERR
        wait_rd_resp(40);
        expect(cap_rd_resp === 2'd2, "T6 unaligned read SLVERR");
        push_read(32'h2000_0000, 4'd2);            // 越出 256MiB ⇒ DECERR
        wait_rd_resp(40);
        expect(cap_rd_resp === 2'd3, "T6 out-of-range read DECERR");
        push_write(32'h0000_0106, 32'hFFFF_FFFF, 4'hf, 3'd7);   // 非 4 对齐写 ⇒ SLVERR
        wait_wr_resp(40);
        expect(cap_wr_resp === 2'd2, "T6 unaligned write SLVERR");
        expect(mem_bytes[32'h0000_0106] === 8'h06, "T6 SLVERR write must not touch memory");
        if ((cap_wr_resp === 2'd2) && (mem_bytes[32'h0000_0106] === 8'h06))
            $display("PASS: T6 SLVERR/DECERR passthrough");

        // ---- T7 停机: 0x80000000 + wstrb=4'hf ⇒ bresp OKAY, done, 退出值 = WDATA ----
        expect(done === 1'b0, "T7 not done before exit write");
        push_write(EXIT_ADDRESS, 32'h0000_1234, 4'hf, 3'd0);
        wait_wr_resp(40);
        expect(cap_wr_resp === 2'd0, "T7 exit bresp OKAY");
        expect(done === 1'b1, "T7 done after exit write");
        expect(result === 32'h0000_1234, "T7 exit result = WDATA");
        if ((done === 1'b1) && (result === 32'h0000_1234))
            $display("PASS: T7 exit write latches result");

        // ---- T8 同址但 wstrb≠0x0f ⇒ SLVERR 且不停机 (官方口径: 该用例会死等超时) ----
        done = 1'b0;                               // sim.cpp 的 done 是一次性锁存, TB 要继续测后面用例须手动清
        push_write(EXIT_ADDRESS, 32'h0000_9999, 4'h3, 3'd1);
        wait_wr_resp(40);
        expect(cap_wr_resp === 2'd2, "T8 partial-strobe exit write SLVERR");
        expect(done === 1'b0, "T8 partial-strobe write must NOT exit");
        if ((cap_wr_resp === 2'd2) && (done === 1'b0))
            $display("PASS: T8 partial-strobe exit write does not terminate");

        // ---- T9 写通道 AW/W 先后序: 压住 wready 让 AW 先握手 ⇒ 位置配对不许错位 ----
        tb_hold_w = 1'b1;
        push_write(32'h0000_0500, 32'h1111_1111, 4'hf, 3'd0);
        for (k = 0; k < 3; k = k + 1) tick();
        expect(dut.aw_done_r === 1'b1, "T9 AW done while W pending");
        expect(dut.w_done_r === 1'b0, "T9 W not done yet");
        push_write(32'h0000_0504, 32'h2222_2222, 4'hf, 3'd1);
        tb_hold_w = 1'b0;
        for (k = 0; k < 20; k = k + 1) tick();
        expect(mem_bytes[32'h0000_0500] === 8'h11, "T9 first write lands at 0x500");
        expect(mem_bytes[32'h0000_0504] === 8'h22, "T9 second write lands at 0x504");
        if ((mem_bytes[32'h0000_0500] === 8'h11) && (mem_bytes[32'h0000_0504] === 8'h22))
            $display("PASS: T9 AW-first ordering preserves pairing");
        // 反向: 压住 awready, 让 W 先握手
        drain();
        tb_hold_aw = 1'b1;
        push_write(32'h0000_0510, 32'h3333_3333, 4'hf, 3'd2);
        for (k = 0; k < 3; k = k + 1) tick();
        expect(dut.w_done_r === 1'b1, "T9b W done while AW pending");
        expect(dut.aw_done_r === 1'b0, "T9b AW not done yet");
        tb_hold_aw = 1'b0;
        for (k = 0; k < 20; k = k + 1) tick();
        expect(mem_bytes[32'h0000_0510] === 8'h33, "T9b write lands at 0x510");
        if (mem_bytes[32'h0000_0510] === 8'h33)
            $display("PASS: T9b W-first ordering preserves pairing");
        drain();

        // ---- T10 写 FIFO 满: 压住 AW/W 后最多收下 WR_DEPTH-1 条 ----
        tb_hold_aw = 1'b1; tb_hold_w = 1'b1;
        wr_req_valid = 1'b1; wr_req_data = 32'h5555_5555; wr_req_strb = 4'hf; wr_req_tag = 3'd0;
        acc = 0; wr_req_addr = 32'h0000_0600;
        for (k = 0; k < 12; k = k + 1) begin
            tick();
            if (s_wr_hs) begin
                acc = acc + 1;
                wr_req_addr = 32'h0000_0600 + 4 * acc;   // 只在被收下后才换载荷
            end
        end
        expect(acc == (WR_DEPTH - 1), "T10 write fifo accepts WR_DEPTH-1");
        tb_hold_aw = 1'b0; tb_hold_w = 1'b0; wr_req_valid = 1'b0;
        for (k = 0; k < 40; k = k + 1) tick();
        expect(dut.wr_wr_p === dut.wr_rd_p, "T10 all writes drained");
        if ((acc == (WR_DEPTH - 1)) && (dut.wr_wr_p === dut.wr_rd_p))
            $display("PASS: T10 write fifo full then drained");

        // ---- T11 复位打断: 在途事务被清, 释放后恢复正常 ----
        push_read(32'h0000_0700, 4'd9);
        push_write(32'h0000_0704, 32'hAAAA_AAAA, 4'hf, 3'd0);
        for (k = 0; k < 3; k = k + 1) tick();
        reset = 1'b1;
        for (k = 0; k < 3; k = k + 1) tick();
        expect(arvalid === 1'b0, "T11 AR valid low during reset");
        expect(awvalid === 1'b0, "T11 AW valid low during reset");
        expect(wvalid === 1'b0, "T11 W valid low during reset");
        expect(rd_resp_valid === 1'b0, "T11 rd resp cleared by reset");
        expect(wr_resp_valid === 1'b0, "T11 wr resp cleared by reset");
        clr_req();
        reset = 1'b0;
        tick();
        push_read(32'h0000_0708, 4'd4);
        wait_rd_resp(40);
        expect(cap_rd_data === mem_word(32'h0000_0708), "T11 read after reset");
        if (cap_rd_data === mem_word(32'h0000_0708)) $display("PASS: T11 reset recovery");

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end
endmodule
