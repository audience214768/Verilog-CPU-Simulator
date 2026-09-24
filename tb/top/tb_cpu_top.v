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

    // ---- 存储接口 (cpu_top 已不再内建 u_mem, 由本 TB 例化 core/memory.v) ----
    localparam MEM_SIZE     = 65536;
    localparam MEM_LATENCY  = 3;
    localparam MEM_INFLIGHT = 4;
    localparam LSQ_SIZE     = 16;
    localparam LW           = $clog2(LSQ_SIZE);

    wire [31 : 0] imem_addr, inst_data;
    wire          ld_start_valid, ld_busy, ld_done_valid, sw_valid;
    wire [31 : 0] ld_start_addr, ld_done_data, sw_addr, sw_data;
    wire [1 : 0]  ld_start_width, sw_width;
    wire [LW - 1 : 0] ld_start_idx, ld_done_idx;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n),
        .halt(halt), .ret_val(ret_val),
        .commit_count(commit_count), .flush_count(flush_count),
        .branch_count(branch_count),
        .rob_head(rob_head), .rob_ready_head(rob_ready_head),
        .imem_addr(imem_addr), .inst_data(inst_data), .imem_valid(1'b1), .imem_hit(1'b1),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx), .ld_done_data(ld_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .sw_ready(1'b1)                      // 本 TB 用 memory.v (无下游队列) ⇒ 恒可收
    );

    memory #(.ISSUE_WIDTH(1), .MEM_SIZE(MEM_SIZE), .MEM_LATENCY(MEM_LATENCY),
             .MEM_INFLIGHT(MEM_INFLIGHT), .LSQ_SIZE(LSQ_SIZE)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .inst_data(inst_data), .imem_addr(imem_addr),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx), .ld_done_data(ld_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .init_valid(1'b0), .init_addr(32'd0), .init_data(8'd0)
    );

    integer errors = 0;
    integer progfd;

    // ---- 取指流水快照: pc_r / imem 地址 / 延迟地址 / 到达指令 / f2i 批寄存器 ----
    always @(negedge clk) begin
        if (rst_n)
            $fwrite(progfd, "F t=%0t pc=%h imem=%h dly=%h inst=%h f2v=%b f2raw=%h f2pc=%h stall=%b ie=%b hb=%b misp=%b flsh=%b halt=%b robh=%0d robl=%0d sp=%0d rsf=%0d exp=%h aok=%b\n",
                    $time, dut.u_fetch.pc_r, dut.imem_addr, dut.u_fetch.imem_addr_d,
                    dut.inst_data, dut.f2i_valid, dut.f2i_raw, dut.f2i_pc,
                    dut.fetch_stall, dut.issue_en, dut.have_batch, dut.misp_valid,
                    dut.flushing_r, dut.halt_q_r,
                    dut.rob_head_w, dut.rob_last_w, dut.u_fl.sp, dut.rs_free_w,
                    dut.u_fetch.exp_pc_r, dut.u_fetch.arr_ok_w);
        $fflush(progfd);
    end

    // ---- RS 有效条目 (pc/prd/rob_tag) ----
    integer ri;
    always @(negedge clk) begin
        if (rst_n)
            for (ri = 0; ri < 16; ri = ri + 1)
                if (dut.u_rs.valid_r[ri])
                    $fwrite(progfd, "R t=%0t e=%0d pc=%h op=%02x prd=%0d rob=%0d prs1=%0d prs2=%0d pt=%b\n",
                            $time, ri, dut.u_rs.pc_r[ri], dut.u_rs.opcode_r[ri],
                            dut.u_rs.prd_r[ri], dut.u_rs.rob_r[ri],
                            dut.u_rs.prs1_r[ri], dut.u_rs.prs2_r[ri],
                            dut.u_rs.ptaken_r[ri]);
        $fflush(progfd);
    end

    // ---- 发射轨迹: f2i 原始指令 vs decode 输出 vs 分配 ----
    always @(negedge clk) begin
        if (rst_n && dut.issue_en)
            $fwrite(progfd, "ISS t=%0t raw=%h pc=%h d_rd=%0d wr=%b d_op=%02x alloc=%0d prs1=%0d prs2=%0d old=%0d sp=%0d rdy=%b rob_last=%0d\n",
                    $time, dut.f2i_raw[31 : 0], dut.f2i_pc[31 : 0], dut.d_rd[4 : 0],
                    dut.d_writes_rd[0], dut.d_opcode[6 : 0], dut.alloc_val[5 : 0],
                    dut.map_out1[5 : 0], dut.map_out2[5 : 0], dut.old_map_chain[5 : 0],
                    dut.u_fl.sp, dut.rt_ready_w[dut.map_out1[5 : 0]], dut.rob_last_w);
        $fflush(progfd);
    end

    // ---- 提交轨迹: 每条提交指令的 index/raw/是否终止标记 ----
    always @(negedge clk) begin
        if (rst_n && dut.set_head_valid)
            $fwrite(progfd, "CMT t=%0t head=%0d raw=%h rd=%0d new=%0d old=%0d marker=%b halt_q=%b ret_l=%b\n",
                    $time, dut.rob_head_w, dut.rob_raw_w[dut.rob_head_w * 32 +: 32],
                    dut.rob_rd_w[dut.rob_head_w * 5 +: 5],
                    dut.rob_new_w[dut.rob_head_w * 6 +: 6],
                    dut.rob_old_w[dut.rob_head_w * 6 +: 6],
                    dut.marker_acc[0], dut.halt_q_r, dut.ret_latched_r);
        $fflush(progfd);
    end

    // ---- free_list 回收/分配轨迹 (posedge 采样 = 该边沿实际生效的值) ----
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.fl_push_valid[0])
                $fwrite(progfd, "PUSH t=%0t preg=%0d by=%0s sp=%0d\n",
                        $time, dut.fl_push_preg, dut.flushing_r ? "walk" : "cmt",
                        dut.u_fl.sp);
            if (|dut.rename_valid)
                $fwrite(progfd, "POP  t=%0t preg=%0d sp=%0d\n",
                        $time, dut.alloc_val, dut.u_fl.sp);
            $fflush(progfd);
        end
    end

    // ---- 分支执行轨迹 (槽 0 的 branch 操作数/结果) ----
    always @(negedge clk) begin
        if (rst_n && dut.sel_valid[0] && (dut.slt[0].u_slot.opcode == 7'h63))
            $fwrite(progfd, "BR t=%0t pc=%h prs1=%0d prs2=%0d op1=%h op2=%h prf1=%h prf2=%h taken=%b pred=%b misp=%b\n",
                    $time, dut.slt[0].u_slot.pc, dut.slt[0].u_slot.prs1, dut.slt[0].u_slot.prs2,
                    dut.slt[0].u_slot.op1, dut.slt[0].u_slot.op2,
                    dut.u_prf.regs[dut.slt[0].u_slot.prs1], dut.u_prf.regs[dut.slt[0].u_slot.prs2],
                    dut.slt[0].u_slot.br_taken, dut.slt[0].u_slot.pred_taken, dut.misp_valid);
        $fflush(progfd);
    end

    // ---- 体系结构寄存器影子 (提交时按 rd 采样 prf 值, 用于观察程序语义) ----
    reg [31 : 0] arch [0 : 31];
    integer ai;
    localparam TPW = 6;      // = $clog2(PRF_SIZE=64), 与 verilog/top/cpu_top.v 保持一致
    always @(posedge clk) begin
        if (rst_n && dut.set_head_valid) begin
            if (dut.rob_rd_w[dut.rob_head_w * 5 +: 5] != 5'd0)
                arch[dut.rob_rd_w[dut.rob_head_w * 5 +: 5]]
                    <= dut.u_prf.regs[dut.rob_new_w[dut.rob_head_w * TPW +: TPW]];
        end
    end

    // ---- 卡死现场: RS 条目 / ROB 窗口 / 指针 ----
    task dump_stuck;
        integer e, w;
        begin
            $display("STUCK rs_free=%0d sel_cnt=%0d robh=%0d robl=%0d rob_free=%0d sp=%0d rsf=%0d lsqh=%0d lsql=%0d lsqf=%0d",
                     dut.rs_free_w, dut.sel_cnt, dut.rob_head_w, dut.rob_last_w, dut.u_rob.free_r,
                     dut.u_fl.sp, dut.rs_free_w, dut.u_lsq.head_r, dut.u_lsq.last_r, dut.u_lsq.free_count_w);
            $display("  FLUSH flushing=%b misp=%b walk_ptr=%0d fs=%0d issue_en=%b batch=%b stall=%b halt_q=%b cdbv=%b",
                     dut.flushing_r, dut.misp_valid, dut.walk_ptr_r, dut.flush_fs_r,
                     dut.issue_en, dut.have_batch, dut.fetch_stall, dut.halt_q_r, dut.cdb_slot_valid_w);
            for (e = 0; e < 16; e = e + 1)
                if (dut.u_rs.valid_r[e])
                    $display("  RS[%0d] op=%02x prs1=%0d rdy1=%b prs2=%0d rdy2=%b prd=%0d rob=%0d lsq=%0d",
                             e, dut.u_rs.opcode_r[e], dut.u_rs.prs1_r[e], dut.rt_ready_w[dut.u_rs.prs1_r[e]],
                             dut.u_rs.prs2_r[e], dut.rt_ready_w[dut.u_rs.prs2_r[e]],
                             dut.u_rs.prd_r[e], dut.u_rs.rob_r[e], dut.u_rs.lsq_r[e]);
            $display("  MEM ld_busy=%b ld_start_v=%b ld_start_idx=%0d ld_start_addr=%h slots v=%b cnt=%b idx=%0d/%0d/%0d/%0d",
                     dut.ld_busy, dut.ld_start_valid, dut.ld_start_idx, dut.ld_start_addr,
                     u_mem.slot_valid, u_mem.slot_cnt,
                     u_mem.slot_idx[0 * 4 +: 4], u_mem.slot_idx[1 * 4 +: 4],
                     u_mem.slot_idx[2 * 4 +: 4], u_mem.slot_idx[3 * 4 +: 4]);
            for (e = 0; e < 16; e = e + 1)
                $display("  LSQ[%0d] v=%b ld=%b ar=%b dr=%b dn=%b rob=%0d prd=%0d addr=%h data=%h",
                         e, dut.u_lsq.valid_r[e], dut.u_lsq.is_load_r[e], dut.u_lsq.addr_ready_r[e],
                         dut.u_lsq.data_ready_r[e], dut.u_lsq.done_r[e],
                         dut.u_lsq.rob_tag_r[e * 5 +: 5], dut.u_lsq.prs2_or_prd_r[e * 6 +: 6],
                         dut.u_lsq.addr_r[e * 32 +: 32], dut.u_lsq.data_r[e * 32 +: 32]);
            for (w = 0; w < 32; w = w + 1)
                if (((w - dut.rob_head_w) & 31) < (32 - dut.u_rob.free_r))
                    $display("  ROB[%0d] op=%02x rd=%0d new=%0d old=%0d lsq=%0d rdy=%b",
                             w, dut.u_rob.opcode_r[w], dut.u_rob.rd_r[w], dut.u_rob.new_r[w],
                             dut.u_rob.old_r[w], dut.u_rob.lsq_r[w], dut.u_rob.ready_r[w]);
        end
    endtask

    // 运行一个程序: 加载 hex → 复位 → 轮询直到 ret 锁存
    task run_prog;
        input [127 : 0] fname;
        input [7 : 0]   exp;
        integer cyc;
        begin
            $readmemh($sformatf("tb/top/%0s.hex", fname), u_mem.mem);
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
                if ((cyc % 500) == 0)
                    $display("DBG %0s@%0d: x5(t0)=%0d x6(t1)=%0d x7(t2)=%0d x10(a0)=%0d pc=%h",
                             fname, cyc, arch[5], arch[6], arch[7], arch[10], dut.u_fetch.pc_r);
            end
            if (!dut.ret_latched_r) begin
                $display("FAIL: %0s timeout (ret not latched, halt=%b)", fname, halt);
                $display("  ARCH x5(t0)=%0d x6(t1)=%0d x7(t2)=%0d x10(a0)=%0d x1=%0d x2=%0d",
                         arch[5], arch[6], arch[7], arch[10], arch[1], arch[2]);
                dump_stuck;
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

        run_prog("p1_sum",    8'h56);
        run_prog("p2_vecadd", 8'h60);
        run_prog("p3_vecmul", 8'h48);

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
