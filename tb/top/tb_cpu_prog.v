// 编译程序整机验证 (CPU Simulator 测试集): 每次运行一个程序
//   镜像 tb/top/prog/<name>.data 与参考模拟器 (RISC-V-Tomasulo-CPU-Simulator) 同格式:
//     "@地址" 行 + 每行 16 个 2 位 hex 字节 (little-endian) → 直接 $readmemh 进 dut.u_mem.mem
//   程序结尾 addi a0,x0,255 (0x0FF00513) 提交 → halt; decode 把它视作写 x0, 故 a0 保留
//   main 的返回值 → ret_val (a0 低 8 位) 与参考 C++ 模拟器输出对照
//   用法: make run TB=top/tb_cpu_prog ARGS="+PROG=gcd"; 缺省跑 naive
//   可选: +DUMP=N 只 dump 前 N 拍 (缺省 2000, 0 = 不 dump; VCD 太大时用)
//   性能微负载 loopjal (jal 自循环) / loopld (lw+分支循环): 无终止指令, **只配 +PERF=N 用** (缺 +PERF 会跑到超时)
//   失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
`timescale 1ns/1ps
module tb_cpu_prog;
    // 0x40000: 覆盖代码 (0x1000) / 栈 (0x20000, 程序入口 lui sp,0x20) / 停机 MMIO (0x30004)
    localparam MEM_SIZE  = 262144;
    localparam MAX_CYCLE = 2000000;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire        halt;
    wire [7 : 0]  ret_val;
    wire [31 : 0] commit_count, flush_count, branch_count;
    wire [$clog2(32) - 1 : 0] rob_head;
    wire        rob_ready_head;

    cpu_top #(.ISSUE_WIDTH(1), .MEM_SIZE(MEM_SIZE)) dut (
        .clk(clk), .rst_n(rst_n),
        .halt(halt), .ret_val(ret_val),
        .commit_count(commit_count), .flush_count(flush_count),
        .branch_count(branch_count),
        .rob_head(rob_head), .rob_ready_head(rob_ready_head)
    );

    integer errors = 0;
    reg [8 * 16 - 1 : 0] prog_name;
    integer dump_cyc;
    integer trace_n;
    integer cyc;
    integer perf_n;      // >0: 只跑 N 拍 (性能测量; 不看 ret, 供消融矩阵用)

    // ---- 可选逐拍 trace (+TRACE=N, 缺省 0 = 关): 定位卡死时看 rob 头 / rs / lsq / 取指 ----
    integer te;
    always @(negedge clk) begin
        if (rst_n && (cyc <= trace_n) && (trace_n > 0)) begin
            $display("T %0d pc=%h f2v=%b raw=%h iss=%b hb=%b misp=%b flsh=%b halt=%b robh=%0d robl=%0d rdy=%b raw_h=%h",
                     cyc, dut.u_fetch.pc_r, dut.f2i_valid, dut.f2i_raw[31 : 0],
                     dut.issue_en, dut.have_batch, dut.misp_valid, dut.flushing_r,
                     dut.halt_q_r, dut.rob_head_w, dut.rob_last_w,
                     dut.rob_ready_w[dut.rob_head_w],
                     dut.rob_raw_w[dut.rob_head_w * 32 +: 32]);
            for (te = 0; te < 16; te = te + 1)
                if (dut.u_rs.valid_r[te])
                    $display("   RS[%0d] op=%02x prs1=%0d rdy1=%b prs2=%0d rdy2=%b prd=%0d rob=%0d lsq=%0d pc=%h",
                             te, dut.u_rs.opcode_r[te], dut.u_rs.prs1_r[te],
                             dut.rt_ready_w[dut.u_rs.prs1_r[te]], dut.u_rs.prs2_r[te],
                             dut.rt_ready_w[dut.u_rs.prs2_r[te]], dut.u_rs.prd_r[te],
                             dut.u_rs.rob_r[te], dut.u_rs.lsq_r[te], dut.u_rs.pc_r[te]);
            for (te = 0; te < 16; te = te + 1)
                if (dut.u_lsq.valid_r[te])
                    $display("   LSQ[%0d] ld=%b ar=%b dr=%b dn=%b rob=%0d addr=%h data=%h",
                             te, dut.u_lsq.is_load_r[te], dut.u_lsq.addr_ready_r[te],
                             dut.u_lsq.data_ready_r[te], dut.u_lsq.done_r[te],
                             dut.u_lsq.rob_tag_r[te * 5 +: 5],
                             dut.u_lsq.addr_r[te * 32 +: 32], dut.u_lsq.data_r[te * 32 +: 32]);
            $display("   MEM ldbusy=%b ldv=%b ldi=%0d lda=%h lsqh=%0d lsql=%0d",
                     dut.ld_busy, dut.ld_start_valid, dut.ld_start_idx, dut.ld_start_addr,
                     dut.u_lsq.head_r, dut.u_lsq.last_r);
        end
    end

    // 期望返回值: 源文件注释 (judgeResult % Mod) 与参考模拟器 (build/code < <name>.data) 输出一致
    function [7 : 0] exp_ret_f;
        input [8 * 16 - 1 : 0] n;
        begin
            exp_ret_f = (n == "naive")          ? 8'd94
                      : (n == "gcd")            ? 8'd178
                      : (n == "array_test1")    ? 8'd123
                      : (n == "array_test2")    ? 8'd43
                      : (n == "statement_test") ? 8'd50
                      : (n == "lvalue2")        ? 8'd175
                      : (n == "manyarguments")  ? 8'd40
                      : (n == "expr")           ? 8'd58
                      : (n == "multiarray")     ? 8'd115
                      : (n == "basicopt1")      ? 8'd88
                      : (n == "hanoi")          ? 8'd20
                      : (n == "bulgarian")      ? 8'd159
                      : (n == "magic")          ? 8'd106
                      : (n == "qsort")          ? 8'd105
                      : (n == "queens")         ? 8'd171
                      : (n == "pi")             ? 8'd137
                      : (n == "superloop")      ? 8'd134
                      : (n == "tak")            ? 8'd186
                      : 8'h00;
        end
    endfunction

    // 运行程序: 装载镜像 → 复位 → 跑到 ret 锁存或超时
    task run_prog;
        input [8 * 16 - 1 : 0] nm;
        reg [7 : 0]         exp;
        integer             mi;
        begin
            exp = exp_ret_f(nm);
            $display("== %0s (exp=%0d, file=%0s)", nm, exp,
                     $sformatf("tb/top/prog/%0s.data", nm));
            for (mi = 0; mi < MEM_SIZE; mi = mi + 1)
                dut.u_mem.mem[mi] = 8'h00;          // 清零 (镜像只覆盖部分地址)
            $readmemh($sformatf("tb/top/prog/%0s.data", nm), dut.u_mem.mem);
            rst_n = 1'b0;
            #1; #8; #1;
            rst_n = 1'b1;
            #1; #8; #1;
            cyc = 0;
            while (!dut.ret_latched_r && cyc < MAX_CYCLE
                   && ((perf_n == 0) || (cyc < perf_n))) begin
                #1; #8; #1;
                cyc = cyc + 1;
                if (dump_cyc > 0 && cyc == dump_cyc) $dumpoff;
                if ((cyc % 20000) == 0)
                    $display("   ... %0s cyc=%0d commit=%0d pc=%h", nm, cyc,
                             commit_count, dut.u_fetch.pc_r);
            end
            if ((perf_n > 0) && !dut.ret_latched_r) begin
                // 性能模式: 只跑固定拍数, 报 IPC (提交数/拍); 不作对错判定
                $display("PERF: %0s cycles=%0d commit=%0d ipc=%0d.%03d flush=%0d branch=%0d",
                         nm, cyc, commit_count,
                         (commit_count * 1000) / cyc,
                         ((commit_count * 1000000) / cyc) % 1000,
                         flush_count, branch_count);
            end else if (!dut.ret_latched_r) begin
                $display("FAIL: %0s timeout @%0d (halt=%b pc=%h commit=%0d)",
                         nm, cyc, halt, dut.u_fetch.pc_r, commit_count);
                errors = errors + 1;
            end else if (ret_val !== exp) begin
                $display("FAIL: %0s ret=%0d exp=%0d cycles=%0d commit=%0d flush=%0d",
                         nm, ret_val, exp, cyc, commit_count, flush_count);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s ret=%0d cycles=%0d commit=%0d flush=%0d branch=%0d",
                         nm, ret_val, cyc, commit_count, flush_count, branch_count);
            end
        end
    endtask

    initial begin
        $dumpfile("sim/top/tb_cpu_prog.vcd");
        // 只记录 TB + 各流水模块, 不含 u_mem.mem (26 万字节数组会把 VCD 撑到数百 MB)
        $dumpvars(1, tb_cpu_prog);
        $dumpvars(1, dut);
        $dumpvars(0, dut.u_fetch);
        $dumpvars(0, dut.u_decode);
        $dumpvars(0, dut.u_rob);
        $dumpvars(0, dut.u_rs);
        $dumpvars(0, dut.u_lsq);
        $dumpvars(0, dut.u_rat);
        $dumpvars(0, dut.u_fl);
        $dumpvars(0, dut.u_rt);
        $dumpvars(0, dut.u_prf);
        $dumpvars(0, dut.u_cdb);
        if (!$value$plusargs("PROG=%s", prog_name)) prog_name = "naive";
        if (!$value$plusargs("DUMP=%d", dump_cyc))  dump_cyc  = 2000;
        if (!$value$plusargs("TRACE=%d", trace_n))  trace_n   = 0;
        if (!$value$plusargs("PERF=%d", perf_n))    perf_n    = 0;
        if (dump_cyc == 0) $dumpoff;      // +DUMP=0: 完全不记录 (长程序 VCD 可达数百 MB)

        run_prog(prog_name);

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end
endmodule
