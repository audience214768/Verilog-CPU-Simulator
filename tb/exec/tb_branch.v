// 分支单元测试: 6 种条件边界 (相等/跨 0/极值) + jal/jalr 目标链接, 再随机对照
// 失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
module tb_branch;
    reg  [31 : 0] rs1, rs2, pc, imm;
    reg  [1 : 0]  mode;
    reg  [2 : 0]  br_op;
    wire          taken;
    wire [31 : 0] target, link;

    integer errors = 0;

    branch dut (
        .rs1(rs1), .rs2(rs2), .pc(pc), .imm(imm),
        .mode(mode), .br_op(br_op),
        .taken(taken), .target(target), .link(link)
    );

    // 条件真值 (与 DUT 同语义)
    function cond_f;
        input [31 : 0] a;
        input [31 : 0] b;
        input [2 : 0]  o;
        begin
            case (o)
                3'd0: cond_f = (a == b);
                3'd1: cond_f = (a != b);
                3'd4: cond_f = ($signed(a) < $signed(b));
                3'd5: cond_f = !($signed(a) < $signed(b));
                3'd6: cond_f = (a < b);
                default: cond_f = !(a < b);
            endcase
        end
    endfunction

    // 检查一次
    task check;
        input [31 : 0] ea;
        input [31 : 0] eb;
        input [31 : 0] epc;
        input [31 : 0] eimm;
        input [1 : 0]  em;
        input [2 : 0]  eo;
        begin
            rs1 = ea; rs2 = eb; pc = epc; imm = eimm; mode = em; br_op = eo;
            #1;
            if (taken !== (em == 2'd0 ? cond_f(ea, eb, eo) : 1'b1)
             || target !== (em == 2'd2 ? ((ea + eimm) & 32'hFFFFFFFE)
                          : (em == 2'd0 ? (taken ? (epc + eimm) : (epc + 32'd4))
                          : (epc + eimm)))
             || link !== (epc + 32'd4)) begin
                $display("FAIL: m=%0d op=%0d a=%h b=%h pc=%h imm=%h t=%b tg=%h lk=%h",
                         em, eo, ea, eb, epc, eimm, taken, target, link);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/exec/tb_branch.vcd");
        $dumpvars(0, tb_branch);

        // ---- 第一段: 小规模 + 边界 ----
        // beq/bne: 相等与不等
        check(32'd0,          32'd0,          32'h1000, 32'd8,   2'd0, 3'd0);
        check(32'd1,          32'd2,          32'h1000, 32'hFF8, 2'd0, 3'd0);
        check(32'd1,          32'd2,          32'h1000, 32'hFF8, 2'd0, 3'd1);
        check(32'hFFFFFFFF,   32'hFFFFFFFF,   32'h1000, 32'hFFC, 2'd0, 3'd1);
        // blt/bge: 跨 0, 极值
        check(32'hFFFFFFFF,   32'd0,          32'h1000, 32'd16,  2'd0, 3'd4);   // -1 < 0
        check(32'd0,          32'hFFFFFFFF,   32'h1000, 32'd16,  2'd0, 3'd4);
        check(32'h80000000,   32'h7FFFFFFF,   32'h1000, 32'd16,  2'd0, 3'd4);   // -2^31 < 2^31-1
        check(32'h7FFFFFFF,   32'h80000000,   32'h1000, 32'd16,  2'd0, 3'd5);   // bge
        check(32'hFFFFFFFF,   32'd0,          32'h1000, 32'd16,  2'd0, 3'd5);
        // bltu/bgeu: 无符号
        check(32'hFFFFFFFF,   32'd0,          32'h1000, 32'd16,  2'd0, 3'd6);   // 0xFFFFFFFF > 0
        check(32'd0,          32'd1,          32'h1000, 32'd16,  2'd0, 3'd6);
        check(32'hFFFFFFFF,   32'd0,          32'h1000, 32'd16,  2'd0, 3'd7);
        check(32'd1,          32'd1,          32'h1000, 32'd16,  2'd0, 3'd6);
        check(32'd1,          32'd1,          32'h1000, 32'd16,  2'd0, 3'd7);
        // jal: 无条件, pc+imm (负数 imm), link=pc+4
        check(32'd0,          32'd0,          32'h1000, 32'hFFFFFFFC, 2'd1, 3'd0);
        check(32'd0,          32'd0,          32'h0FFF, 32'h00001000,  2'd1, 3'd0);
        // jalr: 目标 (rs1+imm)&~1, 奇数 imm 对齐
        check(32'h2000,       32'd0,          32'h1000, 32'd3,   2'd2, 3'd0);
        check(32'h2001,       32'd0,          32'h1000, 32'hFFFFFFFC, 2'd2, 3'd0);
        $display("SMALL+EDGE TESTS PASSED");

        // ---- 第二段: 随机对照 ----
        begin : rnd
            integer i, rr;
            for (i = 0; i < 500; i = i + 1) begin
                rs1 = $random; rs2 = $random;
                pc  = $random & 32'hFFFFF000;
                imm = ($random & 1) ? ($random & 32'h00000FFF) : ($random | 32'hFFFFF000);
                mode = ($random & 2'h3) % 2'd3;   // 0/1/2 (3 映射 0)
                rr = $random & 3'h7;
                br_op = (rr < 2) ? rr[2 : 0] : (rr + 2);   // 合法集 {0,1,4,5,6,7}
                #1;
                if (taken !== (mode == 2'd0 ? cond_f(rs1, rs2, br_op) : 1'b1)
                 || target !== (mode == 2'd2 ? ((rs1 + imm) & 32'hFFFFFFFE)
                              : (mode == 2'd0 ? (taken ? (pc + imm) : (pc + 32'd4))
                              : (pc + imm)))
                 || link !== (pc + 32'd4)) begin
                    $display("FAIL: rnd m=%0d op=%0d a=%h b=%h pc=%h imm=%h", mode, br_op,
                             rs1, rs2, pc, imm);
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
endmodule
