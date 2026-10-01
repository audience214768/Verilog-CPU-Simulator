// dcache 单元 TB —— 覆盖 dcache.v 文件头里每一条 ★ 不变量。
// 存储模型是本 TB 自带的 (不接 AXI): 需求 load 的 AR 走一条 LOAD_LAT 拍的延迟线,
// 填充请求走另一条 FILL_LAT 拍的延迟线, 两者各自按序回包 —— 与 mem_subsystem 里
// "按 tag 分流、同 tag 内保序" 的效果一致。
//
// 全局账本 (最重要的那条): 每条被接受的 load 必须**恰好**一个完成脉冲
//   n_done (= rsp_valid 脉冲数 + hit_valid 脉冲数) 最终必须等于 n_accept
// 一拍丢脉冲 = LSQ head 卡死; 一拍两个 = 目的寄存器被写两次。
`timescale 1ns/1ps
module tb_dcache;
    localparam DC_SIZE       = 2048;
    localparam DC_LINE_WORDS = 8;
    // 与 student_top 的默认值一致 ⇒ make -f Makefile.tb 走的就是判分配置的多路分支
    // (T4 的 else 支: 灌 DC_WAYS+1 条同组行, 验空路优先 + round-robin 替换)。
    // 想回到单路覆盖: 把这里改回 1, T4 会走 if 支 (同组挤兑)。
    localparam DC_WAYS       = 2;
    localparam LSQ_SIZE      = 16;
    localparam SETS    = DC_SIZE / (4 * DC_LINE_WORDS * DC_WAYS);
    localparam OFF_W   = $clog2(DC_LINE_WORDS);
    localparam IW      = $clog2(SETS);
    localparam SPLIT   = 2 + OFF_W;
    localparam TAGHI   = SPLIT + IW;
    localparam LOAD_LAT = 2;
    localparam FILL_LAT = 6;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer n_accept = 0, n_done = 0, n_ms = 0, n_fill_req = 0;

    // ---------------- DUT 端口 (先声明, 后例化) ----------------
    reg  lk_start;
    reg  [31:0] lk_addr;
    reg  [1:0]  lk_width;
    reg  [3:0]  lk_idx;
    reg         rsp_ovr;                       // TB 注入一拍 load 回包 (撞车测试用)
    reg         ms_ready;
    reg         fill_req_ready;
    reg         inv_valid;
    reg  [31:0] inv_addr;
    reg         clr_valid;
    reg  [31:0] clr_addr;
    reg  [SETS-1:0] sq_blk;

    wire        hit_valid;
    wire [31:0] hit_word, hit_addr;
    wire [1:0]  hit_width;
    wire [3:0]  hit_idx;
    wire        ms_valid;
    wire [31:0] ms_addr;
    wire [1:0]  ms_width;
    wire [3:0]  ms_idx;
    wire        fill_req_valid;
    wire [31:0] fill_req_addr;
    wire        busy, fill_busy;

    wire        b_hit_valid, b_busy, b_fill_busy, b_ms_valid;
    wire [31:0] b_hit_word, b_ms_addr;
    wire [1:0]  b_hit_width;
    wire [3:0]  b_hit_idx;
    wire        b_fill_req_valid;
    wire [31:0] b_fill_req_addr;

    // ---------------- 存储模型 (必须在例化前定义好 rsp/fill 回包) ----------------
    reg [31:0] mem [0:16383];                  // 按字索引: mem[addr[15:2]]
    integer mi;
    initial for (mi = 0; mi < 16384; mi = mi + 1) mem[mi] = 32'hC0DE_0000 | mi[15:0];

    reg  [LOAD_LAT-1:0] lp_v;                  // 需求 load 回包延迟线 (数据不经过 dcache)
    reg  [FILL_LAT-1:0] fp_v;                  // 填充回包延迟线
    reg  [31:0]         fp_a [0:FILL_LAT-1];
    integer fi;

    wire        rsp_valid_w    = lp_v[LOAD_LAT - 1];
    wire        rsp_busy_w     = rsp_valid_w || rsp_ovr;
    wire        fill_rsp_valid = fp_v[FILL_LAT - 1];
    wire [31:0] fill_rsp_data  = mem[fp_a[FILL_LAT - 1][15:2]];
    wire        lk_valid       = lk_start && !busy;   // 与 mem_subsystem 的 ld_accept 同构

    // ---------------- DUT ----------------
    dcache #(
        .DC_SIZE (DC_SIZE), .DC_LINE_WORDS (DC_LINE_WORDS),
        .DC_WAYS (DC_WAYS), .LSQ_SIZE (LSQ_SIZE)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .lk_valid (lk_valid), .lk_addr (lk_addr), .lk_width (lk_width), .lk_idx (lk_idx),
        .rsp_busy (rsp_busy_w),
        .hit_valid (hit_valid), .hit_word (hit_word), .hit_addr (hit_addr),
        .hit_width (hit_width), .hit_idx (hit_idx),
        .ms_valid (ms_valid), .ms_addr (ms_addr), .ms_width (ms_width), .ms_idx (ms_idx),
        .ms_ready (ms_ready),
        .fill_req_valid (fill_req_valid), .fill_req_addr (fill_req_addr),
        .fill_req_ready (fill_req_ready),
        .fill_rsp_valid (fill_rsp_valid), .fill_rsp_data (fill_rsp_data),
        .inv_valid (inv_valid), .inv_addr (inv_addr), .sq_blk (sq_blk),
        .clr_valid (clr_valid), .clr_addr (clr_addr),
        .busy (busy), .fill_busy (fill_busy)
    );

    // 旁路实例: DC_SIZE=0 必须永不命中、永不起填
    dcache #(
        .DC_SIZE (0), .DC_LINE_WORDS (DC_LINE_WORDS), .DC_WAYS (DC_WAYS), .LSQ_SIZE (LSQ_SIZE)
    ) dut_off (
        .clk (clk), .rst_n (rst_n),
        .lk_valid (lk_valid), .lk_addr (lk_addr), .lk_width (lk_width), .lk_idx (lk_idx),
        .rsp_busy (rsp_busy_w),
        .hit_valid (b_hit_valid), .hit_word (b_hit_word), .hit_addr (), .hit_width (b_hit_width),
        .hit_idx (b_hit_idx),
        .ms_valid (b_ms_valid), .ms_addr (b_ms_addr), .ms_width (), .ms_idx (), .ms_ready (ms_ready),
        .fill_req_valid (b_fill_req_valid), .fill_req_addr (b_fill_req_addr),
        .fill_req_ready (1'b1),
        .fill_rsp_valid (1'b0), .fill_rsp_data (32'd0),
        .inv_valid (1'b0), .inv_addr (32'd0), .sq_blk (1'b0),
        .clr_valid (1'b0), .clr_addr (32'd0),
        .busy (b_busy), .fill_busy (b_fill_busy)
    );

    // ---------------- 延迟线 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lp_v <= {LOAD_LAT{1'b0}};
            fp_v <= {FILL_LAT{1'b0}};
        end else begin
            lp_v[0] <= ms_valid && ms_ready;
            for (fi = 1; fi < LOAD_LAT; fi = fi + 1) lp_v[fi] <= lp_v[fi - 1];
            fp_v[0] <= fill_req_valid && fill_req_ready;
            fp_a[0] <= fill_req_addr;
            for (fi = 1; fi < FILL_LAT; fi = fi + 1) begin
                fp_v[fi] <= fp_v[fi - 1];
                fp_a[fi] <= fp_a[fi - 1];
            end
        end
    end

    // ---------------- 全局账本 / 常驻断言 ----------------
    always @(posedge clk) begin
        if (rst_n) begin
            if (lk_valid)            n_accept   <= n_accept + 1;
            // 账本只数**真实**交付: rsp_ovr 是 TB 为撞车测试注入的合成脉冲, 不对应任何 AR
            if (rsp_valid_w)         n_done     <= n_done + 1;
            if (hit_valid)           n_done     <= n_done + 1;
            if (ms_valid && ms_ready) n_ms      <= n_ms + 1;
            if (fill_req_valid && fill_req_ready) n_fill_req <= n_fill_req + 1;
            // 交付端口只有一个源: 命中与真实回包绝不同拍
            if (hit_valid && rsp_valid_w) begin
                $display("FAIL: hit_valid 与 rsp_valid 同拍 (t=%0t)", $time);
                errors = errors + 1;
            end
            // 旁路实例永不命中 / 永不起填
            if (b_hit_valid)      begin $display("FAIL: DC_SIZE=0 竟命中"); errors = errors + 1; end
            if (b_fill_req_valid) begin $display("FAIL: DC_SIZE=0 竟起填"); errors = errors + 1; end
        end
    end

    // ---------------- 驱动任务 ----------------
    task do_reset;
        begin
            rst_n = 1'b0; lk_start = 1'b0; lk_addr = 32'd0; lk_width = 2'd2; lk_idx = 4'd0;
            rsp_ovr = 1'b0; ms_ready = 1'b1; fill_req_ready = 1'b1;
            inv_valid = 1'b0; inv_addr = 32'd0; sq_blk = {SETS{1'b0}};
            clr_valid = 1'b0; clr_addr = 32'd0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // 激励一律在 negedge 驱动、在 negedge 采样 —— posedge 上 DUT 采样、TB 也可能驱动,
    // 同一个时隙读写同一根线会出竞争。半拍错开后时序完全确定。
    task idle(input integer n);
        integer k;
        begin for (k = 0; k < n; k = k + 1) @(negedge clk); end
    endtask

    task chk(input cond, input [8*96-1:0] msg);
        begin
            if (!cond) begin $display("FAIL: %0s (t=%0t)", msg, $time); errors = errors + 1; end
        end
    endtask

    // 接受一条 load: 先等不忙, 再抬 lk_start 并确认真的握手了才放下
    task accept(input [31:0] a, input [1:0] w, input [3:0] ix);
        integer guard;
        begin
            guard = 0;
            lk_addr = a; lk_width = w; lk_idx = ix; lk_start = 1'b0;
            @(negedge clk);
            while (busy && guard < 400) begin @(negedge clk); guard = guard + 1; end
            lk_start = 1'b1;
            #1;                          // 让连续赋值走过一个 delta 再读 lk_valid
            if (!lk_valid) begin
                $display("FAIL: 抬了 lk_start 却没握手 (busy 抢跑) t=%0t", $time); errors = errors + 1;
            end
            @(posedge clk);              // 握手
            @(negedge clk);
            lk_start = 1'b0;
        end
    endtask

    // 等 ms 推送并检查地址/idx
    task expect_ms(input [31:0] a, input [3:0] ix);
        integer guard;
        begin
            guard = 0;
            while (!(ms_valid && ms_ready) && guard < 400) begin @(negedge clk); guard = guard + 1; end
            if (guard >= 400) begin
                $display("FAIL: 等不到 ms 推送 (addr=%h, t=%0t)", a, $time);
                errors = errors + 1;
            end else begin
                if (ms_addr !== a)  begin $display("FAIL: ms_addr=%h 应为 %h", ms_addr, a); errors = errors + 1; end
                if (ms_idx  !== ix) begin $display("FAIL: ms_idx=%0d 应为 %0d", ms_idx, ix);  errors = errors + 1; end
            end
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    // 等填充跑完。填充可能**已经跑完** (比如被合并的 load 命中时填充刚好结束), 那也算通过 ——
    // 真正判对错的是随后的 expect_hit / expect_ms。
    task run_fill;
        integer guard;
        begin
            guard = 0;
            while (!fill_busy && guard < 40) begin @(negedge clk); guard = guard + 1; end
            guard = 0;
            while (fill_busy && guard < 400) begin @(negedge clk); guard = guard + 1; end
            if (guard >= 400) begin $display("FAIL: fill 不落 (t=%0t)", $time); errors = errors + 1; end
            @(negedge clk);
        end
    endtask

    task expect_hit(input [31:0] a, input [3:0] ix, input [31:0] wd);
        integer guard;
        begin
            guard = 0;
            while (!hit_valid && guard < 400) begin @(negedge clk); guard = guard + 1; end
            if (guard >= 400) begin
                $display("FAIL: 等不到命中 (addr=%h, t=%0t)", a, $time); errors = errors + 1;
            end else begin
                if (hit_addr !== a)  begin $display("FAIL: hit_addr=%h 应为 %h", hit_addr, a); errors = errors + 1; end
                if (hit_idx  !== ix) begin $display("FAIL: hit_idx=%0d 应为 %0d", hit_idx, ix);   errors = errors + 1; end
                if (hit_word !== wd) begin $display("FAIL: hit_word=%h 应为 %h", hit_word, wd);   errors = errors + 1; end
            end
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task wait_done(input integer guard_max, input [255:0] msg);
        integer guard;
        begin
            guard = 0;
            while (!(hit_valid || rsp_busy_w) && guard < guard_max) begin @(negedge clk); guard = guard + 1; end
            if (guard >= guard_max) begin $display("FAIL: %0s", msg); errors = errors + 1; end
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    // 把一整行填好并等稳定
    task fill_line(input [31:0] base);
        begin
            accept(base, 2'd2, 4'd0);
            expect_ms(base, 4'd0);
            run_fill;
            idle(2);
        end
    endtask

    // ---------------- 主流程 ----------------
    integer cap_n, ms_n, done_n;
    integer wt;                                       // T4 多路分支的行 tag 循环
    initial begin
        $dumpfile("sim/core/tb_dcache.vcd");
        $dumpvars(0, tb_dcache);

        // ============ T1 复位恒等 ============
        $display("=== T1 复位恒等");
        do_reset;
        idle(2);
        chk(!hit_valid && !fill_busy && !busy, "T1 复位后应为空闲");
        chk(!b_hit_valid && !b_busy && !b_fill_busy, "T1b DC_SIZE=0 复位后应为空闲");

        // ============ T2 缺失 → 填充 → 再命中 ============
        $display("=== T2 缺失 → 填充 → 再命中");
        accept(32'h0000_0004, 2'd2, 4'd1);
        expect_ms(32'h0000_0004, 4'd1);
        run_fill;
        idle(2);
        accept(32'h0000_0004, 2'd2, 4'd2);
        expect_hit(32'h0000_0004, 4'd2, 32'hC0DE_0001);

        // ============ T3 填充途中同行 load 合并 (不发 AR) 且重放后命中 ============
        $display("=== T3 填充途中同行 load 合并 (不发 AR) 且重放后命中");
        ms_n = n_ms;
        accept(32'h0000_0040, 2'd2, 4'd3);        // set 2, 触发新填充
        expect_ms(32'h0000_0040, 4'd3);
        idle(2);
        accept(32'h0000_0058, 2'd2, 4'd4);        // 同一行第 6 字, 填充中 ⇒ 应合并
        idle(3);
        chk(n_ms == ms_n + 1, "T3 合并的 load 不该再发 AR");
        expect_hit(32'h0000_0058, 4'd4, 32'hC0DE_0016);
        run_fill;
        idle(2);

        // ============ T4 起填即清 valid ⇒ 半行不得假命中; tag 比较有效 ============
        $display("=== T4 起填即清 valid ⇒ 半行不得假命中; tag 比较有效");
        if (DC_WAYS == 1) begin
            fill_line(32'h0000_0800);                 // set 0, tag 1
            accept(32'h0000_0800, 2'd2, 4'd5);
            expect_hit(32'h0000_0800, 4'd5, 32'hC0DE_0200);
            idle(2);
            accept(32'h0000_0000, 2'd2, 4'd6);        // 同 set 不同 tag, 把它挤掉
            expect_ms(32'h0000_0000, 4'd6);
            run_fill;
            idle(2);
            accept(32'h0000_0800, 2'd2, 4'd7);        // 被挤掉 ⇒ 必须缺失
            expect_ms(32'h0000_0800, 4'd7);
            run_fill;
            idle(2);
        end else begin
            // 多路: 同组灌 DC_WAYS+1 条不同 tag 的行 —— 前 DC_WAYS 条各占一路, 全命中;
            // 第 DC_WAYS+1 条触发替换 (空路优先 + round-robin), 挤掉的是组内第 1 条。
            for (wt = 5; wt <= 5 + DC_WAYS; wt = wt + 1) fill_line(wt[15:0] << TAGHI);
            accept(32'd5 << TAGHI, 2'd2, 4'd6);       // 组内第 1 条: 必已被换出
            expect_ms(32'd5 << TAGHI, 4'd6);
            run_fill;
            idle(2);
            accept((32'd5 + DC_WAYS) << TAGHI, 2'd2, 4'd7);   // 最后灌进去的那条仍在
            expect_hit((32'd5 + DC_WAYS) << TAGHI, 4'd7,
                       32'hC0DE_0000 | (((32'd5 + DC_WAYS) << TAGHI) >> 2));
            idle(2);
        end

        // ============ T5 store 失效的**两个**时点: 提交不清 valid, 退休才清 (按索引, 不看 tag) ============
        $display("=== T5 store 提交不清 valid (仍命中), 退休才清 (必缺失)");
        // 先把 set 0 清干净再重填 0x0800 那行 —— T4 各分支留下的组内状态不同, 这里不依赖它
        @(negedge clk); clr_valid = 1'b1; clr_addr = 32'h0000_0800;
        @(negedge clk); clr_valid = 1'b0;
        idle(1);
        accept(32'h0000_0800, 2'd2, 4'd8);        // 刚失效 ⇒ 必缺失, 填上
        expect_ms(32'h0000_0800, 4'd8);
        run_fill;
        idle(2);
        accept(32'h0000_0808, 2'd2, 4'd8);        // 0x0800 那行刚填好 ⇒ 命中
        expect_hit(32'h0000_0808, 4'd8, 32'hC0DE_0202);
        idle(1);
        // ★ 提交一拍: 行**不下架**。该行那个字确实已经旧了, 但字节由 mem_subsystem 的合并链
        //   (sq_merge_byte_f) 在交付时逐字节覆盖, 覆盖窗口与这里的 valid 窗口同拍结束。
        @(negedge clk); inv_valid = 1'b1; inv_addr = 32'h0000_0000;  // 同组 (set 0) 不同行
        @(negedge clk); inv_valid = 1'b0;
        idle(1);
        accept(32'h0000_0808, 2'd2, 4'd9);
        expect_hit(32'h0000_0808, 4'd9, 32'hC0DE_0202);   // 提交**不**清 valid ⇒ 仍命中
        idle(1);
        // ★ 退休一拍: 清该组**全部路** (不看 tag) —— 此后缓存里那个字节是错值, 必须下架
        @(negedge clk); clr_valid = 1'b1; clr_addr = 32'h0000_0000;
        @(negedge clk); clr_valid = 1'b0;
        idle(1);
        accept(32'h0000_0808, 2'd2, 4'd10);
        expect_ms(32'h0000_0808, 4'd10);          // 退休清同组 ⇒ 必缺失
        run_fill;
        idle(2);

        // ============ T6 起填时 SQ 有未落盘的同组 store ⇒ 本次填充作废 ============
        $display("=== T6 起填时 SQ 有未落盘的同组 store ⇒ 本次填充作废");
        accept(32'h0000_0020, 2'd2, 4'd11);       // set 1
        expect_ms(32'h0000_0020, 4'd11);
        run_fill;
        idle(2);
        accept(32'h0000_0020, 2'd2, 4'd12);
        expect_hit(32'h0000_0020, 4'd12, 32'hC0DE_0008);
        idle(1);
        @(negedge clk); clr_valid = 1'b1; clr_addr = 32'h0000_0020;  // 先失效, 再重填
        @(negedge clk); clr_valid = 1'b0;
        sq_blk[1] = 1'b1;
        idle(1);
        accept(32'h0000_0020, 2'd2, 4'd13);
        expect_ms(32'h0000_0020, 4'd13);
        run_fill;
        idle(2);
        accept(32'h0000_0020, 2'd2, 4'd14);
        expect_ms(32'h0000_0020, 4'd14);          // 被污染 ⇒ 还是缺失
        run_fill;
        idle(2);
        sq_blk = {SETS{1'b0}};
        idle(1);
        accept(32'h0000_0020, 2'd2, 4'd15);       // 干净了 ⇒ 这次装得上
        expect_ms(32'h0000_0020, 4'd15);
        run_fill;
        idle(2);
        accept(32'h0000_0020, 2'd2, 4'd0);
        expect_hit(32'h0000_0020, 4'd0, 32'hC0DE_0008);

        // ============ T7 填充途中才出现未落盘的 store ⇒ 同样作废 ============
        $display("=== T7 填充途中才出现未落盘的 store ⇒ 同样作废");
        accept(32'h0000_0060, 2'd2, 4'd1);        // set 3
        expect_ms(32'h0000_0060, 4'd1);
        idle(2);
        sq_blk[3] = 1'b1;                         // 填到一半才出现
        idle(3);
        sq_blk[3] = 1'b0;
        idle(16);
        accept(32'h0000_0060, 2'd2, 4'd2);        // 必须缺失
        expect_ms(32'h0000_0060, 4'd2);
        run_fill;
        idle(2);

        // ============ T8 填充全程 store 提交到同组 ⇒ 写被抑制, 不置 valid ============
        $display("=== T8 填充全程 store 提交到同组 ⇒ 写被抑制, 不置 valid");
        accept(32'h0000_0080, 2'd2, 4'd3);        // set 4; 这一笔的填充即将开始
        expect_ms(32'h0000_0080, 4'd3);
        repeat (FILL_LAT + DC_LINE_WORDS + 6) begin       // 覆盖整个填充写窗口
            @(negedge clk);
            inv_valid = 1'b1; inv_addr = 32'h0000_0080;
        end
        inv_valid = 1'b0;
        idle(2);
        accept(32'h0000_0080, 2'd2, 4'd4);
        expect_ms(32'h0000_0080, 4'd4);           // 写全被抑制 ⇒ 没装上 ⇒ 还是缺失
        run_fill;                                  // 这一次干净, 会装上
        idle(2);
        accept(32'h0000_0080, 2'd2, 4'd5);
        expect_hit(32'h0000_0080, 4'd5, 32'hC0DE_0020);

        // ============ T9 缺失推送被 ready 挡住 (park) 后地址不得丢失 ============
        $display("=== T9 缺失推送被 ready 挡住 (park) 后地址不得丢失");
        ms_ready = 1'b0;
        idle(1);
        accept(32'h0000_00A4, 2'd2, 4'd7);
        idle(3);
        chk(busy, "T9 park 期间 busy 应为 1");
        ms_ready = 1'b1;
        expect_ms(32'h0000_00A4, 4'd7);           // 被 park 的地址必须原样推出
        run_fill;
        idle(2);
        accept(32'h0000_00A4, 2'd2, 4'd8);
        expect_hit(32'h0000_00A4, 4'd8, 32'hC0DE_0029);

        // ============ T10 命中撞回包 ⇒ 降级为缺失, 交付脉冲不重不漏 ============
        $display("=== T10 命中撞回包 ⇒ 降级为缺失, 交付脉冲不重不漏");
        cap_n  = n_accept;
        done_n = n_done;
        ms_n   = n_ms;
        accept(32'h0000_0024, 2'd2, 4'd9);        // set 1, 已填好 ⇒ 会命中
        rsp_ovr = 1'b1;                            // accept 返回即命中判定那一拍, 当场注入回包
        @(negedge clk);
        rsp_ovr = 1'b0;
        idle(1);
        chk(n_ms == ms_n + 1, "T10 demoted hit must push one AR");
        wait_done(200, "T10 no delivery after demotion");
        idle(4);
        chk(n_accept - cap_n == 1, "T10 exactly one load accepted");
        chk(n_done - done_n == 1, "T10 exactly one delivery (hit suppressed, AXI delivers)");

        // ============ T11 背靠背访问不丢交付、不错配 idx ============
        $display("=== T11 背靠背访问不丢交付、不错配 idx");
        fill_line(32'h0000_0100);                 // set 8
        idle(1);
        accept(32'h0000_0100, 2'd2, 4'd10); expect_hit(32'h0000_0100, 4'd10, 32'hC0DE_0040);
        accept(32'h0000_0104, 2'd2, 4'd11); expect_hit(32'h0000_0104, 4'd11, 32'hC0DE_0041);
        accept(32'h0000_0108, 2'd2, 4'd12); expect_hit(32'h0000_0108, 4'd12, 32'hC0DE_0042);
        accept(32'h0000_010C, 2'd2, 4'd13); expect_hit(32'h0000_010C, 4'd13, 32'hC0DE_0043);
        idle(2);

        // ============ T12 填充中复位 ⇒ 干净重启 ============
        $display("=== T12 填充中复位 ⇒ 干净重启");
        accept(32'h0000_0180, 2'd2, 4'd14);       // set 12
        expect_ms(32'h0000_0180, 4'd14);
        idle(2);
        rst_n = 1'b0;
        idle(3);
        rst_n = 1'b1;
        idle(2);
        chk(!fill_busy && !hit_valid, "T12 复位后 fill_busy/hit_valid 应为 0");
        accept(32'h0000_0180, 2'd2, 4'd15);
        expect_ms(32'h0000_0180, 4'd15);
        run_fill;
        idle(2);
        accept(32'h0000_0180, 2'd2, 4'd0);
        expect_hit(32'h0000_0180, 4'd0, 32'hC0DE_0060);

        // ============ 收尾: 全局账本 ============
        idle(200);                                 // 排空所有在飞的 AR
        if (n_accept != n_done) begin
            $display("FAIL 账本: 接受 %0d 条, 完成 %0d 条", n_accept, n_done);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED  (accept=%0d done=%0d ms=%0d fill_req=%0d)",
                     n_accept, n_done, n_ms, n_fill_req);
            $finish;
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
    end

    // 超时保护
    initial begin
        #4000000;
        $display("FAIL: 仿真超时");
        $display("1 TESTS FAILED");
        $stop;
    end
endmodule
