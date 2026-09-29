// tb_icache: 段 1 小规模+极端 (冷启动首发必 miss / 填充后同址必 hit / 冲突替换 / 读写口冲突 /
//        跨行批各偏移 / backpressure 原地重试 / IC_BYPASS 重填期间不得假命中);
//        段 2 逐拍数据 oracle 下的各配置长跑
//
// 检查口径 = **交付契约本身**: imem_valid(T) ⇒ inst_data(T) 必须逐字等于地址 imem_addr(T−1) 上的批。
//   这条与 DUT 内部怎么实现无关, 是 fetch 接收批的唯一依据 ⇒ 用作主 oracle。
//   激励侧另有一个"类 fetch"的驱动器 (照抄 fetch.v 的 arr_ok/cap_w/pc_lead_w 三支), 以便产生
//   真实地址流 (命中超前/重定向/跨行装配), 但驱动错了只会改变激励, 不会动摇上面的 oracle。
`timescale 1ns/1ps
module tb_icache;
    localparam MEMW = 4096;         // 存储器字数 (16 KiB), 用 [13:2] 索引 ⇒ 地址须 < 0x4000
    localparam LAT1 = 10;           // 4 个读通道延迟各不相同 (官方真实值 10; 其余取小值加速)
    localparam LAT2 = 4;
    localparam LAT3 = 3;
    localparam LAT4 = 2;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    integer i, k, ci, pi, n0;
    integer errors = 0;
    integer cyc    = 0;
    integer nchk   = 0;             // 已校验的交付数
    reg [3 : 0] chk_en = 4'b0000;   // 分段使能: 0=u_w1 1=u_byp 2=u_w4 3=u_t2

    // ==================== 存储器 + 读通道 backpressure ====================
    reg [31 : 0] mem [0 : MEMW - 1];

    reg       bp_en  = 1'b0;        // 1 = 每 8 拍拉低 ready 3 拍 (模拟 load 抢读口)
    reg [2:0] bp_cnt = 3'd0;
    always @(posedge clk) bp_cnt <= bp_cnt + 3'd1;
    wire fr_ready = !(bp_en && (bp_cnt >= 3'd5));

    // ==================== 全部网表/状态声明 (Verilog-2005 须先声明后使用) ====================
    // DUT 端口
    wire [31 : 0]  w1_inst, by_inst;
    wire [63 : 0]  t2_inst;
    wire [127 : 0] w4_inst;
    wire w1_valid, w1_hit, w1_busy, w1_fv, by_valid, by_hit, by_busy, by_fv;
    wire w4_valid, w4_hit, w4_busy, w4_fv, t2_valid, t2_hit, t2_busy, t2_fv;
    wire [31 : 0] w1_fa, by_fa, w4_fa, t2_fa;
    wire [31 : 0] w1_rd, by_rd, w4_rd, t2_rd;
    wire          w1_rv, by_rv, w4_rv, t2_rv;

    // 激励状态
    reg  [31 : 0] w1_addr, w4_addr, t2_addr;   // 本拍驱动给 DUT 的批基址
    reg  [31 : 0] w1_tgt, by_tgt, w4_tgt, t2_tgt;
    reg           w1_ld, by_ld, w4_ld, t2_ld;
    reg  [31 : 0] w1_exp, w1_pd, w4_exp, w4_pd, t2_exp, t2_pd, by_addr, by_pd;
    wire [127 : 0] w4_batch;
    wire [63 : 0]  t2_batch;

    // 读通道模型
    reg [31 : 0] q1 [0 : LAT1 - 1];  reg v1 [0 : LAT1 - 1];
    reg [31 : 0] q2 [0 : LAT2 - 1];  reg v2 [0 : LAT2 - 1];
    reg [31 : 0] q3 [0 : LAT3 - 1];  reg v3 [0 : LAT3 - 1];
    reg [31 : 0] q4 [0 : LAT4 - 1];  reg v4 [0 : LAT4 - 1];

    // ==================== 批地址展开 (照抄 fetch.v 的 imem_addr[g] = pc + 4g) ====================
    genvar gw;
    generate
        for (gw = 0; gw < 2; gw = gw + 1) begin : a2
            assign t2_batch[gw * 32 +: 32] = t2_addr + 32'd4 * gw;
        end
        for (gw = 0; gw < 4; gw = gw + 1) begin : a4
            assign w4_batch[gw * 32 +: 32] = w4_addr + 32'd4 * gw;
        end
    endgenerate

    // ==================== 4 个 DUT ====================
    // u_w1 : 发行配置 (W=1, 1 KiB/8 字行, 预取开) —— 官方 student_top 的默认形态
    // u_byp: IC_BYPASS=1 —— 交付一次即失效, 专测"重填期间不得假命中"
    // u_w4 : W=4 行 8 字 —— 批占 16 字节, 行内偏移 4..7 跨行
    // u_t2 : W=2 行 2 字 —— W == IC_LINE_WORDS 的极端, 每批必跨两行
    icache #(.ISSUE_WIDTH(1), .IC_SIZE(1024), .IC_LINE_WORDS(8), .IC_BYPASS(0), .IC_PREFETCH(1)) u_w1 (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(w1_addr), .inst_data(w1_inst), .imem_valid(w1_valid), .imem_hit(w1_hit),
        .fill_req_valid(w1_fv), .fill_req_addr(w1_fa), .fill_req_ready(fr_ready),
        .fill_rsp_valid(w1_rv), .fill_rsp_data(w1_rd), .fill_busy(w1_busy)
    );
    icache #(.ISSUE_WIDTH(1), .IC_SIZE(1024), .IC_LINE_WORDS(8), .IC_BYPASS(1), .IC_PREFETCH(0)) u_byp (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(by_addr), .inst_data(by_inst), .imem_valid(by_valid), .imem_hit(by_hit),
        .fill_req_valid(by_fv), .fill_req_addr(by_fa), .fill_req_ready(fr_ready),
        .fill_rsp_valid(by_rv), .fill_rsp_data(by_rd), .fill_busy(by_busy)
    );
    icache #(.ISSUE_WIDTH(4), .IC_SIZE(1024), .IC_LINE_WORDS(8), .IC_BYPASS(0), .IC_PREFETCH(0)) u_w4 (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(w4_batch), .inst_data(w4_inst), .imem_valid(w4_valid), .imem_hit(w4_hit),
        .fill_req_valid(w4_fv), .fill_req_addr(w4_fa), .fill_req_ready(fr_ready),
        .fill_rsp_valid(w4_rv), .fill_rsp_data(w4_rd), .fill_busy(w4_busy)
    );
    icache #(.ISSUE_WIDTH(2), .IC_SIZE(128), .IC_LINE_WORDS(2), .IC_BYPASS(0), .IC_PREFETCH(0)) u_t2 (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(t2_batch), .inst_data(t2_inst), .imem_valid(t2_valid), .imem_hit(t2_hit),
        .fill_req_valid(t2_fv), .fill_req_addr(t2_fa), .fill_req_ready(fr_ready),
        .fill_rsp_valid(t2_rv), .fill_rsp_data(t2_rd), .fill_busy(t2_busy)
    );

    // ==================== 读通道模型 (固定延迟 + 同序 1:1 回包) ====================
    // 只接受握手成功那一拍的请求 (fill_req_valid && fr_ready) ⇒ DUT 必须把请求保持到 ready 为止。
    // 这正是"被 load 抢走就原地重试、不丢位置"要验的那条性质。
    wire w1_rq = w1_fv && fr_ready;
    wire by_rq = by_fv && fr_ready;
    wire w4_rq = w4_fv && fr_ready;
    wire t2_rq = t2_fv && fr_ready;
    assign w1_rd = q1[LAT1 - 1];  assign w1_rv = v1[LAT1 - 1];
    assign by_rd = q2[LAT2 - 1];  assign by_rv = v2[LAT2 - 1];
    assign w4_rd = q3[LAT3 - 1];  assign w4_rv = v3[LAT3 - 1];
    assign t2_rd = q4[LAT4 - 1];  assign t2_rv = v4[LAT4 - 1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) for (pi = 0; pi < LAT1; pi = pi + 1) v1[pi] <= 1'b0;
        else begin
            v1[0] <= w1_rq;  q1[0] <= mem[w1_fa[13 : 2]];
            for (pi = 1; pi < LAT1; pi = pi + 1) begin v1[pi] <= v1[pi - 1];  q1[pi] <= q1[pi - 1]; end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) for (pi = 0; pi < LAT2; pi = pi + 1) v2[pi] <= 1'b0;
        else begin
            v2[0] <= by_rq;  q2[0] <= mem[by_fa[13 : 2]];
            for (pi = 1; pi < LAT2; pi = pi + 1) begin v2[pi] <= v2[pi - 1];  q2[pi] <= q2[pi - 1]; end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) for (pi = 0; pi < LAT3; pi = pi + 1) v3[pi] <= 1'b0;
        else begin
            v3[0] <= w4_rq;  q3[0] <= mem[w4_fa[13 : 2]];
            for (pi = 1; pi < LAT3; pi = pi + 1) begin v3[pi] <= v3[pi - 1];  q3[pi] <= q3[pi - 1]; end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) for (pi = 0; pi < LAT4; pi = pi + 1) v4[pi] <= 1'b0;
        else begin
            v4[0] <= t2_rq;  q4[0] <= mem[t2_fa[13 : 2]];
            for (pi = 1; pi < LAT4; pi = pi + 1) begin v4[pi] <= v4[pi - 1];  q4[pi] <= q4[pi - 1]; end
        end
    end

    // ==================== 类 fetch 激励驱动器 ====================
    // exp_*: 下一条应交付的批基址;  *_addr: 本拍驱动给 DUT 的批基址
    //   arr_ok = (上一拍地址 == exp)         本拍到达的是期望批
    //   cap    = arr_ok && imem_valid        本拍接收 (exp 前进一个批)
    //   lead   = (地址 == exp) && imem_hit   请求可提前到下一批 (pc 超前一个批)
    // 这三支照抄 fetch.v:75/80/181, 只去掉 stall/halt/预测跳转 (本 TB 不做分支预测)。
    wire w1_arr = (w1_pd == w1_exp);
    wire w1_cap = w1_arr && w1_valid;
    wire w1_lea = (w1_addr == w1_exp) && w1_hit;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w1_exp <= 32'd0;  w1_addr <= 32'd0;  w1_pd <= 32'd0;
        end else begin
            w1_pd  <= w1_addr;
            w1_exp <= w1_ld ? w1_tgt : (w1_cap ? (w1_exp + 32'd4) : w1_exp);
            w1_addr <= w1_ld ? w1_tgt : (w1_cap ? (w1_addr + 32'd4)
                                       : w1_lea ? (w1_addr + 32'd4) : w1_exp);
        end
    end

    // BYPASS 实例用最简激励: 地址**保持到该地址被交付**为止再 +4。
    //   ⇒ 反复访问同一行, 每次都必然重填 ⇒ 正面撞击"旧条目 tag 仍匹配 + 半行已写入"的假命中陷阱。
    wire by_arr = (by_pd == by_addr);      // 本拍交付的确实是当前保持的地址 (跳转首拍不成立)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin by_addr <= 32'd0;  by_pd <= 32'd0; end
        else begin
            by_pd   <= by_addr;
            by_addr <= by_ld ? by_tgt : ((by_valid && by_arr) ? (by_addr + 32'd4) : by_addr);
        end
    end

    wire w4_arr = (w4_pd == w4_exp);
    wire w4_cap = w4_arr && w4_valid;
    wire w4_lea = (w4_addr == w4_exp) && w4_hit;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w4_exp <= 32'd0;  w4_addr <= 32'd0;  w4_pd <= 32'd0;
        end else begin
            w4_pd  <= w4_addr;
            w4_exp <= w4_ld ? w4_tgt : (w4_cap ? (w4_exp + 32'd16) : w4_exp);
            w4_addr <= w4_ld ? w4_tgt : (w4_cap ? (w4_addr + 32'd16)
                                        : w4_lea ? (w4_addr + 32'd16) : w4_exp);
        end
    end

    wire t2_arr = (t2_pd == t2_exp);
    wire t2_cap = t2_arr && t2_valid;
    wire t2_lea = (t2_addr == t2_exp) && t2_hit;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t2_exp <= 32'd0;  t2_addr <= 32'd0;  t2_pd <= 32'd0;
        end else begin
            t2_pd  <= t2_addr;
            t2_exp <= t2_ld ? t2_tgt : (t2_cap ? (t2_exp + 32'd8) : t2_exp);
            t2_addr <= t2_ld ? t2_tgt : (t2_cap ? (t2_addr + 32'd8)
                                        : t2_lea ? (t2_addr + 32'd8) : t2_exp);
        end
    end

    // ==================== 逐拍检查 ====================
    // ★ why 一律用 ASCII: iverilog 把 %s 实参里的非 ASCII 字节打坏 (格式串里的中文没事),
    //   故中文说明写在各调用点旁边的注释里, 打印串保持 ASCII。
    task bad; input [8 * 16 - 1 : 0] tag; input [8 * 64 - 1 : 0] why; begin
        errors = errors + 1;
        if (errors <= 24) $display("FAIL cyc=%0d [%0s] %0s", cyc, tag, why);
    end endtask

    // 白盒不变量 (直指文件头记的陷阱; 数据 oracle 抓不到它们时这两条兜底)
    task chk_core;
        input                  v, rdok, fbsy;
        input [4 : 0]          fline, qline;
        input [8 * 16 - 1 : 0] tag;
        begin
            if (v && !rdok) bad(tag, "delivery from a write-stolen read (rd_ok_r=0)");
            if (v && fbsy && (qline == fline)) bad(tag, "delivery from the line being filled (half line)");
        end
    endtask

    task chk1; input [31 : 0] pa; begin
        if (w1_valid) begin
            nchk = nchk + 1;
            if (w1_inst !== mem[pa[13 : 2]]) bad("w1", "batch data != memory");
            if (^w1_inst === 1'bx)           bad("w1", "delivery data contains X");
            chk_core(w1_valid, u_w1.rd_ok_r, u_w1.fill_busy_r, u_w1.fill_line_r, u_w1.q_line_w, "w1");
        end
    end endtask

    task chkb; input [31 : 0] pa; begin
        if (by_valid) begin
            nchk = nchk + 1;
            if (by_inst !== mem[pa[13 : 2]]) bad("byp", "batch data != memory");
            chk_core(by_valid, u_byp.rd_ok_r, u_byp.fill_busy_r, u_byp.fill_line_r, u_byp.q_line_w, "byp");
        end
    end endtask

    task chk4; input [31 : 0] pa; begin
        if (w4_valid) begin
            nchk = nchk + 1;
            for (ci = 0; ci < 4; ci = ci + 1)
                if (w4_inst[ci * 32 +: 32] !== mem[pa[13 : 2] + ci])
                    bad("w4", "straddle batch slot != memory");
            if (^w4_inst === 1'bx) bad("w4", "delivery data contains X");
            chk_core(w4_valid, u_w4.rd_ok_r, u_w4.fill_busy_r, u_w4.fill_line_r, u_w4.q_line_w, "w4");
        end
    end endtask

    task chk2; input [31 : 0] pa; begin
        if (t2_valid) begin
            nchk = nchk + 1;
            for (ci = 0; ci < 2; ci = ci + 1)
                if (t2_inst[ci * 32 +: 32] !== mem[pa[13 : 2] + ci])
                    bad("t2", "always-straddle batch slot != memory");
            chk_core(t2_valid, u_t2.rd_ok_r, u_t2.fill_busy_r, u_t2.fill_line_r, u_t2.q_line_w, "t2");
        end
    end endtask

    // 填充期间该行的 valid 位必须为 0 (发起即清, 最后一字落地才置) —— 假命中的直接判据
    task chk_fill; input fbsy; input vline; input [8 * 16 - 1 : 0] tag; begin
        if (fbsy && vline) bad(tag, "line valid still 1 while fill in progress");
    end endtask

    task tick; begin
        @(posedge clk);
        #1;
        cyc = cyc + 1;
        if (chk_en[0]) begin
            chk1(w1_pd);
            chk_fill(u_w1.fill_busy_r, u_w1.valid_r[u_w1.fill_line_r], "w1");
        end
        if (chk_en[1]) chkb(by_pd);
        if (chk_en[2]) begin
            chk4(w4_pd);
            chk_fill(u_w4.fill_busy_r, u_w4.valid_r[u_w4.fill_line_r], "w4");
        end
        if (chk_en[3]) begin
            chk2(t2_pd);
            chk_fill(u_t2.fill_busy_r, u_t2.valid_r[u_t2.fill_line_r], "t2");
        end
    end endtask

    task run; input integer n; integer j; begin
        for (j = 0; j < n; j = j + 1) tick();
    end endtask

    task jmp1; input [31 : 0] a; begin w1_tgt = a; w1_ld = 1'b1; tick(); w1_ld = 1'b0; end endtask
    task jmpb; input [31 : 0] a; begin by_tgt = a; by_ld = 1'b1; tick(); by_ld = 1'b0; end endtask
    task jmp4; input [31 : 0] a; begin w4_tgt = a; w4_ld = 1'b1; tick(); w4_ld = 1'b0; end endtask
    task jmp2; input [31 : 0] a; begin t2_tgt = a; t2_ld = 1'b1; tick(); t2_ld = 1'b0; end endtask

    // 段内交付数下限: 只用来抓死锁/活锁 (真值取决于填充代价, 见各段注释), 不做性能判据
    task rep; input [8 * 16 - 1 : 0] tag; input integer lo; begin
        $display("     %0s 段内交付 %0d 次 (下限 %0d)", tag, nchk - n0, lo);
        if (nchk - n0 < lo) bad(tag, "delivery count below floor (deadlock/livelock?)");
    end endtask

    // ==================== 主流程 ====================
    initial begin
        $dumpfile("sim/core/tb_icache.vcd");
        $dumpvars(0, tb_icache.u_w1);
        $dumpvars(0, tb_icache.u_byp);
        $dumpvars(0, tb_icache.u_w4);
        $dumpvars(0, tb_icache.u_t2);

        for (i = 0; i < MEMW; i = i + 1)
            mem[i] = ((i << 16) ^ i ^ 32'h9E37_79B9);   // 高半字即下标 ⇒ 任意两字互不相同

        w1_ld = 0;  by_ld = 0;  w4_ld = 0;  t2_ld = 0;
        w1_tgt = 0; by_tgt = 0; w4_tgt = 0; t2_tgt = 0;
        rst_n = 1'b0;
        repeat (5) tick();                              // 复位保持 5 拍 (官方要求)
        rst_n = 1'b1;

        // ---- 段 1: u_w1 冷启动 / 顺序流 / 冲突替换 / 读写口冲突 ----
        $display("---- 段 1  u_w1 冷启动 + 顺序流 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        chk_en = 4'b0001;
        if (w1_hit) bad("w1", "imem_hit=1 right after reset (cold cache)");
        jmp1(32'h0000_1000);
        n0 = nchk;
        run(600);
        rep("w1", 100);       // 每 8 字行 = 一次 ~18 拍填充 + 8 拍交付 ⇒ 约 160 次
        if (!w1_hit) bad("w1", "imem_hit should be 1 at end of stream");

        // 冲突替换: 0x1000 与 0x1400 同属 32 行直接映射的同一行号 (相距 1 KiB) ⇒ 每次互踢。
        // 这条同时是"假命中自纠"的正面用例: 位图说 valid 而 tag 已换 ⇒ 交付失败 ⇒ 当场重填。
        $display("---- 段 1b u_w1 冲突替换 (同一行号不同 tag 反复互踢) (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        for (k = 0; k < 8; k = k + 1) begin
            jmp1(32'h0000_1000);  n0 = nchk;  run(40);  rep("w1", 2);
            jmp1(32'h0000_1400);  n0 = nchk;  run(40);  rep("w1", 2);
        end

        // 人为 backpressure: 每 8 拍有 3 拍 ready=0 ⇒ 填充器必须原地重试而非丢位置。
        // 同时填充写会偷走读口 ⇒ 制造大量"读写口冲突"拍 (rd_ok_r=0 由 chk_core 盯住)。
        $display("---- 段 1c u_w1 填充期间被人造 backpressure 反复抢占 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        bp_en = 1'b1;
        jmp1(32'h0000_2000);
        n0 = nchk;
        run(600);
        rep("w1", 60);
        bp_en = 1'b0;

        // ---- 段 2: u_byp 交付一次即失效 ⇒ 每次访问都重填 ----
        $display("---- 段 2  u_byp (IC_BYPASS=1) 反复重填同一行, 期间不得假命中 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        chk_en = 4'b0010;
        jmpb(32'h0000_0800);
        n0 = nchk;
        run(1600);
        rep("byp", 40);       // 每次访问都要 (4 拍回包 + 8 拍填充) ⇒ 约 80 次
        if (by_hit) bad("byp", "imem_hit must stay 0 in bypass mode");

        // ---- 段 3: u_w4 (W=4, 行 8 字) 跨行批 ----
        $display("---- 段 3  u_w4 顺序流 (批 16 字节, 行内偏移 4..7 跨行) (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        chk_en = 4'b0100;
        jmp4(32'h0000_3000);
        n0 = nchk;
        run(600);
        rep("w4", 40);        // 每 32 字行 = 2 个批, 填充 3+8 拍 ⇒ 约 90 次

        $display("---- 段 3b u_w4 批起点取遍行内全部偏移 (0..7), 含 4 个跨行点 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        for (k = 0; k < 8; k = k + 1) begin
            jmp4(32'h0000_3000 + 4 * k);  n0 = nchk;  run(30);  rep("w4", 1);
            jmp4(32'h0000_3100 + 4 * k);  n0 = nchk;  run(30);  rep("w4", 1);
        end

        $display("---- 段 3c u_w4 冲突替换 (相距 1 KiB 的同一行号互踢) (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        for (k = 0; k < 8; k = k + 1) begin
            jmp4(32'h0000_3000);  n0 = nchk;  run(40);  rep("w4", 2);
            jmp4(32'h0000_3400);  n0 = nchk;  run(40);  rep("w4", 2);
        end

        // ---- 段 4: u_t2 (W=2, 行 2 字) 每批必跨两行 ----
        $display("---- 段 4  u_t2 (W == IC_LINE_WORDS) 每批必跨两行 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        chk_en = 4'b1000;
        jmp2(32'h0000_0000);
        n0 = nchk;
        run(600);
        rep("t2", 20);        // 每批必跨两行 ⇒ 每次都要填两行, 下限放低

        $display("---- 段 4b u_t2 遍历 17 个行号 (16 行 + 回绕) 每次都是冲突缺失 (cyc=%0d, 累计校验 %0d 次交付)", cyc, nchk);
        bp_en = 1'b1;
        for (k = 0; k < 3; k = k + 1)
            for (i = 0; i <= 16; i = i + 1) begin
                jmp2(32'h0000_0000 + 8 * i);  n0 = nchk;  run(20);  rep("t2", 1);
            end
        bp_en = 1'b0;
        chk_en = 4'b0000;

        // ---- 收尾 ----
        $display("---- 共 %0d 拍, 逐拍校验 %0d 次交付", cyc, nchk);
        if (errors == 0) begin
            $display("ALL TESTS PASSED");
            $finish;
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
    end
endmodule
