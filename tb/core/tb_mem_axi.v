// tb_mem_axi: 存储子系统 (mem_subsystem) 单元测试
// 从机模型与 tb_axi_lite_master.v 同源, 严格照 scripts/sim.cpp 的 Memory 写:
//   每通道 16 深 FIFO / 每拍至多 1 读 + 1 写 / 两通道都挂起时 LFSR 随机定先后 /
//   握手后次拍才可服务, 再 +LATENCY 拍响应 / R 按 AR 序、B 按 AW 序 / AW 与 W 按位置配对 /
//   读恒返整 4 字节小端字 / 非 4 对齐 ⇒ SLVERR, 越界 ⇒ DECERR
//   区别: 本 TB 不需要 MMIO 停机语义 (mem_subsystem 不特判 0x80000000, 由 cpu_top 做)
//
// 每拍无条件查 (protocol_check / mem_check):
//   * AXI 硬规则: VALID 拉起未握手前必须保持且载荷不变
//   * 取指地址恒 4 字节对齐; load/store 的 araddr/awaddr 也必须对齐 (否则从机 SLVERR)
//   * imem_addr_q ≡ 上一拍的 imem_addr (与 fetch.v 的 imem_addr_d 同步是设计前提)
//   * ★ imem_valid 为 1 时, inst_data 必须**就是该地址上的指令** (取指错绑的结构性排除)
//   * ★ 每个被接受的 load 恰好一个完成脉冲 (ld_busy 硬契约的两半: 不反悔 / 不重复不少给)
//
// 用例: T1 顺序取指 (含冷启动周期数) / T2 重定向与 tag 别名不错绑 / T3 load 各宽度与零扩展 /
//       T4 store 各宽度 strb 与地址对齐 / T5 store→load 可见性竞态 (提交时刻扫描) / T6 复位打断
// 失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
`timescale 1ns/1ps
module tb_mem_axi;
    localparam ISSUE_WIDTH = 1;
    localparam LSQ_SIZE    = 16;
    localparam PF_DEPTH    = 16;
    localparam PF_WIN      = 8;
    localparam LD_INFLIGHT = 8;
    localparam SQ_DEPTH    = 8;
    localparam RD_DEPTH    = 8;
    localparam WR_DEPTH    = 8;
    localparam LATENCY     = 10;                   // 官方口径: 从机响应延迟
    localparam DEPTH       = 16;                   // 从机每通道 FIFO 深度
    localparam [63:0] RAM_BYTES = 64'h1000_0000;   // 256MiB (sim.cpp 的 RAM_BYTES)
    localparam MEM_BYTES = 4096;                   // TB 建模的字节数
    localparam QMASK = 63;
    localparam LIW = 4;                            // $clog2(LSQ_SIZE)
    // 地址分区 (互不重叠, 便于定位错绑)
    localparam FA_PARK = 32'h0000_0700;            // 取指"停车位"
    localparam LA_BASE = 32'h0000_0200;            // load 区
    localparam SA_BASE = 32'h0000_0300;            // store 区
    localparam RA_BASE = 32'h0000_0500;            // 竞态区

    reg clk = 1'b0;
    wire rst_n;
    always #5 clk = ~clk;
    reg reset;                                     // 高有效 (对应官方顶层 reset)
    assign rst_n = ~reset;

    // ---- CPU 侧 (TB 驱动) ----
    reg  [ISSUE_WIDTH*32-1:0] imem_addr;
    reg  ld_start_valid;
    reg  [31:0] ld_start_addr;
    reg  [1:0]  ld_start_width;
    reg  [LIW-1:0] ld_start_idx;
    wire [ISSUE_WIDTH*32-1:0] inst_data;
    wire imem_valid, ld_done_valid, ld_busy, sw_ready;
    wire [31:0] ld_done_data;
    wire [LIW-1:0] ld_done_idx;
    reg  sw_valid;
    reg  [31:0] sw_addr, sw_data;
    reg  [1:0]  sw_width;
    // ---- AXI 引脚 ----
    wire [31:0] araddr, awaddr, wdata, rdata;
    wire [3:0]  wstrb;
    wire arvalid, awvalid, wvalid, rvalid, bvalid, rready, bready;
    wire [1:0]  rresp, bresp;
    reg  arready, awready, wready, rvalid_s, bvalid_s;
    reg  [31:0] rdata_s;
    reg  [1:0]  rresp_s, bresp_s;
    reg  tb_hold_ar, tb_hold_aw, tb_hold_w, tb_hold_r, tb_hold_b;

    mem_subsystem #(
        .ISSUE_WIDTH(ISSUE_WIDTH), .LSQ_SIZE(LSQ_SIZE),
        .PF_DEPTH(PF_DEPTH), .PF_WIN(PF_WIN), .LD_INFLIGHT(LD_INFLIGHT),
        .SQ_DEPTH(SQ_DEPTH), .RD_DEPTH(RD_DEPTH), .WR_DEPTH(WR_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .inst_data(inst_data), .imem_addr(imem_addr), .imem_valid(imem_valid),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx),
        .ld_done_data(ld_done_data), .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data),
        .sw_width(sw_width), .sw_ready(sw_ready),
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
    integer i, k, n;

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
    integer    b_tq [0 : QMASK];
    integer ar_cnt, aw_cnt, w_cnt, r_cnt, b_cnt;
    integer ar_head, aw_head, w_head, r_head, b_head;
    integer ar_tail, aw_tail, w_tail, r_tail, b_tail;
    integer cycle;
    reg [31:0] rnd;

    // 初始数据图案 (每字节互异, 便于定位字节道写反)
    integer mi;
    initial begin
        for (mi = 0; mi < MEM_BYTES; mi = mi + 1) mem_bytes[mi] = (mi + 1) & 8'hFF;
    end

    function [7:0] pat;
        input [31:0] a;
        begin
            pat = (a + 32'd1) & 8'hFF;
        end
    endfunction

    // 整 4 字节小端字 (仅对 aligned 且在建模范围内的地址调用)
    function [31:0] mem_word;
        input [31:0] a;
        begin
            mem_word = {mem_bytes[a + 3], mem_bytes[a + 2], mem_bytes[a + 1], mem_bytes[a]};
        end
    endfunction

    function [1:0] response;
        input [31:0] address;
        reg   [63:0] a64;
        begin
            a64 = {32'd0, address};
            response = (address[1:0] != 2'b00) ? 2'd2
                     : ((a64 + 64'd4) > RAM_BYTES) ? 2'd3 : 2'd0;
        end
    endfunction

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

    task slave_do_write;
        reg [31:0] a; reg [31:0] d; reg [3:0] s; reg [1:0] st;
        integer bi;
        begin
            a = aw_q[aw_head]; d = w_dq[w_head]; s = w_sq[w_head];
            aw_head = (aw_head + 1) & QMASK; aw_cnt = aw_cnt - 1;
            w_head  = (w_head + 1) & QMASK;  w_cnt  = w_cnt - 1;
            st = response(a);
            if (st == 2'd0) begin
                if ((a + 4) > MEM_BYTES) begin
                    $display("TB ERROR: modeled RAM too small for address %h", a);
                    errors = errors + 1;
                end else begin
                    for (bi = 0; bi < 4; bi = bi + 1)
                        if (s[bi]) mem_bytes[a + bi] = d >> (8 * bi);
                end
            end
            b_pq[b_tail] = st; b_tq[b_tail] = cycle + LATENCY;
            b_tail = (b_tail + 1) & QMASK; b_cnt = b_cnt + 1;
        end
    endtask

    task slave_step;
        reg do_read, do_write, write_first;
        reg [31:0] rn;
        begin
            if (reset) begin
                ar_cnt = 0; aw_cnt = 0; w_cnt = 0; r_cnt = 0; b_cnt = 0;
                ar_head = 0; aw_head = 0; w_head = 0; r_head = 0; b_head = 0;
                ar_tail = 0; aw_tail = 0; w_tail = 0; r_tail = 0; b_tail = 0;
                cycle = 0; rnd = 32'd1;
            end else begin
                cycle = cycle + 1;
                if (rvalid && rready) begin r_head = (r_head + 1) & QMASK; r_cnt = r_cnt - 1; end
                if (bvalid && bready) begin b_head = (b_head + 1) & QMASK; b_cnt = b_cnt - 1; end
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

    // ================= 每拍采样 + 断言 =================
    reg s_ar_hs, s_aw_hs, s_w_hs, s_ld_hs, s_lddone_hs, s_sw_hs;
    reg [31:0] s_araddr, s_awaddr, s_wdata, s_imem_addr;
    reg [3:0]  s_wstrb;
    reg [31:0] cap_w_addr, cap_w_data;
    reg [3:0]  cap_w_strb;
    reg [31:0] cap_ld_data;
    reg [LIW-1:0] cap_ld_idx;
    reg [31:0] prev_araddr, prev_awaddr, prev_wdata;
    reg [3:0]  prev_wstrb;
    reg p_arvalid, p_awvalid, p_wvalid, p_rvalid, p_bvalid;
    reg p_arready, p_awready, p_wready, p_rready, p_bready;
    reg [31:0] p_rdata;
    reg [1:0]  p_rresp;
    integer pend_done = 0;           // 已回但尚未被 ld_wait 认领的完成脉冲数
    integer ld_inflight_tb = 0;      // TB 侧账本: 收下的 load 数 - 完成的 load 数
    integer ld_acc_tb = 0;
    integer ld_done_tb = 0;
    integer tcyc = 0;                // 全局拍计数 (do_reset 清零), 用于竞态时刻对齐
    integer commit_t, done_t;        // store 入队拍 / load 完成拍
    integer fetch_cycles;

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

    task tb_sample;
        begin
            s_ar_hs = arvalid && arready;
            s_aw_hs = awvalid && awready;
            s_w_hs  = wvalid && wready;
            s_ld_hs = ld_start_valid && !ld_busy;
            s_lddone_hs = ld_done_valid;
            s_sw_hs = sw_valid && sw_ready;
            s_araddr = araddr; s_awaddr = awaddr; s_wdata = wdata; s_wstrb = wstrb;
            // 完成脉冲当拍锁存 (posedge 后 rd_rd_p 已前进, 端口值不再对应本条)
            if (s_lddone_hs) begin
                cap_ld_data = ld_done_data;
                cap_ld_idx  = ld_done_idx;
                done_t = tcyc;
                pend_done = pend_done + 1;    // 完成脉冲可能落在两次 ld_wait 之间的空档 (T5 的对齐 tick)
            end
            // 提交拍与完成拍必须同一口径: 都用"握手可见的那一拍" (st_push 里读 tcyc 会晚一拍)
            if (s_sw_hs) commit_t = tcyc;
        end
    endtask

    // AXI 硬规则 + 对齐契约 (每拍无条件; 复位期间主从双方同时作废, VALID 允许拉低 ⇒ 不查)
    task protocol_check;
        begin
        if (!reset) begin
            if (p_arvalid && !p_arready && (!arvalid || (araddr !== prev_araddr))) begin
                $display("FAIL: AR valid/addr changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_awvalid && !p_awready && (!awvalid || (awaddr !== prev_awaddr))) begin
                $display("FAIL: AW valid/addr changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_wvalid && !p_wready && (!wvalid || (wdata !== prev_wdata) || (wstrb !== prev_wstrb))) begin
                $display("FAIL: W valid/payload changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_rvalid && !p_rready && (!rvalid || (rdata !== p_rdata) || (rresp !== p_rresp))) begin
                $display("FAIL: R valid/payload changed before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            if (p_bvalid && !p_bready && !bvalid) begin
                $display("FAIL: B valid dropped before handshake (t=%0t)", $time);
                errors = errors + 1;
            end
            // 地址必须 4 字节对齐, 否则从机会回 SLVERR (mem_subsystem 的取指/load 契约)
            if (s_ar_hs && (s_araddr[1:0] !== 2'b00)) begin
                $display("FAIL: araddr not word aligned: %h", s_araddr);
                errors = errors + 1;
            end
            if (s_aw_hs && (s_awaddr[1:0] !== 2'b00)) begin
                $display("FAIL: awaddr not word aligned: %h", s_awaddr);
                errors = errors + 1;
            end
            // 写事务载荷当场锁存 (指针在 posedge 前进, 之后端口值不再对应本条)
            if (s_aw_hs) begin
                cap_w_addr = s_awaddr; cap_w_data = s_wdata; cap_w_strb = s_wstrb;
            end
            // load 完成脉冲必须与已收下的 load 一一对应 (不少给, 也不多给)
            if (s_lddone_hs && (ld_inflight_tb <= 0)) begin
                $display("FAIL: load completion pulse without an accepted load (t=%0t)", $time);
                errors = errors + 1;
            end
        end
            prev_araddr = araddr; prev_awaddr = awaddr; prev_wdata = wdata; prev_wstrb = wstrb;
            p_arvalid = arvalid; p_arready = arready;
            p_awvalid = awvalid; p_awready = awready;
            p_wvalid  = wvalid;  p_wready  = wready;
            p_rvalid  = rvalid;  p_rready  = rready;  p_rdata = rdata; p_rresp = rresp;
            p_bvalid  = bvalid;  p_bready  = bready;
        end
    endtask

    // 取指侧不变量: 地址寄存器同步 + ★ 交付的数据必须属于该地址 (错绑的结构性排除)
    task mem_check;
        begin
            if (rst_n) begin
                if (dut.imem_addr_q !== s_imem_addr) begin
                    $display("FAIL: imem_addr_q=%h != imem_addr delayed=%h", dut.imem_addr_q, s_imem_addr);
                    errors = errors + 1;
                end
                if ((imem_valid === 1'b1) && (dut.imem_addr_q < (MEM_BYTES - 4))) begin
                    if (inst_data !== mem_word(dut.imem_addr_q)) begin
                        $display("FAIL: imem_valid with wrong data at %h: got %h want %h",
                                 dut.imem_addr_q, inst_data, mem_word(dut.imem_addr_q));
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    task tick;
        begin
            @(negedge clk);
            s_imem_addr = imem_addr;      // posedge 后应出现在 imem_addr_q
            slave_drive;
            #1;
            tb_sample;
            protocol_check;
            slave_step;
            @(posedge clk);
            #1;
            tcyc = tcyc + 1;
            mem_check;
        end
    endtask

    task clr_cpu;
        begin
            ld_start_valid = 1'b0; sw_valid = 1'b0;
            ld_start_addr = 32'd0; ld_start_width = 2'b10; ld_start_idx = 4'd0;
            sw_addr = 32'd0; sw_data = 32'd0; sw_width = 2'b10;
            tb_hold_ar = 1'b0; tb_hold_aw = 1'b0; tb_hold_w = 1'b0;
            tb_hold_r = 1'b0; tb_hold_b = 1'b0;
        end
    endtask

    task do_reset;
        begin
            reset = 1'b1; imem_addr = 32'd0; clr_cpu;
            for (n = 0; n < 5; n = n + 1) tick();
            reset = 1'b0;
            tick();
            tcyc = 0;
        end
    endtask

    // 取指: 驱动地址 A, 等 imem_valid, 再核对数据 (返回等待拍数)
    task fetch_wait;
        input [31:0] a;
        input integer maxn;
        reg hit;
        integer w;
        begin
            imem_addr = a;
            hit = 1'b0; w = 0;
            for (n = 0; (n < maxn) && !hit; n = n + 1) begin
                tick();
                w = w + 1;
                hit = (imem_valid === 1'b1);
            end
            expect(hit, "imem_valid never asserted");
            if (hit) expect(inst_data === mem_word(a), "fetched instruction mismatch");
            fetch_cycles = w;
        end
    endtask

    // load: 发起 (ld_busy==0 的拍必被收下) + 等完成 (恰好一个脉冲)
    task ld_push;
        input [31:0] a;
        input [1:0]  w;
        input [LIW-1:0] idx;
        reg hit;
        begin
            ld_start_valid = 1'b1; ld_start_addr = a; ld_start_width = w; ld_start_idx = idx;
            hit = 1'b0;
            for (n = 0; (n < 400) && !hit; n = n + 1) begin
                tick();
                hit = s_ld_hs;
            end
            ld_start_valid = 1'b0;
            expect(hit, "load start never accepted (ld_busy stuck)");
            if (hit) begin
                ld_inflight_tb = ld_inflight_tb + 1;
                ld_acc_tb = ld_acc_tb + 1;
            end
        end
    endtask

    task ld_wait;
        input integer maxn;
        reg hit;
        begin
            hit = (pend_done > 0);                // 空档期已回 ⇒ 不必再等
            for (n = 0; (n < maxn) && !hit; n = n + 1) begin
                tick();
                hit = (pend_done > 0);            // 数据已在 tb_sample 里当拍锁存
            end
            expect(hit, "load completion never returned");
            if (hit) begin
                pend_done = pend_done - 1;
                ld_inflight_tb = ld_inflight_tb - 1;
                ld_done_tb = ld_done_tb + 1;
            end
        end
    endtask

    // store: 提交级 1 拍脉冲 (只在被收下的那一拍拉高, 不会重复入队)
    task st_push;
        input [31:0] a, d;
        input [1:0]  w;
        reg ok;
        begin
            sw_valid = 1'b1; sw_addr = a; sw_data = d; sw_width = w;
            ok = 1'b0;
            for (n = 0; (n < 400) && !ok; n = n + 1) begin
                tick();
                ok = s_sw_hs;                      // commit_t 在 tb_sample 里按同一口径锁存
            end
            sw_valid = 1'b0;
            expect(ok, "store never accepted (sw_ready stuck low)");
        end
    endtask

    // 等 store 队列排空 (B 已回 + 该 B 之前的 load 已完成 ⇒ 退休)
    task sq_drain;
        input integer maxn;
        reg ok;
        begin
            ok = 1'b0;
            for (n = 0; (n < maxn) && !ok; n = n + 1) begin
                tick();
                ok = (dut.sq_wr_p === dut.sq_ret_p);
            end
            expect(ok, "store queue never drained");
        end
    endtask

    // load 的期望值 (从机模型的字节图案)
    function [31:0] exp_ld;
        input [31:0] a;
        input [1:0]  w;
        reg [31:0] wd;
        begin
            wd = mem_word({a[31:2], 2'b00});
            exp_ld = (w == 2'b10) ? wd
                   : (w == 2'b01) ? {16'd0, wd[a[1:0]*8 +: 16]}
                   : {24'd0, wd[a[1:0]*8 +: 8]};
        end
    endfunction

    integer t1_cyc, t1_total;
    reg same_cycle_hit;
    integer commit_cyc, done_cyc;
    reg [31:0] race_val;

    initial begin
        reset = 1'b1; imem_addr = 32'd0;
        clr_cpu();
        $dumpfile("sim/core/tb_mem_axi.vcd");
        $dumpvars(0, tb_mem_axi);
        for (n = 0; n < 5; n = n + 1) tick();
        reset = 1'b0;
        tick();

        // ---- T1 顺序取指: 冷启动后应约 1 拍/字 ----
        t1_total = 0;
        for (k = 0; k < 16; k = k + 1) begin
            fetch_wait(32'd4 * k, 60);
            if (k == 0) t1_cyc = fetch_cycles;
            t1_total = t1_total + fetch_cycles;
        end
        $display("T1: cold start %0d cycles, 16 sequential words %0d cycles", t1_cyc, t1_total);
        expect(t1_total <= 60, "T1 sequential fetch too slow (prefetch not working)");
        expect(inst_data === mem_word(32'd60), "T1 last word mismatch");
        if (t1_total <= 60) $display("PASS: T1 sequential fetch (16 words in %0d cycles)", t1_total);

        // ---- T2 重定向 / tag 别名 ----
        imem_addr = 32'h0000_0400;
        for (k = 0; k < 3; k = k + 1) begin
            tick();
            expect(imem_valid === 1'b0, "T2 imem_valid before data could arrive (misbinding)");
        end
        fetch_wait(32'h0000_0400, 60);
        expect(inst_data === mem_word(32'h0000_0400), "T2 redirect target data");
        // 0x440 与 0x400 落在同一窗口下标 (addr[5:2] 相同) 但 tag 不同 ⇒ 必须重取, 不得拿旧格顶替
        imem_addr = 32'h0000_0440;
        for (k = 0; k < 2; k = k + 1) begin
            tick();
            expect(imem_valid === 1'b0, "T2 tag alias delivered stale line");
        end
        fetch_wait(32'h0000_0440, 60);
        // 后跳回已在窗口里的地址 (不应重取, 数据仍对)
        fetch_wait(32'h0000_0404, 60);
        expect(inst_data === mem_word(32'h0000_0404), "T2 backward jump data");
        $display("PASS: T2 redirect and tag alias");

        // ---- T3 load 各宽度与零扩展 (取指停到停车位, 别抢带宽) ----
        fetch_wait(FA_PARK, 60);
        for (k = 0; k < 6; k = k + 1) tick();
        // 0x180 处字节为 0x81/0x82 (高位置 1), 用来钉死"零扩展"而非符号扩展
        ld_push(32'h0000_0180, 2'b00, 4'd1); ld_wait(60);
        expect(cap_ld_data === 32'h0000_0081, "T3 LB must zero-extend");
        expect(cap_ld_idx === 4'd1, "T3 LB index passthrough");
        ld_push(32'h0000_0181, 2'b00, 4'd2); ld_wait(60);
        expect(cap_ld_data === 32'h0000_0082, "T3 LB offset 1");
        ld_push(32'h0000_0180, 2'b01, 4'd3); ld_wait(60);
        expect(cap_ld_data === 32'h0000_8281, "T3 LHU must zero-extend half");
        ld_push(32'h0000_0182, 2'b01, 4'd4); ld_wait(60);
        expect(cap_ld_data === 32'h0000_8483, "T3 LHU offset 2");
        ld_push(32'h0000_0180, 2'b10, 4'd5); ld_wait(60);
        expect(cap_ld_data === 32'h8483_8281, "T3 LW");
        ld_push(32'h0000_0183, 2'b00, 4'd6); ld_wait(60);
        expect(cap_ld_data === 32'h0000_0084, "T3 LB offset 3");
        // 非对齐字读: 本模块一个请求只取一个对齐字, 故只给出该字内剩下的字节, 高位补 0
        // (跨字非对齐访问不支持, 见 mem_subsystem 头注释; 编译产出的 C 不会产生)
        ld_push(32'h0000_0182, 2'b10, 4'd7); ld_wait(60);
        expect(cap_ld_data === 32'h0000_8483, "T3 unaligned LW returns bytes within the aligned word");
        ld_push(LA_BASE, 2'b10, 4'd8); ld_wait(60);
        expect(cap_ld_data === mem_word(LA_BASE), "T3 LW pattern");
        $display("PASS: T3 load widths and zero extension (%0d loads)", ld_acc_tb);

        // ---- T4 store 各宽度 strb 与地址对齐 ----
        st_push(SA_BASE, 32'hDEAD_BEEF, 2'b10); sq_drain(80);
        expect(cap_w_addr === SA_BASE, "T4 SW aligned awaddr");
        expect(cap_w_strb === 4'hF, "T4 SW strb");
        expect(cap_w_data === 32'hDEAD_BEEF, "T4 SW data");
        expect(mem_word(SA_BASE) === 32'hDEAD_BEEF, "T4 SW landed");
        st_push(SA_BASE + 32'd2, 32'h0000_1234, 2'b01); sq_drain(80);
        expect(cap_w_addr === SA_BASE, "T4 SH awaddr aligned down");
        expect(cap_w_strb === 4'hC, "T4 SH strb");
        expect(cap_w_data === 32'h1234_0000, "T4 SH data shifted");
        expect(mem_word(SA_BASE) === 32'h1234_BEEF, "T4 SH landed");
        st_push(SA_BASE + 32'd1, 32'h0000_00AB, 2'b00); sq_drain(80);
        expect(cap_w_strb === 4'b0010, "T4 SB strb");
        expect(cap_w_data === 32'h0000_AB00, "T4 SB data shifted");
        expect(mem_word(SA_BASE) === 32'h1234_ABEF, "T4 SB landed");
        st_push(SA_BASE + 32'd3, 32'h0000_00CD, 2'b00); sq_drain(80);
        expect(cap_w_strb === 4'b1000, "T4 SB offset 3 strb");
        expect(cap_w_data === 32'hCD00_0000, "T4 SB offset 3 data");
        expect(mem_word(SA_BASE) === 32'hCD34_ABEF, "T4 SB offset 3 landed");
        st_push(SA_BASE, 32'h0000_BEEF, 2'b01); sq_drain(80);
        expect(cap_w_strb === 4'h3, "T4 SH offset 0 strb");
        expect(mem_word(SA_BASE) === 32'hCD34_BEEF, "T4 SH offset 0 landed");
        $display("PASS: T4 store widths, strb and address alignment");

        // ---- T5 store→load 可见性竞态 ----
        // 已提交的 store 必须一直留在队列里兜底, 直到 B 已握手且该 B 之前的 load 都已回:
        // 写通道压住 (store 落不到从机) 时, 同址 load 从总线读到的是**旧值**, 必须由队列合并改正。
        // 提交时刻相对 load 完成时刻扫描一遍, 覆盖"与完成同拍提交"的那条路径。
        same_cycle_hit = 1'b0;
        for (k = 0; k <= 31; k = k + 1) begin
            do_reset();
            imem_addr = FA_PARK;
            tb_hold_aw = 1'b1; tb_hold_w = 1'b1;      // 写通道压住: B 不来, store 留在队列
            race_val = 32'hB000_0000 + k;
            commit_t = -1; done_t = -2;
            ld_push(RA_BASE + 32'd4 * k, 2'b10, 4'd0);
            for (n = 0; n < k; n = n + 1) tick();
            st_push(RA_BASE + 32'd4 * k, race_val, 2'b10);
            ld_wait(80);
            commit_cyc = commit_t; done_cyc = done_t;
            if (commit_cyc == done_cyc) same_cycle_hit = 1'b1;
            // 提交不晚于完成 ⇒ 必须看到 store 的值; 晚于完成 ⇒ 该 store 尚未进入队列, 应读到旧值
            if (commit_cyc <= done_cyc)
                expect(cap_ld_data === race_val, "T5 committed store must be visible to the load");
            else
                expect(cap_ld_data === exp_ld(RA_BASE + 32'd4 * k, 2'b10),
                       "T5 younger store must not retro-activate an already completed load");
            tb_hold_aw = 1'b0; tb_hold_w = 1'b0;
            for (n = 0; n < 4; n = n + 1) tick();
        end
        expect(same_cycle_hit, "T5 sweep never hit same-cycle commit+completion");
        // 放开写通道: store 必须真的落到从机, 且队列能退休
        do_reset();
        imem_addr = FA_PARK;
        tb_hold_aw = 1'b1; tb_hold_w = 1'b1;
        st_push(RA_BASE + 32'd4 * 32, 32'hFEED_F00D, 2'b10);
        for (n = 0; n < 12; n = n + 1) tick();
        expect(dut.sq_wr_p !== dut.sq_ret_p, "T5 unacked store must stay in queue");
        tb_hold_aw = 1'b0; tb_hold_w = 1'b0;
        sq_drain(120);
        expect(mem_word(RA_BASE + 32'd4 * 32) === 32'hFEED_F00D, "T5 store landed after B");
        expect(dut.sq_wr_p === dut.sq_ret_p, "T5 queue retired after B");
        $display("PASS: T5 store->load visibility race (sweep %0d offsets, same-cycle covered)", 32);

        // ---- T6 复位打断 ----
        do_reset();
        imem_addr = FA_PARK;
        tb_hold_aw = 1'b1; tb_hold_w = 1'b1;
        st_push(RA_BASE + 32'd4 * 40, 32'h0BAD_0BAD, 2'b10);
        ld_push(32'h0000_0600, 2'b10, 4'd9);
        for (n = 0; n < 5; n = n + 1) tick();
        reset = 1'b1;
        for (n = 0; n < 3; n = n + 1) tick();
        expect(imem_valid === 1'b0, "T6 imem_valid during reset");
        expect(ld_done_valid === 1'b0, "T6 load completion during reset");
        expect(arvalid === 1'b0, "T6 AR valid during reset");
        expect(awvalid === 1'b0, "T6 AW valid during reset");
        clr_cpu();
        reset = 1'b0;
        tick();
        expect(dut.sq_wr_p === 0, "T6 store queue cleared by reset");
        expect(dut.pf_valid_r === {PF_DEPTH{1'b0}}, "T6 prefetch window cleared by reset");
        ld_inflight_tb = 0;                    // 复位作废在途 load (完成脉冲不会再来)
        ld_acc_tb = ld_acc_tb - 1;             // 该 load 被复位作废, 账本里也不该再算"收下过"
        // 释放后恢复: 取指与 load 都要正常工作
        imem_addr = 32'h0000_0440;
        fetch_wait(32'h0000_0440, 60);
        expect(inst_data === mem_word(32'h0000_0440), "T6 fetch after reset");
        imem_addr = FA_PARK;
        for (n = 0; n < 6; n = n + 1) tick();
        ld_push(LA_BASE + 32'd4, 2'b10, 4'd3);
        ld_wait(60);
        expect(cap_ld_data === mem_word(LA_BASE + 32'd4), "T6 load after reset");
        expect(cap_ld_idx === 4'd3, "T6 index after reset");
        $display("PASS: T6 reset in the middle of traffic");

        // 账本: 收下与完成必须相等 (不多给也不少给)
        expect(ld_inflight_tb == 0, "load bookkeeping not balanced");
        expect(ld_acc_tb == ld_done_tb, "accepted loads != completed loads");

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end
endmodule
