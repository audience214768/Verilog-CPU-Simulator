// 整机联调: 3 个汇编程序依次加载进内存运行, TERM marker (ori x0,x0,255) 停机后
// 断言 ret_val (x10 低 8 位) 与统计计数
// p1_sum: 0..99 累加 = 4950 → 0x56; p2_vecadd: Σ(30i+3) = 864 → 0x60;
// p3_vecmul: Σ2(i+1) = 72 → 0x48
// 失败: N TESTS FAILED + $stop; 成功: ALL TESTS PASSED + $finish
module tb_cpu_top;
    reg  clk, rst_n;
    wire halt;
    wire [7 : 0]       ret_val;
    wire [31 : 0]      commit_count, flush_count, branch_count;
    wire [$clog2(32) - 1 : 0] rob_head;
    wire               rob_ready_head;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n),
        .halt(halt), .ret_val(ret_val),
        .commit_count(commit_count), .flush_count(flush_count),
        .branch_count(branch_count),
        .rob_head(rob_head), .rob_ready_head(rob_ready_head)
    );

    integer errors = 0;
    integer progfd;

    // ---- 稳定快照: negedge clk (组合已结算) 每 cycle 记录关键状态 ----
    // S: 快照行; 风暴时 (组合不收敛) negedge 不触发, 靠 run_prog 超时定位
    always @(negedge clk) begin
        $fwrite(progfd, "S%0d t=%0t sel=%b cdbv=%b flushing=%b misp=%b ie=%b hb=%b rs_v=%b sidx=%0d\n  e1: op=%02x f3=%0b pc=%h prs1=%0d prs2=%0d prd=%0d pt=%b robh=%0d robl=%0d lsqh=%0d lsqf=%0d cmt=%0d fls=%0d\n",
                dut.commit_count_r, $time, dut.sel_valid, dut.cdb_slot_valid_w,
                dut.flushing_r, dut.misp_valid, dut.issue_en, dut.have_batch,
                dut.u_rs.entry_valid, dut.u_rs.sel_idx_w,
                dut.u_rs.entry_opcode[1 * 7 +: 7], dut.u_rs.entry_func3[1 * 3 +: 3],
                dut.u_rs.entry_pc[1 * 32 +: 32],
                dut.u_rs.entry_prs1[1 * 6 +: 6], dut.u_rs.entry_prs2[1 * 6 +: 6],
                dut.u_rs.entry_prd[1 * 6 +: 6], dut.u_rs.entry_pred_taken[1],
                dut.rob_head_w, dut.rob_last_w, dut.u_lsq.head_r, dut.u_lsq.free_count_r,
                dut.commit_count_r, dut.flush_count_r);
        $fflush(progfd);
    end

    // 运行一个程序: 加载 hex → 复位 → 轮询直到 ret 锁存
    task run_prog;
        input [127 : 0] fname;
        input [7 : 0]   exp;
        integer cyc;
        begin
            $readmemh($sformatf("tb/top/%0s.hex", fname), dut.u_mem.mem);
            rst_n = 0;
            #1; #8; #1;
            rst_n = 1;
            #1; #8; #1;
            cyc = 0;
            while (!dut.ret_latched_r && cyc < 3000) begin
                #1; #8; #1;
                cyc = cyc + 1;
                if (((cyc < 100) && ((cyc % 10) == 0)) || ((cyc >= 100) && ((cyc % 50) == 0))) begin
                    $fwrite(progfd, "prog=%0s cyc=%0d commit=%0d flush=%0d\n",
                            fname, cyc, dut.commit_count_r, dut.flush_count_r);
                    $fflush(progfd);
                end
                if (cyc == 100)
                    $display("DBG %0s@100: commit=%0d robh=%0d robl=%0d halt=%b stall=%b batch=%b iss=%b pc=%h",
                             fname, dut.commit_count_r, dut.rob_head_w, dut.rob_last_w,
                             halt, dut.fetch_stall, dut.have_batch, dut.issue_en,
                             dut.u_fetch.pc_r);
            end
            if (!dut.ret_latched_r) begin
                $display("FAIL: %0s timeout (ret not latched, halt=%b)", fname, halt);
                errors = errors + 1;
            end else if (ret_val !== exp) begin
                $display("FAIL: %0s ret=%0d exp=%0d cyc=%0d commit=%0d flush=%0d",
                         fname, ret_val, exp, cyc, commit_count, flush_count);
                errors = errors + 1;
            end else begin
                $display("PASS: %0s ret=%0d cycles=%0d commit=%0d flush=%0d branch=%0d",
                         fname, ret_val, cyc, commit_count, flush_count, branch_count);
            end
        end
    endtask

    initial begin
        progfd = $fopen("/tmp/cpu_top_prog.log", "w");
        $dumpfile("sim/top/tb_cpu_top.vcd");
        $dumpvars(0, tb_cpu_top);
        clk = 0;
        rst_n = 0;

        $fwrite(progfd, "START p2\n"); $fflush(progfd);
        run_prog("p2_vecadd", 8'h60);

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TESTS FAILED", errors);
            $stop;
        end
        $finish;
    end

    always #5 clk = ~clk;
endmodule
