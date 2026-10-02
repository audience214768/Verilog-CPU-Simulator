// dcache 单元 TB —— 覆盖 dcache.v 文件头里每一条 ★ 不变量 (写回版)。
// 存储模型是本 TB 自带的 (不接 AXI): 需求 load 的 AR 走一条 LOAD_LAT 拍的延迟线,
// 填充请求走另一条 FILL_LAT 拍的延迟线, 两者各自按序回包 —— 与 mem_subsystem 里
// "按 tag 分流、同 tag 内保序" 的效果一致。写通道 (WB 排水) 同样有个小模型: 收下即记账,
// WB_LAT 拍后回一个 B。B 与 W 一一对应, 与 axi_lite_master 的口径相同。
//
// 全局账本 (最重要的那条): 每条被接受的 load 必须**恰好**一个完成脉冲
//   n_done (= rsp_valid 脉冲数 + hit_valid 脉冲数) 最终必须等于 n_accept
// 一拍丢脉冲 = LSQ head 卡死; 一拍两个 = 目的寄存器被写两次。
//
// store 退休口 (第 9 节契约) 的驱动全部经由 store_ret / 常驻断言:
//   · st_valid 保持到 st_absorb/st_bypass 之一抬起 (TB 里由 store_ret 保证);
//   · 二者互斥, 且 st_absorb 绝不与安装写 (dut.fill_wr_w) 同拍 (SRAM 单口);
//   · 偷读必须走重放: 不产生 ms 推送、不丢交付脉冲 (T12);
//   · 命中抢不到交付口 (rsp_busy) 也必须走**重放**, 不许降级成缺失 (T10, 写回特有)。
//
// WB 口: 受害路脏 ⇒ 捕获读 + DC_LINE_WORDS 笔整字写 + 逐笔 B; TB 核对地址/数据/笔数 (T15)。
`timescale 1ns/1ps
module tb_dcache;
    localparam DC_SIZE       = 2048;
    localparam DC_LINE_WORDS = 8;
    // TB 自带参数副本 (不随 student_top.v 的基准参数变, 见 tools/README 坑 4) ⇒
    // make -f Makefile.tb 走的就是多路分支 (T4 的 else 支: 灌 DC_WAYS+1 条同组行,
    // 验空路优先 + round-robin 替换)。
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
    localparam WB_LAT   = 3;                      // WB 每笔写 → B 的延迟

    // store 退休回答的编码 (K_ANY = 不检查)
    localparam K_ANY = 2'd0, K_ABSORB = 2'd1, K_BYPASS = 2'd2;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer n_accept = 0, n_done = 0, n_ms = 0, n_fill_req = 0, n_gate = 0, n_steal = 0, n_byp = 0;

    // ---------------- DUT 端口 (先声明, 后例化) ----------------
    reg  lk_start;
    reg  [31:0] lk_addr;
    reg  [1:0]  lk_width;
    reg  [3:0]  lk_idx;
    reg         rsp_ovr;                       // TB 注入一拍 load 回包 (撞车测试用)
    reg         ms_ready;
    reg         fill_req_ready;
    reg         fill_blk;                      // TB 扮演 mem_subsystem 的行粒度污染判定
    reg         st_valid;
    reg  [31:0] st_addr, st_data;
    reg  [1:0]  st_width;
    reg         wb_ready;                      // 写通道背压 (WB 排水用)

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
    wire [31:0] fill_line_w;                  // dcache 的"本拍有效填充行" (与 task fill_line 重名 ⇒ 加后缀)
    wire        busy, fill_busy;
    wire        st_absorb, st_bypass;
    wire        wb_req_valid;
    wire [31:0] wb_req_addr, wb_req_data;

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

    // ---- 写通道模型: 收下记账 + 延迟回 B; 数据/地址留给 T15..T17 核对 ----
    reg  [WB_LAT-1:0] bp_v;
    integer bi;
    wire wb_hs = wb_req_valid && wb_ready;
    wire wb_resp_valid = bp_v[WB_LAT - 1];
    integer    wb_n = 0;                       // 已收下的写回笔数 (integer 不初始化就是 x!)
    reg [31:0] wb_log_a [0:63], wb_log_d [0:63];

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
        .fill_line (fill_line_w), .fill_blk (fill_blk),
        .st_valid (st_valid), .st_addr (st_addr), .st_data (st_data), .st_width (st_width),
        .st_absorb (st_absorb), .st_bypass (st_bypass),
        .wb_req_valid (wb_req_valid), .wb_req_addr (wb_req_addr), .wb_req_data (wb_req_data),
        .wb_req_ready (wb_ready), .wb_resp_valid (wb_resp_valid),
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
        .fill_line (), .fill_blk (1'b0),
        .st_valid (1'b0), .st_addr (32'd0), .st_data (32'd0), .st_width (2'd2),
        .st_absorb (), .st_bypass (),
        .wb_req_valid (), .wb_req_addr (), .wb_req_data (),
        .wb_req_ready (1'b1), .wb_resp_valid (1'b0),
        .busy (b_busy), .fill_busy (b_fill_busy)
    );

    // ---------------- 延迟线 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lp_v <= {LOAD_LAT{1'b0}};
            fp_v <= {FILL_LAT{1'b0}};
            bp_v <= {WB_LAT{1'b0}};
        end else begin
            lp_v[0] <= ms_valid && ms_ready;
            for (fi = 1; fi < LOAD_LAT; fi = fi + 1) lp_v[fi] <= lp_v[fi - 1];
            fp_v[0] <= fill_req_valid && fill_req_ready;
            fp_a[0] <= fill_req_addr;
            for (fi = 1; fi < FILL_LAT; fi = fi + 1) begin
                fp_v[fi] <= fp_v[fi - 1];
                fp_a[fi] <= fp_a[fi - 1];
            end
            bp_v[0] <= wb_hs;
            for (bi = 1; bi < WB_LAT; bi = bi + 1) bp_v[bi] <= bp_v[bi - 1];
        end
    end

    // 写回记账 (TB 观测; 综合无此逻辑)
    always @(posedge clk) begin
        if (rst_n && wb_hs) begin
            wb_log_a[wb_n[5:0]] = wb_req_addr;
            wb_log_d[wb_n[5:0]] = wb_req_data;
            wb_n = wb_n + 1;
            // 写回落地 ⇒ 内存变新。后续填充读 mem 时必须读到它 (T14 末尾就查这一点)
            mem[wb_req_addr[15:2]] = wb_req_data;
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
            // ---- store 退休口的常驻不变量 ----
            if (st_absorb && st_bypass) begin
                $display("FAIL: st_absorb/st_bypass 同时抬起 (t=%0t)", $time);
                errors = errors + 1;
            end
            // 单口 SRAM: store 就地更新绝不能与安装写同拍
            if (st_absorb && dut.fill_wr_w) begin
                $display("FAIL: store 就地更新与安装写抢 SRAM 口 (t=%0t)", $time);
                errors = errors + 1;
            end
            // 让路路径被走到的证据 (T13 末尾检查)
            if (st_valid && dut.fill_wr_w && !st_absorb) n_gate <= n_gate + 1;
            // 偷读路径被走到的证据: 本拍正要对这笔 load 判定, 而它的读被写偷走了 (T12 末尾检查)
            if (dut.lk_v_r && !dut.lk_replay_r && !dut.lk_miss_r && !dut.lk_wait_r && !dut.rd_ok_r)
                n_steal <= n_steal + 1;
            // 未命中还声称吸收 = 写错行
            if (st_absorb && !st_valid) begin
                $display("FAIL: 无 st_valid 却 st_absorb (t=%0t)", $time);
                errors = errors + 1;
            end
            // ---- M2 填充旁路的常驻不变量: 旁路交付必须与**在填行**同行 ----
            // lk_wait_r 有两条来路 (lk_wait_src_w = 等同行填充 | **等写回**), 等写回那条根本没有
            // "在填的行就是我这一行"这回事。判据若只比行内字偏移 ⇒ 别的行的填充只要字偏移撞上,
            // 就把**别人行的数据**交付出去 = 静默算错 (实测代价: perf_rsort 退出值 0→1)。
            // 这条断言让它一旦复发就当场炸; T15b 负责把那个场景造出来。
            if (dut.byp_valid_w && (dut.lk_addr_r[31:SPLIT] !== dut.fill_base_r[31:SPLIT])) begin
                $display("FAIL: 填充旁路跨行交付 (lk=%h 在填=%h, t=%0t)",
                         dut.lk_addr_r, dut.fill_base_r, $time);
                errors = errors + 1;
            end
            if (dut.byp_valid_w) n_byp <= n_byp + 1;
            // WB 三笔账: 排水笔数 = 整行; 每笔地址递增 4; B 不许多不许少 (由 wb_bcnt 守恒保证)
            if (wb_req_valid && wb_req_valid && !wb_ready && !dut.wb_v_r) begin
                $display("FAIL: 无 wb_v_r 却抬 wb_req_valid (t=%0t)", $time);
                errors = errors + 1;
            end
        end
    end

    // ---------------- 驱动任务 ----------------
    task do_reset;
        begin
            rst_n = 1'b0; lk_start = 1'b0; lk_addr = 32'd0; lk_width = 2'd2; lk_idx = 4'd0;
            rsp_ovr = 1'b0; ms_ready = 1'b1; fill_req_ready = 1'b1;
            fill_blk = 1'b0;
            st_valid = 1'b0; st_addr = 32'd0; st_data = 32'd0; st_width = 2'd2;
            wb_ready = 1'b1;
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

    // 等写回排到第 n_beats 笔, 且 8 个 B 全部收齐 (hold 落下)
    task run_wb(input integer n_beats);
        integer guard;
        begin
            guard = 0;
            while ((wb_n < n_beats) && guard < 400) begin @(negedge clk); guard = guard + 1; end
            if (guard >= 400) begin $display("FAIL: 写回排水不落 (t=%0t)", $time); errors = errors + 1; end
            guard = 0;
            while (dut.wb_hold_r && guard < 400) begin @(negedge clk); guard = guard + 1; end
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

    // 一条 store 退休: 抬 st_valid 并等回答 (回答可以晚若干拍 —— 安装写/捕获读占口时要让路)。
    // kind_exp = K_ANY 时不检查是两种中的哪一种; 不匹配 (或等不到) 都算失败。
    task store_ret(input [31:0] a, input [31:0] d, input [1:0] w, input [1:0] kind_exp);
        integer guard;
        reg [1:0] kind;
        begin
            guard = 0;
            @(negedge clk);
            st_addr = a; st_data = d; st_width = w; st_valid = 1'b1;
            #1;
            kind = st_absorb ? K_ABSORB : st_bypass ? K_BYPASS : K_ANY;
            while (kind == K_ANY && guard < 400) begin
                @(negedge clk); #1;
                kind = st_absorb ? K_ABSORB : st_bypass ? K_BYPASS : K_ANY;
                guard = guard + 1;
            end
            if (kind == K_ANY) begin
                $display("FAIL: store 退休等不到回答 (addr=%h, t=%0t)", a, $time); errors = errors + 1;
            end else if (kind_exp != K_ANY && kind !== kind_exp) begin
                $display("FAIL: store 退休回答 %0d 应为 %0d (addr=%h, t=%0t)", kind, kind_exp, a, $time);
                errors = errors + 1;
            end
            @(posedge clk);              // DUT 在这一拍落盘 (SRAM 写 / 置脏)
            @(negedge clk);
            st_valid = 1'b0;
            idle(1);
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
    integer cap_n, ms_n, done_n, wb_n0;
    reg     st_ans;
    integer wt;                                       // T4 多路分支的行 tag 循环
    integer gate_n;                                   // T13 的让路拍数快照
    integer byp_n;                                    // T15b 的旁路拍数快照
    reg [31:0] wb_a;                                  // T15b 正在写回的那一行 (受害行由替换策略定, 不写死)
    integer k;
    integer g8;                                       // T8/T8b 的等待计数器
    initial begin
        $dumpfile("sim/core/tb_dcache.vcd");
        $dumpvars(0, tb_dcache);

        // ============ T1 复位恒等 ============
        $display("=== T1 复位恒等");
        do_reset;
        idle(2);
        chk(!hit_valid && !fill_busy && !busy, "T1 复位后应为空闲");
        chk(!b_hit_valid && !b_busy && !b_fill_busy, "T1b DC_SIZE=0 复位后应为空闲");
        chk(!st_absorb && !st_bypass, "T1c 复位后 store 口应无回答");
        chk(!wb_req_valid, "T1d 复位后写回口应为空");

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

        // ============ T5 store 退休两态: 命中(整字/部分字)就地更新 / 未命中旁路 ============
        // 用 set 16 (0x0600) 与 set 20 (0x0280) —— 前面几条只碰过 set 0/1/2, 状态干净。
        $display("=== T5 store 退休: 吸收 (整字+部分字) / 旁路");
        fill_line(32'h0000_0600);                 // set 16
        accept(32'h0000_0608, 2'd2, 4'd8);
        expect_hit(32'h0000_0608, 4'd8, 32'hC0DE_0182);
        idle(1);
        // ★ 命中的行在**填充期间**同样不许判旁路 (见 T8): 这里先确认普通命中路径不受影响。
        accept(32'h0000_0608, 2'd2, 4'd9);
        expect_hit(32'h0000_0608, 4'd9, 32'hC0DE_0182);
        idle(1);
        // (a) 整字命中 ⇒ 就地更新 + 置脏: 之后命中读到的必须是新值 (本轮改动的主收益)
        store_ret(32'h0000_0608, 32'hA5A5_5A5A, 2'd2, K_ABSORB);
        accept(32'h0000_0608, 2'd2, 4'd10);
        expect_hit(32'h0000_0608, 4'd10, 32'hA5A5_5A5A);
        idle(1);
        // (b) 部分字命中 ⇒ 同样吸收 (字节掩码 ⇒ 1 拍), **不再下架整行**。
        //     字节口径: 写 0xFF 到 0x0609 = 字 0x0608 的 byte1 ⇒ 0xA5A5_5A5A → 0xA5A5_FF5A
        store_ret(32'h0000_0609, 32'h0000_00FF, 2'd0, K_ABSORB);
        accept(32'h0000_0608, 2'd2, 4'd11);
        expect_hit(32'h0000_0608, 4'd11, 32'hA5A5_FF5A);
        idle(1);
        // 半字写 0xBEEF 到 0x060A (byte2/3) ⇒ 0xA5A5_FF5A → 0xBEEF_FF5A
        store_ret(32'h0000_060A, 32'h0000_BEEF, 2'd1, K_ABSORB);
        accept(32'h0000_0608, 2'd2, 4'd12);
        expect_hit(32'h0000_0608, 4'd12, 32'hBEEF_FF5A);
        idle(1);
        // (c) 未命中 ⇒ 旁路: 缓存里不留行 ⇒ 下一次访问仍缺失 (数据另走 AXI, 由上层管)
        store_ret(32'h0000_0280, 32'h1234_5678, 2'd2, K_BYPASS);
        accept(32'h0000_0280, 2'd2, 4'd13);
        expect_ms(32'h0000_0280, 4'd13);
        run_fill;
        idle(2);
        // (d) 非缓存 (MMIO) 地址 ⇒ 即使命中也不许吸收 (终止 store 必须上总线)
        store_ret(32'h8000_0000, 32'h0000_0001, 2'd2, K_BYPASS);

        // ============ T6 行粒度污染: 起填那拍 fill_blk=1 ⇒ 本次填充作废 ============
        $display("=== T6 行粒度污染 ⇒ 本次填充作废");
        accept(32'h0000_0020, 2'd2, 4'd11);       // set 1
        expect_ms(32'h0000_0020, 4'd11);
        chk(fill_line_w[31:SPLIT] === (32'h0000_0020 >> SPLIT), "T6 fill_line 应给出本行");
        fill_blk = 1'b1;                          // 起填那拍就污染
        run_fill;
        fill_blk = 1'b0;
        idle(2);
        accept(32'h0000_0020, 2'd2, 4'd12);
        expect_ms(32'h0000_0020, 4'd12);          // 被污染 ⇒ 还是缺失
        run_fill;
        idle(2);
        accept(32'h0000_0020, 2'd2, 4'd13);       // 干净了 ⇒ 这次装得上
        expect_hit(32'h0000_0020, 4'd13, 32'hC0DE_0008);

        // ============ T7 填充途中才出现污染 ⇒ 同样作废 ============
        $display("=== T7 填充途中才出现污染 ⇒ 同样作废");
        accept(32'h0000_0060, 2'd2, 4'd1);        // set 3
        expect_ms(32'h0000_0060, 4'd1);
        idle(2);
        fill_blk = 1'b1;                          // 填到一半才出现
        idle(3);
        fill_blk = 1'b0;
        idle(16);
        accept(32'h0000_0060, 2'd2, 4'd2);        // 必须缺失
        expect_ms(32'h0000_0060, 4'd2);
        run_fill;
        idle(2);

        // ============ T8 填充在飞 ⇒ 同行 store 不判旁路 (停一拍), 落地后吸收 ============
        // ★ 这是 rsort 异常命中率的病根所在, 两条必须同时成立:
        //   (a) DUT 侧 —— 同行填充在飞时**既不吸收也不旁路** (判旁路就该条目留在 SQ 里毒死这次填充);
        //   (b) 上层侧 —— mem_subsystem 的污染判定豁免"将被吸收"的条目 (本 TB 不覆盖, 见 tb_mem_axi T18)。
        //   本 TB 的 fill_blk 恒 0 (不毒), 只查 (a)。
        $display("=== T8 填充在飞: 同行 store 不判旁路, 落地后吸收");
        accept(32'h0000_0080, 2'd2, 4'd3);        // set 4
        expect_ms(32'h0000_0080, 4'd3);
        g8 = 0;
        while (!fill_busy && g8 < 40) begin @(negedge clk); g8 = g8 + 1; end
        @(negedge clk);
        st_addr = 32'h0000_0084; st_data = 32'h5A5A_1234; st_width = 2'd2; st_valid = 1'b1;
        g8 = 0;
        while (fill_busy && g8 < 400) begin        // 整个填充窗口: 不许有任何回答
            #1;
            if (st_absorb || st_bypass) begin
                $display("FAIL: T8 填充在飞却给了 store 回答 (absorb=%b bypass=%b t=%0t)",
                         st_absorb, st_bypass, $time);
                errors = errors + 1;
            end
            @(negedge clk);
            g8 = g8 + 1;
        end
        g8 = 0; #1;
        while (!st_absorb && g8 < 40) begin @(negedge clk); #1; g8 = g8 + 1; end
        if (!st_absorb) begin                      // 行已 valid ⇒ 必须吸收, 不许旁路
            $display("FAIL: T8 填充落地后仍不给吸收 (bypass=%b t=%0t)", st_bypass, $time);
            errors = errors + 1;
        end
        @(posedge clk);                            // DUT 在这一拍落盘
        @(negedge clk); st_valid = 1'b0; idle(1);
        accept(32'h0000_0084, 2'd2, 4'd4);
        expect_hit(32'h0000_0084, 4'd4, 32'h5A5A_1234);   // 吸收真的写进了行
        idle(1);

        // ============ T8b 停一拍只限同行: 填充在飞时**不同行**的 store 照旧能定去向 ============
        // (不要求当拍: 安装写占着 SRAM 口时命中也要让路; 要求的是**不整条填充地被串行化**。)
        $display("=== T8b 填充在飞: 不同行 store 不停");
        accept(32'h0000_00C0, 2'd2, 4'd5);        // set 6, 未填过 ⇒ 缺失起填
        expect_ms(32'h0000_00C0, 4'd5);
        g8 = 0;
        while (!fill_busy && g8 < 40) begin @(negedge clk); g8 = g8 + 1; end
        @(negedge clk);
        st_addr = 32'h0000_0088; st_data = 32'h0BAD_F00D; st_width = 2'd2; st_valid = 1'b1;
        g8 = 0; #1;
        while (!(st_absorb || st_bypass) && fill_busy && g8 < 40) begin
            @(negedge clk); #1; g8 = g8 + 1;
        end
        if (!(st_absorb || st_bypass)) begin
            $display("FAIL: T8b 不同行 store 在填充期间拿不到回答 (t=%0t)", $time);
            errors = errors + 1;
        end
        chk(fill_busy, "T8b 回答时填充应仍在飞 (不许整条填充地串行化)");
        @(posedge clk);
        @(negedge clk); st_valid = 1'b0; idle(1);
        run_fill;
        idle(2);
        accept(32'h0000_0088, 2'd2, 4'd6);
        expect_hit(32'h0000_0088, 4'd6, 32'h0BAD_F00D);   // 上面那次吸收真的落了盘
        idle(1);
        accept(32'h0000_0080, 2'd2, 4'd7);        // T8 装上的行仍在
        expect_hit(32'h0000_0080, 4'd7, 32'hC0DE_0020);

        // ============ T9 park (ms 推不出去) 后: 地址不得丢失 + **恰好交付一次** ============
        // ★ 断言口径随 M2 改写, 是**加强不是放宽**: 旧版的 expect_ms 抓的其实是"填充跑完 →
        //   重放 → 因 lk_miss_r 压住 hit_raw_w 而假重缺失 → 再推一次 ms"这一次**多余推送**
        //   (逐拍对质过: pre-M2 t=3970000 那一拍 ms_fire_w=1 就是它) —— 那是副产品, 不是契约。
        //   真契约只有一条: 被接受的 load **恰好交付一次**且数据正确。地址也早就有主 ——
        //   park 本身就是"ms 满了, 改由单槽填充队列接住自己起填"。
        $display("=== T9 park (ms 推不出去) 后地址不得丢失, 恰好交付一次");
        cap_n  = n_accept;
        done_n = n_done;
        ms_ready = 1'b0;
        idle(1);
        accept(32'h0000_00A4, 2'd2, 4'd7);
        idle(3);
        chk(busy, "T9 park 期间 busy 应为 1");
        // 地址必须有着落: 要么还在查表寄存器里, 要么已被单槽填充队列接住起了填
        chk(dut.lk_v_r || dut.pf_v_r || dut.fill_busy_r, "T9 park 的地址两边都不在 (丢了)");
        ms_ready = 1'b1;
        run_fill;
        idle(4);
        chk(n_accept - cap_n == 1, "T9 恰好接受一次");
        chk(n_done - done_n == 1, "T9 恰好交付一次 (不多不少)");
        accept(32'h0000_00A4, 2'd2, 4'd8);
        expect_hit(32'h0000_00A4, 4'd8, 32'hC0DE_0029);

        // ============ T10 命中撞回包 ⇒ **重放**, 不许降级为缺失 (写回要害) ============
        $display("=== T10 命中撞回包 ⇒ 重放 (不判缺失, 不丢交付)");
        cap_n  = n_accept;
        done_n = n_done;
        ms_n   = n_ms;
        accept(32'h0000_0024, 2'd2, 4'd9);        // set 1, 已填好 ⇒ 会命中
        rsp_ovr = 1'b1;                            // accept 返回即命中判定那一拍, 当场注入回包
        @(negedge clk);
        rsp_ovr = 1'b0;
        idle(1);
        chk(n_ms == ms_n, "T10 降级成缺失了 (写回下这等于读陈旧内存)");
        wait_done(200, "T10 重放后没有交付");
        idle(4);
        chk(n_accept - cap_n == 1, "T10 exactly one load accepted");
        chk(n_done - done_n == 1, "T10 exactly one delivery (hit suppressed, replay delivers)");

        // ============ T11 背靠背访问不丢交付、不错配 idx ============
        $display("=== T11 背靠背访问不丢交付、不错配 idx");
        fill_line(32'h0000_0100);                 // set 8
        idle(1);
        accept(32'h0000_0100, 2'd2, 4'd10); expect_hit(32'h0000_0100, 4'd10, 32'hC0DE_0040);
        accept(32'h0000_0104, 2'd2, 4'd11); expect_hit(32'h0000_0104, 4'd11, 32'hC0DE_0041);
        accept(32'h0000_0108, 2'd2, 4'd12); expect_hit(32'h0000_0108, 4'd12, 32'hC0DE_0042);
        accept(32'h0000_010C, 2'd2, 4'd13); expect_hit(32'h0000_010C, 4'd13, 32'hC0DE_0043);
        idle(2);

        // ============ T12 store 就地更新偷走 load 的读 ⇒ 重放 (不判缺失、不丢交付) ============
        // 写有绝对优先权 ⇒ 抬住 st_valid 的每一拍 SRAM 写口都被占, load 的读必被偷。
        // 判据: 不产生 ms 推送 (n_ms 不变), 不丢交付脉冲 (账本仍平), 且重放后读到的是新值。
        $display("=== T12 store 写偷读 ⇒ 重放");
        cap_n = n_accept; done_n = n_done; ms_n = n_ms; gate_n = n_steal;
        @(negedge clk);
        st_valid = 1'b1; st_addr = 32'h0000_0104; st_data = 32'h5A5A_A5A5; st_width = 2'd2;
        accept(32'h0000_0104, 2'd2, 4'd7);        // 这条 load 的读必被 store 写偷走
        idle(3);
        chk(n_steal > gate_n, "T12 偷读路径没被走到 (store 写没抢到 SRAM 口?)");
        chk(n_ms == ms_n, "T12 偷读被误判成缺失 (应重放)");
        @(negedge clk); st_valid = 1'b0;
        expect_hit(32'h0000_0104, 4'd7, 32'h5A5A_A5A5);   // 重放后读到 store 写进去的新值
        idle(2);
        chk(n_accept - cap_n == 1, "T12 恰好接受一条 load");
        chk(n_done - done_n == 1, "T12 恰好一个交付脉冲");

        // ============ T13 安装写占口时 store 让路 (不抢 SRAM 口), 填充收尾后仍给回答 ============
        $display("=== T13 安装写期间 store 必须让路");
        gate_n = n_gate;
        accept(32'h0000_0140, 2'd2, 4'd8);        // set 10, 未填过 ⇒ 缺失起填
        expect_ms(32'h0000_0140, 4'd8);
        @(negedge clk);
        st_addr = 32'h0000_0108; st_data = 32'h0BAD_F00D; st_width = 2'd2; st_valid = 1'b1;
        idle(2);
        chk(st_absorb, "T13 填充未占口的拍必须给出 st_absorb");
        // 抬住不放, 覆盖整个填充写窗口 ⇒ 期间 store 让路 (常驻断言同时在查"绝不同拍")
        while (fill_busy) @(negedge clk);
        #1;
        chk(n_gate > gate_n, "T13 让路路径没被走到 (填充没占上 SRAM 口?)");
        chk(st_absorb, "T13 填充收尾后应恢复给回答");
        @(posedge clk); @(negedge clk);
        st_valid = 1'b0;
        idle(2);
        accept(32'h0000_0108, 2'd2, 4'd9);
        expect_hit(32'h0000_0108, 4'd9, 32'h0BAD_F00D);

        // ============ T14 脏行被驱逐 ⇒ 捕获读 + 整行写回 + 逐笔 B ============
        // 布局 (每次都用**没碰过的组**, 免得替换指针被前面的用例带偏):
        //   先填 A 占 way0, 再填 B 占 way1; 把 A 写脏, 然后**敲一下 B** ——
        //   LRU 下这拍才让 A 确定成为受害者 (上面两次命中 A 已把 A 顶成 MRU,
        //   不敲 B 的话受害者会合法地变成 B, 写回地址就不是 A 了)。
        $display("=== T14 脏行驱逐 ⇒ 整行写回");
        fill_line(32'h0000_0300);                 // set 24, tag 0, way0
        fill_line(32'h0000_0700);                 // set 24, tag 1, way1
        accept(32'h0000_0300, 2'd2, 4'd1);
        expect_hit(32'h0000_0300, 4'd1, 32'hC0DE_00C0);
        store_ret(32'h0000_0300, 32'hDEAD_BEEF, 2'd2, K_ABSORB);   // A 变脏
        accept(32'h0000_0300, 2'd2, 4'd2);
        expect_hit(32'h0000_0300, 4'd2, 32'hDEAD_BEEF);
        accept(32'h0000_0700, 2'd2, 4'd13);       // 敲 B ⇒ B 是 MRU, A 是 LRU
        expect_hit(32'h0000_0700, 4'd13, 32'hC0DE_01C0);
        wb_n0 = wb_n;
        accept(32'h0000_0B00, 2'd2, 4'd3);        // 同组第三条 ⇒ 驱逐 A
        expect_ms(32'h0000_0B00, 4'd3);
        run_wb(wb_n0 + DC_LINE_WORDS);
        chk(wb_n - wb_n0 == DC_LINE_WORDS, "T14 写回笔数应为一整行");
        for (k = 0; k < DC_LINE_WORDS; k = k + 1)
            chk(wb_log_a[(wb_n0 + k) % 64] === (32'h0000_0300 + k * 4), "T14 写回地址应逐字递增");
        chk(wb_log_d[wb_n0 % 64] === 32'hDEAD_BEEF, "T14 写回数据必须带上被吸收的 store");
        chk(wb_log_d[(wb_n0 + 1) % 64] === 32'hC0DE_00C1, "T14 写回其余字应为行内原值");
        run_fill;
        idle(2);
        accept(32'h0000_0B00, 2'd2, 4'd4);
        expect_hit(32'h0000_0B00, 4'd4, 32'hC0DE_02C0);
        accept(32'h0000_0300, 2'd2, 4'd5);        // A 已被换出 ⇒ 必须缺失
        expect_ms(32'h0000_0300, 4'd5);
        run_fill;
        idle(2);
        accept(32'h0000_0300, 2'd2, 4'd6);
        expect_hit(32'h0000_0300, 4'd6, 32'hDEAD_BEEF);   // 读回的是**写回进内存**的值

        // ============ T15 写回在飞 ⇒ 同行的 store 旁路、同行的 load 等 (不发 AR) ============
        $display("=== T15 写回在飞 ⇒ 同行 store 旁路 / 同行 load 等");
        fill_line(32'h0000_0340);                  // set 26, way0
        fill_line(32'h0000_0740);                  // way1
        store_ret(32'h0000_0340, 32'h0BAD_0BAD, 2'd2, K_ABSORB);
        wb_ready = 1'b0;                           // 卡住写通道 ⇒ 写回一直"在飞"
        accept(32'h0000_0B40, 2'd2, 4'd6);         // 驱逐脏行
        expect_ms(32'h0000_0B40, 4'd6);
        idle(4);
        chk(wb_req_valid, "T15 写回应已开始排水");
        // (a) 同行 store: 行已没了 ⇒ 不能吸收; 但写回还没落盘 ⇒ 也不能旁路 (会被那 8 笔反超)
        st_addr = 32'h0000_0340; st_data = 32'h1234_1234; st_width = 2'd2; st_valid = 1'b1;
        @(negedge clk); #1;
        st_ans = 1'b0;
        for (k = 0; k < 6; k = k + 1) begin
            @(negedge clk); #1;
            if (st_absorb || st_bypass) st_ans = 1'b1;
        end
        chk(!st_ans, "T15 写回在飞时同行 store 必须等 (吸收/旁路都不许)");
        // (b) 同行 load: 不许发 AR —— 内存此刻还是旧值, 读回来就是静默算错
        ms_n = n_ms;
        accept(32'h0000_0340, 2'd2, 4'd7);
        idle(4);
        chk(n_ms == ms_n, "T15 写回在飞时不该对同行发 AR (会读回旧值)");
        // 放开写通道: 写回排完 ⇒ 被 park 的那条同行填充立刻起填
        wb_ready = 1'b1;
        run_wb(wb_n + DC_LINE_WORDS);
        // ms_valid 是 1 拍脉冲 ⇒ 必须**先**接住它再跑填充 (顺序反了就永远等不到)
        expect_ms(32'h0000_0340, 4'd7);            // 写回落地后才按缺失推送
        // ★ 此刻同行**有**填充在飞 ⇒ 那条 store 按 T8 的规则不判旁路, 等这次填充落地后吸收。
        //   (纯"写回落地 ⇒ 同行 store 旁路"那条路由 T15c 覆盖 —— 那里没有同行填充在飞。
        //    真实机器里两者不会同时出现: 未可见的 store 会挡住同行填充起填, 见 mem_subsystem 的
        //    sq_line_blk_f; 本单元 TB 不建 SQ, 故只能在两种情形里各测一条。)
        k = 0;
        while (!st_absorb && k < 100) begin @(negedge clk); #1; k = k + 1; end
        chk(st_absorb, "T15 写回落地 + 同行填充在飞 ⇒ 那条 store 应等填充并吸收");
        @(posedge clk); @(negedge clk); st_valid = 1'b0; idle(1);
        run_fill;
        idle(2);
        accept(32'h0000_0340, 2'd2, 4'd8);
        expect_hit(32'h0000_0340, 4'd8, 32'h1234_1234);   // 吸收进去的新值 (内存里是写回的老值)

        // ============ T15c 写回落地 ⇒ 同行 store 必须能旁路 (活性: 不许被永远卡住) ============
        $display("=== T15c 写回落地后同行 store 旁路 (无同行填充)");
        fill_line(32'h0000_0380);                  // set 28, way0
        fill_line(32'h0000_0780);                  // way1 (填满两路, 第三条才驱逐到脏的 way0)
        store_ret(32'h0000_0380, 32'h0BAD_0BAD, 2'd2, K_ABSORB);
        wb_ready = 1'b0;
        accept(32'h0000_0B80, 2'd2, 4'd9);         // 驱逐脏行 ⇒ 写回卡在通道上
        expect_ms(32'h0000_0B80, 4'd9);
        idle(4);
        st_addr = 32'h0000_0380; st_data = 32'h1234_1234; st_width = 2'd2; st_valid = 1'b1;
        @(negedge clk); #1;
        chk(!st_absorb && !st_bypass, "T15c 写回在飞时不该有回答");
        wb_ready = 1'b1;
        run_wb(wb_n + DC_LINE_WORDS);
        k = 0;
        while (!(st_absorb || st_bypass) && k < 100) begin @(negedge clk); #1; k = k + 1; end
        chk(st_bypass, "T15c 写回落地且无同行填充 ⇒ 同行 store 应旁路");
        @(posedge clk); @(negedge clk); st_valid = 1'b0; idle(1);
        run_fill;                                  // 0xB80 那次填充收尾
        idle(2);
        accept(32'h0000_0380, 2'd2, 4'd10);        // 已被换出且旁路 store 不入缓存 ⇒ 必须缺失
        expect_ms(32'h0000_0380, 4'd10);
        run_fill;
        idle(2);
        accept(32'h0000_0380, 2'd2, 4'd11);
        expect_hit(32'h0000_0380, 4'd11, 32'h0BAD_0BAD);   // 读回**写回进内存**的老值

        // ============ T15b 等写回的 load 遇上**另一行**的填充 ⇒ 跨行旁路必须被挡住 ============
        // ★ 这是 M2 第一版**真错过**的一处 (实测: perf_rsort 退出值 0→1), 独立成用例防回归。
        //   根因: lk_wait_r 有两条来路 (lk_wait_src_w = 等同行填充 | **等写回**), 等写回那条
        //   根本没有"在填的行就是我这一行"这回事; 判据若只比行内字偏移, 别的行的填充只要字偏移
        //   撞上, 就把**别人行的数据**交付出去 —— 又快又错。
        //   共存条件是现成的 (dcache.v:388): fill_blk_w 只在**受害行是脏的**时候才挡填充 ⇒ 写回
        //   在飞时, 若要驱逐的另一组是空的/干净的, 填充照起 ⇒ fill_busy_r=1 (B 行) 与
        //   lk_wb_wait_w=1 (A 行) 同拍 —— 两条来路第一次同时为真。T15/T15c 都构造不出这个交叠
        //   (它们只有写回那一条, 填的是同一行)。
        $display("=== T15b 等写回 + 另一行在填 ⇒ 跨行旁路必须被挡住");
        fill_line(32'h0000_03A0);                  // set 29 way0, tag 0
        fill_line(32'h0000_07A0);                  // way1, tag 1
        store_ret(32'h0000_03A0, 32'h1111_1111, 2'd2, K_ABSORB);   // 只脏 way0 ⇒ 受害行确定
        wb_ready = 1'b0;                           // 卡住写通道 ⇒ 写回一直"在飞"
        accept(32'h0000_0BA0, 2'd2, 4'd20);        // set 29 第三条 ⇒ 驱逐脏的 way0, 写回卡住
        expect_ms(32'h0000_0BA0, 4'd20);
        idle(4);
        chk(wb_req_valid, "T15b 写回应已开始排水");
        wb_a = {dut.wb_base_r[31:2], 2'b00};       // 受害行由替换策略定, 不写死
        // (b) 另一组起一次填充: set 30 两路全空 ⇒ 受害行无效 ⇒ 填充不被写回挡住。
        //     必须排在等写回的 load **之前** —— 等待者一点住查表寄存器, busy 就不再落 0 (M1 的靶子)。
        accept(32'h0000_03C0, 2'd2, 4'd21);
        // (a) 这条 load 的行正在写回 ⇒ 停在"等写回"上; 字偏移挑 4 = 填充回包的第 5 拍
        accept(wb_a + 32'd16, 2'd2, 4'd22);
        idle(2);
        chk(dut.lk_wait_r && dut.lk_wb_wait_w, "T15b wb-wait load must stay waiting");
        // ★ 本用例的三条 chk 消息写成 ASCII: Icarus 把多字节 UTF-8 字符串经
        //   [8*96-1:0] 端口传递时会毁掉字节序 (长度无关)。诊断信息必须可读。
        byp_n = n_byp;
        idle(30);                                  // 覆盖 B 行填充整条 (FILL_LAT + 8 拍 + 收尾)
        chk(n_byp == byp_n, "T15b CROSS-LINE bypass delivered! (wrong data)");
        chk(dut.lk_v_r && dut.lk_wait_r, "T15b wb-wait load was delivered early");
        // (c) 放开写通道 ⇒ 写回落地 ⇒ 该 load 按缺失重走, 读回**写回进内存**的那个字
        wb_ready = 1'b1;
        run_wb(wb_n + DC_LINE_WORDS);
        expect_ms(wb_a + 32'd16, 4'd22);           // 行内第 4 字: store 只碰过第 0 字
        idle(60);                                  // 0xBA0 与被驱逐行的两笔填充都落地
        accept(wb_a + 32'd16, 2'd2, 4'd23);
        expect_hit(wb_a + 32'd16, 4'd23, 32'hC0DE_0000 | (((wb_a + 32'd16) >> 2) & 32'hFFFF));

        // ============ T16 写回排水途中复位 ⇒ 干净重启 ============
        $display("=== T16 写回排水途中复位 ⇒ 干净重启");
        fill_line(32'h0000_0360);                  // set 27, way0
        fill_line(32'h0000_0760);                  // way1
        store_ret(32'h0000_0360, 32'h5555_AAAA, 2'd2, K_ABSORB);
        wb_ready = 1'b0;
        accept(32'h0000_0B60, 2'd2, 4'd9);         // 驱逐脏行 ⇒ 排水卡住
        expect_ms(32'h0000_0B60, 4'd9);
        idle(4);
        chk(wb_req_valid, "T16 写回应已开始排水");
        rst_n = 1'b0;
        idle(3);
        rst_n = 1'b1;
        wb_ready = 1'b1;
        idle(2);
        chk(!fill_busy && !hit_valid && !wb_req_valid, "T16 复位后 fill/hit/WB 应为空");
        fill_line(32'h0000_0180);                  // set 12
        accept(32'h0000_0180, 2'd2, 4'd15);
        expect_hit(32'h0000_0180, 4'd15, 32'hC0DE_0060);

        // ============ 收尾: 全局账本 ============
        idle(200);                                 // 排空所有在飞的 AR
        if (n_accept != n_done) begin
            $display("FAIL 账本: 接受 %0d 条, 完成 %0d 条", n_accept, n_done);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED  (accept=%0d done=%0d ms=%0d fill_req=%0d gate=%0d steal=%0d wb=%0d)",
                     n_accept, n_done, n_ms, n_fill_req, n_gate, n_steal, wb_n);
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
