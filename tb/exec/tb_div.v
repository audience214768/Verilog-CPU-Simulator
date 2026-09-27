// tb_div: 段 1 小规模+极端 (除零/溢出/四象限符号/边界/33 拍延迟/握手 H1-H4), 段 2 随机对照
//   延迟契约: start_valid 被采样那拍起算, 第 33 拍 done_valid 抬起 (单拍脉冲)
//   握手契约: busy 期间 start_valid 被忽略; kill 只杀在飞的那发, 且空闲时不吞同拍的新 start
//   参考模型: 无符号用 / %; 有符号用 $signed 的 / % (向零取整, 余数随被除数 ⇒ 与 RISC-V 一致),
//             除零与 INT_MIN/-1 两个角例单独分支 (仿真器在这两处与 ISA 语义不同)
`timescale 1ns/1ps
module tb_div;
    localparam PRF = 64;
    localparam ROB = 32;
    localparam PW  = 6;
    localparam RW  = 5;

    parameter  RAND_N = 200;               // 随机组数 (4 种 op 轮转 ⇒ 每种 50 组)

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    reg               start_valid;
    reg  [1 : 0]      start_op;
    reg  [31 : 0]     start_a, start_b;
    reg  [PW - 1 : 0] start_prd;
    reg  [RW - 1 : 0] start_rob_tag;
    reg               kill;
    wire              busy, done_valid;
    wire [PW - 1 : 0] done_prd;
    wire [RW - 1 : 0] done_rob_tag;
    wire [31 : 0]     done_result;

    integer errors = 0;
    integer lat;                           // 上一次 await_done 量到的延迟 (拍)
    integer i;

    div #(.PRF_SIZE(PRF), .ROB_SIZE(ROB)) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_op(start_op),
        .start_a(start_a), .start_b(start_b),
        .start_prd(start_prd), .start_rob_tag(start_rob_tag),
        .kill(kill),
        .busy(busy), .done_valid(done_valid), .done_prd(done_prd),
        .done_rob_tag(done_rob_tag), .done_result(done_result)
    );

    task do_reset;
        begin
            rst_n = 1'b0;
            start_valid = 1'b0;  kill = 1'b0;
            start_op = 2'd0;     start_a = 32'd0;  start_b = 32'd0;
            start_prd = {PW{1'b0}};  start_rob_tag = {RW{1'b0}};
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // 发起一笔: 在 negedge 摆好, 下一 posedge 被采样
    task issue;
        input [1 : 0]      eop;
        input [31 : 0]     ea, eb;
        input [PW - 1 : 0] ep;
        input [RW - 1 : 0] et;
        begin
            @(negedge clk);
            start_valid = 1'b1;  start_op = eop;
            start_a = ea;        start_b = eb;
            start_prd = ep;      start_rob_tag = et;
            @(negedge clk);                    // 采样沿已过
            start_valid = 1'b0;
        end
    endtask

    // 等到 done_valid 抬起, lat = 采样沿 ⇒ done 拍的拍数 (契约值 33)
    // 带看门狗: 死锁 (如 kill 误吞 start) 必须当场报失败, 不能挂住 make
    task await_done;
        begin
            lat = 1;
            while (!done_valid && (lat < 200)) begin
                @(negedge clk);
                lat = lat + 1;
            end
            if (!done_valid) begin
                $display("FAIL: 等待 done_valid 超时 200 拍 —— 死锁或 start 被吞");
                errors = errors + 1;
                $display("%0d TESTS FAILED", errors);
                $stop;
            end
        end
    endtask

    // 一次完整事务: 结果 + 延迟 + 脉冲宽度 + 完成后回到空闲
    task check;
        input [1 : 0]  eop;
        input [31 : 0] ea, eb;
        input [31 : 0] expect;
        begin
            issue(eop, ea, eb, 6'd7, 5'd3);
            await_done;
            if (done_result !== expect) begin
                $display("FAIL: op=%0d a=%h b=%h r=%h expect=%h", eop, ea, eb, done_result, expect);
                errors = errors + 1;
            end
            if (lat !== 33) begin
                $display("FAIL: 延迟 %0d 拍 (期望 33), op=%0d a=%h b=%h", lat, eop, ea, eb);
                errors = errors + 1;
            end
            @(negedge clk);
            if (done_valid || busy) begin                   // done_valid 必须是单拍脉冲
                $display("FAIL: done_valid/busy 未及时落 (done=%b busy=%b)", done_valid, busy);
                errors = errors + 1;
            end
        end
    endtask

    // RISC-V RV32M 参考模型 (与 DUT 算法无关)
    function [31 : 0] ref_model;
        input [1 : 0]       eop;
        input [31 : 0]      ea, eb;
        reg signed [31 : 0] sa, sb;
        begin
            sa = ea;  sb = eb;
            if (eop[0]) begin                                   // divu / remu
                ref_model = (eb == 32'd0) ? (eop[1] ? ea : 32'hFFFF_FFFF)
                                          : (eop[1] ? (ea % eb) : (ea / eb));
            end else if (eb == 32'd0) begin                     // 有符号除零
                ref_model = eop[1] ? ea : 32'hFFFF_FFFF;
            end else if ((ea == 32'h8000_0000) && (eb == 32'hFFFF_FFFF)) begin
                ref_model = eop[1] ? 32'd0 : 32'h8000_0000;     // 唯一溢出角例
            end else begin
                ref_model = eop[1] ? (sa % sb) : (sa / sb);
            end
        end
    endfunction

    initial begin
        $dumpfile("sim/exec/tb_div.vcd");
        $dumpvars(0, tb_div);

        do_reset;

        // ---- 段 1: 小规模 + 极端 ----
        // 四象限 (±20 ÷ ±6): 截断除法 ⇒ 商向零取整, 余数符号随被除数
        check(2'd0, 32'h0000_0014, 32'h0000_0006, 32'h0000_0003);
        check(2'd0, 32'hFFFF_FFEC, 32'h0000_0006, 32'hFFFF_FFFD);
        check(2'd0, 32'h0000_0014, 32'hFFFF_FFFA, 32'hFFFF_FFFD);
        check(2'd0, 32'hFFFF_FFEC, 32'hFFFF_FFFA, 32'h0000_0003);
        check(2'd2, 32'h0000_0014, 32'h0000_0006, 32'h0000_0002);
        check(2'd2, 32'hFFFF_FFEC, 32'h0000_0006, 32'hFFFF_FFFE);
        check(2'd2, 32'h0000_0014, 32'hFFFF_FFFA, 32'h0000_0002);
        check(2'd2, 32'hFFFF_FFEC, 32'hFFFF_FFFA, 32'hFFFF_FFFE);
        // 溢出: RISC-V 规定回绕不陷阱
        check(2'd0, 32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000);
        check(2'd2, 32'h8000_0000, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd0, 32'h7FFF_FFFF, 32'hFFFF_FFFF, 32'h8000_0001);
        // 除零: 商全 1, 余 = 被除数 (有/无符号同)
        check(2'd0, 32'h0000_0014, 32'h0000_0000, 32'hFFFF_FFFF);
        check(2'd0, 32'hFFFF_FFEC, 32'h0000_0000, 32'hFFFF_FFFF);
        check(2'd0, 32'h8000_0000, 32'h0000_0000, 32'hFFFF_FFFF);
        check(2'd2, 32'h0000_0014, 32'h0000_0000, 32'h0000_0014);
        check(2'd2, 32'hFFFF_FFEC, 32'h0000_0000, 32'hFFFF_FFEC);
        check(2'd1, 32'hFFFF_FFFF, 32'h0000_0000, 32'hFFFF_FFFF);
        check(2'd3, 32'hFFFF_FFFF, 32'h0000_0000, 32'hFFFF_FFFF);
        // 边界: a<b / a==b / a==0 / b==1 / ±1 / 极值
        check(2'd0, 32'h0000_0003, 32'h0000_0005, 32'h0000_0000);
        check(2'd2, 32'h0000_0003, 32'h0000_0005, 32'h0000_0003);
        check(2'd0, 32'h1234_5678, 32'h1234_5678, 32'h0000_0001);
        check(2'd2, 32'h1234_5678, 32'h1234_5678, 32'h0000_0000);
        check(2'd0, 32'h0000_0000, 32'h0000_0007, 32'h0000_0000);
        check(2'd2, 32'h0000_0000, 32'h0000_0007, 32'h0000_0000);
        check(2'd0, 32'hDEAD_BEEF, 32'h0000_0001, 32'hDEAD_BEEF);
        check(2'd0, 32'hFFFF_FFFF, 32'h0000_0001, 32'hFFFF_FFFF);
        check(2'd0, 32'hFFFF_FFFF, 32'h0000_0002, 32'h0000_0000);
        check(2'd2, 32'hFFFF_FFFF, 32'h0000_0002, 32'hFFFF_FFFF);
        check(2'd0, 32'h8000_0000, 32'h0000_0001, 32'h8000_0000);
        check(2'd0, 32'h8000_0000, 32'h0000_0002, 32'hC000_0000);
        check(2'd0, 32'h8000_0000, 32'h0000_0003, 32'hD555_5556);
        check(2'd2, 32'h8000_0000, 32'h0000_0003, 32'hFFFF_FFFE);
        // 无符号: 商满 32 位 / 余数满 32 位 / 大除数 (余数逼近 |b|)
        check(2'd1, 32'hFFFF_FFFF, 32'h0000_0002, 32'h7FFF_FFFF);
        check(2'd3, 32'hFFFF_FFFF, 32'h0000_0002, 32'h0000_0001);
        check(2'd1, 32'h8000_0000, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd3, 32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000);
        check(2'd1, 32'h8000_0000, 32'h8000_0000, 32'h0000_0001);
        check(2'd1, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0001);
        check(2'd1, 32'hFFFF_FFFF, 32'h0000_0001, 32'hFFFF_FFFF);
        check(2'd3, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd1, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd3, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0001);
        check(2'd1, 32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd3, 32'hFFFF_FFFE, 32'hFFFF_FFFF, 32'hFFFF_FFFE);
        check(2'd1, 32'hFFFF_FFFE, 32'hFFFF_FFFF, 32'h0000_0000);
        check(2'd1, 32'hFFFF_FFFF, 32'h8000_0001, 32'h0000_0001);
        check(2'd3, 32'hFFFF_FFFF, 32'h8000_0001, 32'h7FFF_FFFE);
        $display("SMALL+EDGE TESTS PASSED");

        // ---- H1: busy 期间拉起的 start_valid 必须被忽略 ----
        begin
            issue(2'd0, 32'd100, 32'd7, 6'd11, 5'd5);       // 100/7 = 14, prd=11, tag=5
            @(negedge clk);                                  // busy 已抬起
            start_valid = 1'b1;  start_op = 2'd3;            // 灌一发不同的请求
            start_a = 32'hDEAD_BEEF;  start_b = 32'd1;
            start_prd = 6'd12;       start_rob_tag = 5'd6;
            @(negedge clk);
            start_valid = 1'b0;
            await_done;
            if (done_result !== 32'd14 || done_prd !== 6'd11 || done_rob_tag !== 5'd5) begin
                $display("FAIL: H1 busy 期 start_valid 未被忽略 (r=%h prd=%0d tag=%0d)",
                         done_result, done_prd, done_rob_tag);
                errors = errors + 1;
            end
            if (busy) begin
                $display("FAIL: H1 完成后 busy 未落");
                errors = errors + 1;
            end
        end

        // ---- H2: kill 杀在飞的那发, 且此后不得再出 done_valid ----
        begin : h2
            integer k;
            issue(2'd0, 32'h1234_5678, 32'd3, 6'd1, 5'd1);
            repeat (5) @(negedge clk);
            kill = 1'b1;
            @(negedge clk);
            kill = 1'b0;
            if (busy || done_valid) begin
                $display("FAIL: H2 kill 当拍未清 busy (busy=%b done=%b)", busy, done_valid);
                errors = errors + 1;
            end
            for (k = 0; k < 40; k = k + 1) begin
                @(negedge clk);
                if (done_valid) begin
                    $display("FAIL: H2 kill 后第 %0d 拍仍出 done_valid", k);
                    errors = errors + 1;
                    k = 40;
                end
            end
            $display("PASS: H2 kill 抑制输出");
        end

        // ---- H3: 空闲时 kill 与 start 同拍 ⇒ 必须收下 (否则上层已清 RS 条目 = 死锁) ----
        begin
            @(negedge clk);
            start_valid = 1'b1;  start_op = 2'd1;
            start_a = 32'hFFFF_FFFF;  start_b = 32'd2;
            start_prd = 6'd3;  start_rob_tag = 5'd2;
            kill = 1'b1;
            @(negedge clk);
            start_valid = 1'b0;  kill = 1'b0;
            await_done;
            if (done_result !== 32'h7FFF_FFFF) begin
                $display("FAIL: H3 空闲时 kill 吞掉了同拍的新 start (r=%h)", done_result);
                errors = errors + 1;
            end
            $display("PASS: H3 空闲 kill 不吞 start");
        end

        // ---- H4: kill 恰落在最后一次迭代 ⇒ 优先级高于 done (不得漏出 done_valid) ----
        begin
            issue(2'd0, 32'd100, 32'd7, 6'd0, 5'd0);
            repeat (31) @(negedge clk);      // 采样沿 +31 拍 = 产生 done 的那个沿
            kill = 1'b1;
            @(negedge clk);
            kill = 1'b0;
            if (busy || done_valid) begin
                $display("FAIL: H4 末拍 kill 未压住 done (busy=%b done=%b)", busy, done_valid);
                errors = errors + 1;
            end
            $display("PASS: H4 末拍 kill 抑制 done");
        end

        // ---- 段 2: 随机对照 (每 20 组注入一次角例) ----
        for (i = 0; i < RAND_N; i = i + 1) begin : rnd
            reg [31 : 0] ra, rb;
            reg [1 : 0]  ro;
            ro = i[1 : 0];
            ra = $random;  rb = $random;
            if ((i % 20) == 0)  rb = 32'd0;                              // 除零
            if ((i % 20) == 5)  begin ra = 32'h8000_0000;  rb = 32'hFFFF_FFFF;  end
            if ((i % 20) == 10) ra = {16'd0, $random};                   // 小被除数 (商高位全 0)
            if ((i % 20) == 15) rb = {16'd0, $random} | 32'd1;           // 小除数
            issue(ro, ra, rb, 6'd0, 5'd0);
            await_done;
            if (done_result !== ref_model(ro, ra, rb)) begin
                $display("FAIL: rnd op=%0d a=%h b=%h r=%h expect=%h",
                         ro, ra, rb, done_result, ref_model(ro, ra, rb));
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("LARGE TESTS PASSED (%0d random)", RAND_N);
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;                            // vvp -N: 失败退出码为 1
        end
        $finish;
    end

endmodule
