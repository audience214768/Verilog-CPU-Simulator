// 乘法器 testbench: 定向边界向量 + 随机向量, 64 位参考模型对比四种符号模式
// 参考模型按 RV32M 语义: MULH(s,s) MULHSU(s,u) MULHU(u,u), MUL 为低半 (uu 覆盖)
module tb_mul;

    // 随机组数: 默认 500 (日常回归 ~4.5 分钟); 模块最终验收用 2000 (8400 checks, ~16 分钟),
    // 已通过: make run TB=exec/tb_mul RAND_N=2000
    parameter RAND_N = 500;

    reg  [31:0] a, b;
    reg         a_signed, b_signed;
    wire [63:0] product;

    integer errors = 0;
    integer i, j, m;
    reg [31:0] vals [0:9];

    mul dut (
        .a(a), .b(b), .a_signed(a_signed), .b_signed(b_signed), .product(product)
    );

    task check;
        input [31:0] va;
        input [31:0] vb;
        input        xs;   // a_signed
        input        ys;   // b_signed
        reg [63:0] expect;
        begin
            a = va; b = vb; a_signed = xs; b_signed = ys;
            #1;
            if (xs && ys)
                expect = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
            else if (xs)
                expect = $signed({{32{a[31]}}, a}) * {32'b0, b};
            else if (ys)
                expect = {32'b0, a} * $signed({{32{b[31]}}, b});
            else
                expect = {32'b0, a} * {32'b0, b};
            if (product !== expect) begin
                $display("FAIL: a=%h b=%h mode=(%b,%b) product=%h expect=%h",
                         a, b, a_signed, b_signed, product, expect);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/exec/tb_mul.vcd");
        // 只 dump 接口信号: 乘法器内部树级中间信号数量大 (53 行 x 64 位), 全量 dump 使 VCD 巨大
        $dumpvars(0, a, b, a_signed, b_signed, product);

        // ---- 定向边界向量: 0, ±1, 2^31 边界, 2^32-1, 交替位 ----
        vals[0] = 32'd0;
        vals[1] = 32'd1;
        vals[2] = 32'd2;
        vals[3] = 32'd3;
        vals[4] = 32'h7FFFFFFF;   // 最大正有符号
        vals[5] = 32'h80000000;   // 最小负有符号 / 2^31
        vals[6] = 32'h80000001;   // -2^31+1
        vals[7] = 32'hFFFFFFFF;   // -1 / 2^32-1
        vals[8] = 32'hAAAAAAAA;
        vals[9] = 32'h55555555;

        // 全组合 (10x10) x 4 模式
        for (i = 0; i < 10; i = i + 1)
            for (j = 0; j < 10; j = j + 1)
                for (m = 0; m < 4; m = m + 1)
                    check(vals[i], vals[j], m[1], m[0]);

        // ---- 随机向量: RAND_N 组 x 4 模式 ----
        for (i = 0; i < RAND_N; i = i + 1)
            for (m = 0; m < 4; m = m + 1)
                check($random, $random, m[1], m[0]);

        $display("total checks: %0d", 400 + RAND_N * 4);
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("%0d TESTS FAILED", errors);
            $stop; // vvp -N: 失败退出码为 1
        end
        $finish;
    end

endmodule
