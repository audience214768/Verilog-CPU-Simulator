// ALU 单元测试: 14 ops 全覆盖 + 边界 (溢出/极值/移位 0/31/32), 再随机对照 64 位参考模型
// 失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
module tb_alu;
    reg  [31 : 0] a, b;
    reg  [4 : 0]  op;
    wire [31 : 0] result;

    integer errors = 0;

    alu dut (
        .a(a), .b(b), .op(op), .result(result)
    );

    // 检查一次运算
    task check;
        input [31 : 0] ea;
        input [31 : 0] eb;
        input [4 : 0]  eo;
        input [31 : 0] er;
        reg [63 : 0] sx_a, sx_b, ux_a, ux_b;
        reg [31 : 0] ref;
        begin
            sx_a = {{32{ea[31]}}, ea};  sx_b = {{32{eb[31]}}, eb};
            ux_a = {32'd0, ea};         ux_b = {32'd0, eb};
            case (eo)
                5'd0:  ref = ea + eb;
                5'd1:  ref = ea - eb;
                5'd2:  ref = ea << eb[4 : 0];
                5'd3:  ref = ($signed(ea) < $signed(eb)) ? 32'd1 : 32'd0;
                5'd4:  ref = (ea < eb) ? 32'd1 : 32'd0;
                5'd5:  ref = ea ^ eb;
                5'd6:  ref = ea >> eb[4 : 0];
                5'd7:  ref = $signed(ea) >>> eb[4 : 0];
                5'd8:  ref = ea | eb;
                5'd9:  ref = ea & eb;
                5'd10: ref = ux_a * ux_b;
                5'd11: ref = (sx_a * sx_b) >> 32;
                5'd12: ref = (sx_a * ux_b) >> 32;
                default: ref = (ux_a * ux_b) >> 32;
            endcase
            a = ea; b = eb; op = eo;
            #1;
            if (result !== er || result !== ref) begin
                $display("FAIL: op=%0d a=%h b=%h r=%h ref=%h (期望 %h)",
                         eo, ea, eb, result, ref, er);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/exec/tb_alu.vcd");
        $dumpvars(0, tb_alu);

        // ---- 第一段: 小规模 + 边界 ----
        // 加法/减法: 0, 溢出, 下溢
        check(32'd0,          32'd0,          5'd0, 32'd0);
        check(32'h7FFFFFFF,   32'd1,          5'd0, 32'h80000000);
        check(32'hFFFFFFFF,   32'd1,          5'd0, 32'd0);
        check(32'd0,          32'd1,          5'd1, 32'hFFFFFFFF);
        check(32'h80000000,   32'h7FFFFFFF,   5'd1, 32'h00000001);
        check(32'h12345678,   32'h87654321,   5'd0, 32'h99999999);
        // 移位: 0 / 1 / 31 / 32 (截断为 0)
        check(32'h80000001,   32'd0,          5'd2, 32'h80000001);
        check(32'h80000001,   32'd1,          5'd2, 32'h00000002);
        check(32'h00000001,   32'd31,         5'd2, 32'h80000000);
        check(32'h00000001,   32'd32,         5'd2, 32'd1);          // 移位量截断为 0
        check(32'h80000001,   32'd1,          5'd6, 32'h40000000);
        check(32'h80000001,   32'd31,         5'd6, 32'd1);
        check(32'h80000001,   32'd1,          5'd7, 32'hC0000000);
        check(32'h80000001,   32'd31,         5'd7, 32'hFFFFFFFF);
        check(32'h7FFFFFFF,   32'd31,         5'd7, 32'd0);          // 正数算术右移
        // 比较: 极值
        check(32'h80000000,   32'd1,          5'd3, 32'd1);          // -2^31 < 1
        check(32'd1,          32'h80000000,   5'd3, 32'd0);
        check(32'h7FFFFFFF,   32'h80000000,   5'd3, 32'd0);          // 2^31-1 > -2^31
        check(32'hFFFFFFFF,   32'd1,          5'd4, 32'd0);          // 无符号 0xFFFFFFFF > 1 → sltu=0
        check(32'd0,          32'd0,          5'd4, 32'd0);
        check(32'h80000000,   32'h7FFFFFFF,   5'd4, 32'd0);          // 0x80000000 > 0x7FFFFFFF
        // 逻辑
        check(32'h0F0F0F0F,   32'hF0F0F0F0,   5'd5, 32'hFFFFFFFF);
        check(32'h0F0F0F0F,   32'hF0F0F0F0,   5'd8, 32'hFFFFFFFF);
        check(32'h0F0F0F0F,   32'hF0F0F0F0,   5'd9, 32'd0);
        // 乘法: 符号/无符号高低 32 位
        check(32'd7,          32'd6,          5'd10, 32'd42);
        check(32'h80000000,   32'h80000000,   5'd10, 32'd0);         // 低 32 位
        check(32'h80000000,   32'h80000000,   5'd13, 32'h40000000);  // 无符号高位
        check(32'h80000000,   32'h80000000,   5'd11, 32'h40000000);  // 有符号 (-2^31)^2 高位
        check(32'hFFFFFFFF,   32'hFFFFFFFF,   5'd11, 32'd0);         // (-1)*(-1) 高位 0
        check(32'hFFFFFFFF,   32'hFFFFFFFF,   5'd13, 32'hFFFFFFFE);  // 无符号高位
        check(32'h80000000,   32'hFFFFFFFF,   5'd12, 32'h80000000);  // -2^31 * 0xFFFFFFFF
        check(32'hFFFFFFFF,   32'hFFFFFFFF,   5'd12, 32'hFFFFFFFF);  // -1 * 0xFFFFFFFF 高位
        $display("SMALL+EDGE TESTS PASSED");

        // ---- 第二段: 随机对照 ----
        begin : rnd
            integer i;
            for (i = 0; i < 500; i = i + 1) begin
                a = $random;
                b = $random;
                op = i % 14;
                #1;
                if (result !== model_ref(a, b, op)) begin
                    $display("FAIL: rnd op=%0d a=%h b=%h r=%h", op, a, b, result);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0) begin
            $display("LARGE TESTS PASSED (500 random)");
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end

    // 参考模型 (64 位扩展)
    function [31 : 0] model_ref;
        input [31 : 0] ea;
        input [31 : 0] eb;
        input [4 : 0]  eo;
        reg [63 : 0] sx_a, sx_b, ux_a, ux_b;
        begin
            sx_a = {{32{ea[31]}}, ea};  sx_b = {{32{eb[31]}}, eb};
            ux_a = {32'd0, ea};         ux_b = {32'd0, eb};
            case (eo)
                5'd0:  model_ref = ea + eb;
                5'd1:  model_ref = ea - eb;
                5'd2:  model_ref = ea << eb[4 : 0];
                5'd3:  model_ref = ($signed(ea) < $signed(eb)) ? 32'd1 : 32'd0;
                5'd4:  model_ref = (ea < eb) ? 32'd1 : 32'd0;
                5'd5:  model_ref = ea ^ eb;
                5'd6:  model_ref = ea >> eb[4 : 0];
                5'd7:  model_ref = $signed(ea) >>> eb[4 : 0];
                5'd8:  model_ref = ea | eb;
                5'd9:  model_ref = ea & eb;
                5'd10: model_ref = ux_a * ux_b;
                5'd11: model_ref = (sx_a * sx_b) >> 32;
                5'd12: model_ref = (sx_a * ux_b) >> 32;
                default: model_ref = (ux_a * ux_b) >> 32;
            endcase
        end
    endfunction
endmodule
