// tb_rat: 段 1 小规模+极端 (复位恒等/基本 rename/批内前递最后匹配者赢/flush>rename/
//        flush 多槽同 rd 更老赢/rd=0 抑制/跨拍无泄漏); 段 2 大规模随机模型对照 (500 拍)
// 时序模板: 驱动(t=26+10n) → #1 组合断言 → #8 posedge → #1 arch 断言 → 下用例
`timescale 1ns/1ps
module tb_rat;
    localparam IW  = 4;
    localparam PRF = 64;
    localparam PW  = 6;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [IW * PW - 1 : 0] map_out1, map_out2;
    wire [32 * PW - 1 : 0] map_arch;
    reg  [IW * 5 - 1 : 0]  read_rs1, read_rs2;
    reg  [IW - 1 : 0]      rename_valid;
    reg  [IW * 5 - 1 : 0]  rename_rd;
    reg  [IW * PW - 1 : 0] rename_new;
    reg  [IW - 1 : 0]      flush_valid;
    reg  [IW * 5 - 1 : 0]  flush_rd;
    reg  [IW * PW - 1 : 0] flush_old;

    rat #(.ISSUE_WIDTH(IW), .PRF_SIZE(PRF)) dut (
        .clk(clk), .rst_n(rst_n),
        .map_out1(map_out1), .map_out2(map_out2), .map_arch(map_arch),
        .read_rs1(read_rs1), .read_rs2(read_rs2),
        .rename_valid(rename_valid), .rename_rd(rename_rd), .rename_new(rename_new),
        .flush_valid(flush_valid), .flush_rd(flush_rd), .flush_old(flush_old)
    );

    integer errors = 0;
    integer i, j, k;

    task check;
        input        ok;
        input [255:0] msg;
        begin
            if (!ok) begin
                $display("FAIL: %s", msg);
                errors = errors + 1;
            end else
                $display("PASS: %s", msg);
        end
    endtask

    task check_map;
        input [4 : 0]      idx;
        input [PW - 1 : 0] exp;
        begin
            if (map_arch[idx * PW +: PW] !== exp) begin
                $display("FAIL: map[%0d] = %0d, expect %0d", idx, map_arch[idx * PW +: PW], exp);
                errors = errors + 1;
            end
        end
    endtask

    task clr;
        begin
            read_rs1 = 0; read_rs2 = 0;
            rename_valid = 0; rename_rd = 0; rename_new = 0;
            flush_valid = 0; flush_rd = 0; flush_old = 0;
        end
    endtask

    initial begin
        $dumpfile("sim/core/tb_rat.vcd");
        $dumpvars(0, tb_rat);

        // ---- 段 1: 小规模 + 极端 ----
        clr();
        #23 rst_n = 1;                     // 复位 2 拍, t=25 起正常
        #3;
        // C1 复位恒等
        for (i = 0; i < 32; i = i + 1) check_map(i, i);

        // C2 基本 rename: 驱动拍内读口仍显旧值 (时序写), 锁存后阵列更新 + 读口反映
        clr();
        rename_valid = 4'b0001; rename_rd = 5'd3; rename_new = 6'd40;
        read_rs1 = 5'd3;
        #1;
        check(map_out1[0 * PW +: PW] === 6'd3, "C2 驱动拍内读口仍显旧映射 3");
        #8;
        #1;
        check_map(3, 40);
        check_map(4, 4);
        check_map(10, 10);
        // 无 rename 拍: 读口显示新映射 (阵列值 40)
        clr();
        read_rs1 = 5'd3;
        #1;
        check(map_out1[0 * PW +: PW] === 6'd40, "C2 rename 后读口显示 40");
        #8;
        #1;

        // C3 批内前递: rename 批 {s0 rd=3→40, s1 rd=4→41, s2 rd=5→42, s3 rd=3→43}
        clr();
        rename_valid = 4'b1111;
        rename_rd   = {5'd3, 5'd5, 5'd4, 5'd3};
        rename_new  = {6'd43, 6'd42, 6'd41, 6'd40};
        read_rs1    = {5'd5, 5'd4, 5'd3, 5'd5};   // s3 rs=5, s2 rs=4, s1 rs=3, s0 rs=5
        read_rs2    = {5'd5, 5'd0, 5'd0, 5'd0};
        #1;
        check(map_out1[0 * PW +: PW] === 6'd5,  "C3 slot0 无转发 (阵列 5)");
        check(map_out1[1 * PW +: PW] === 6'd40, "C3 slot1 rs=3 看到 rename[0] → 40");
        check(map_out1[2 * PW +: PW] === 6'd41, "C3 slot2 rs=4 看到 rename[1] → 41");
        check(map_out1[3 * PW +: PW] === 6'd42, "C3 slot3 rs=5 看到 rename[2] → 42");
        check(map_out2[3 * PW +: PW] === 6'd42, "C3 slot3 rs2=5 同 → 42");
        #8;
        #1;
        check_map(3, 43);                    // 批内最后 rename (j=3) 赢
        check_map(4, 41);
        check_map(5, 42);

        // C4 flush > rename: 同拍 rename rd=3→44 与 flush rd=3→45
        clr();
        rename_valid = 4'b0001; rename_rd = 5'd3; rename_new = 6'd44;
        flush_valid = 4'b0001; flush_rd = 5'd3;  flush_old = 6'd45;
        read_rs1 = 5'd3;
        #1;
        check(map_out1[0 * PW +: PW] === 6'd43, "C4 驱动拍内读口仍显旧映射 43");
        #8;
        #1;
        check_map(3, 45);                    // flush 写优先级 > rename

        // C5 flush 多槽同 rd: slot0 old=30 (最新), slot1 old=29 (更老) → 更老赢
        clr();
        flush_valid = 4'b0011;
        flush_rd    = {4{5'd5}};
        flush_old   = {6'd0, 6'd0, 6'd29, 6'd30};   // slot1=29 (更老), slot0=30 (最新)
        #1;
        #8;
        #1;
        check_map(5, 29);

        // C6 rd=0 抑制: rename rd=0 不写
        clr();
        rename_valid = 4'b0001; rename_rd = 5'd0; rename_new = 6'd50;
        #1;
        #8;
        #1;
        check_map(0, 0);

        // C7 跨拍无转发泄漏: 无 rename 拍读旧寄存器 → 阵列值
        clr();
        read_rs1 = {5'd5, 5'd0, 5'd0, 5'd0};   // slot3 rs=5 (读 map[5]=29)
        #1;
        if (map_out1[3 * PW +: PW] !== 6'd29) begin
            $display("FAIL: C7 out1[3] = %0d expect 29 (map[5]=%0d)", map_out1[3 * PW +: PW], map_arch[5 * PW +: PW]);
            errors = errors + 1;
        end else
            $display("PASS: C7 无 rename 时读阵列 (map[5]=29)");
        #9;

        if (errors == 0)
            $display("SMALL+EDGE TESTS PASSED");
        else
            $display("SMALL+EDGE: %0d TESTS FAILED", errors);

        // ---- 段 2: 大规模随机模型对照 (500 拍) ----
        begin : sec2
            reg [PW - 1 : 0] model [0 : 31];
            reg [PW - 1 : 0] exp1, exp2;
            integer n1, n2;
            // 模型从 DUT 当前状态开始 (段 1 已写入 map[3]=45, map[5]=29)
            for (i = 0; i < 32; i = i + 1) model[i] = map_arch[i * PW +: PW];
            for (i = 0; i < 500; i = i + 1) begin
                // 随机 prefix 批 (rename/flush) + 随机读口 (含 rd=0/rs 重复)
                n1 = {$random} % (IW + 1);
                n2 = {$random} % (IW + 1);
                case (n1)
                    0: rename_valid = 4'b0000;
                    1: rename_valid = 4'b0001;
                    2: rename_valid = 4'b0011;
                    3: rename_valid = 4'b0111;
                    default: rename_valid = 4'b1111;
                endcase
                case (n2)
                    0: flush_valid = 4'b0000;
                    1: flush_valid = 4'b0001;
                    2: flush_valid = 4'b0011;
                    3: flush_valid = 4'b0111;
                    default: flush_valid = 4'b1111;
                endcase
                for (j = 0; j < IW; j = j + 1) begin
                    rename_rd[j * 5 +: 5]    = {$random} % 32;
                    rename_new[j * PW +: PW] = {$random} % PRF;
                    flush_rd[j * 5 +: 5]     = {$random} % 32;
                    flush_old[j * PW +: PW]  = {$random} % PRF;
                    read_rs1[j * 5 +: 5]     = {$random} % 32;
                    read_rs2[j * 5 +: 5]     = {$random} % 32;
                end
                #1;
                // 组合读口 vs 模型 (批内转发: 最后匹配 rename 赢)
                for (j = 0; j < IW; j = j + 1) begin
                    exp1 = model[read_rs1[j * 5 +: 5]];
                    exp2 = model[read_rs2[j * 5 +: 5]];
                    for (k = 0; k < j; k = k + 1) begin
                        if (rename_valid[k] && (rename_rd[k * 5 +: 5] != 5'd0) && (rename_rd[k * 5 +: 5] == read_rs1[j * 5 +: 5]))
                            exp1 = rename_new[k * PW +: PW];
                        if (rename_valid[k] && (rename_rd[k * 5 +: 5] != 5'd0) && (rename_rd[k * 5 +: 5] == read_rs2[j * 5 +: 5]))
                            exp2 = rename_new[k * PW +: PW];
                    end
                    if (map_out1[j * PW +: PW] !== exp1 || map_out2[j * PW +: PW] !== exp2) begin
                        $display("FAIL: LARGE cyc %0d slot %0d out=%0d/%0d expect %0d/%0d",
                                 i, j, map_out1[j * PW +: PW], map_out2[j * PW +: PW], exp1, exp2);
                        errors = errors + 1;
                    end
                end
                #8;                          // posedge
                #1;
                // 模型更新 (等价于 DUT posedge 应用本拍输入) + arch 全阵列断言
                for (j = 0; j < IW; j = j + 1)
                    if (rename_valid[j] && (rename_rd[j * 5 +: 5] != 5'd0))
                        model[rename_rd[j * 5 +: 5]] = rename_new[j * PW +: PW];
                for (j = 0; j < IW; j = j + 1)
                    if (flush_valid[j] && (flush_rd[j * 5 +: 5] != 5'd0))
                        model[flush_rd[j * 5 +: 5]] = flush_old[j * PW +: PW];
                for (j = 0; j < 32; j = j + 1)
                    if (map_arch[j * PW +: PW] !== model[j]) begin
                        $display("FAIL: LARGE cyc %0d map[%0d] = %0d expect %0d",
                                 i, j, map_arch[j * PW +: PW], model[j]);
                        errors = errors + 1;
                    end
                // 下一拍驱动在循环顶 (整拍 10ns: 驱动@86+10i)
            end
        end

        if (errors == 0) begin
            $display("LARGE TESTS PASSED (500 cycles)");
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end
endmodule
