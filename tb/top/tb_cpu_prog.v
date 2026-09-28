// 编译程序整机验证 (CPU Simulator 测试集): 每次运行一个程序
//   镜像 tb/top/prog/<name>.data 与参考模拟器 (RISC-V-Tomasulo-CPU-Simulator) 同格式:
//     "@地址" 行 + 每行 16 个 2 位 hex 字节 (little-endian) → 直接 $readmemh 进 u_mem.mem
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
    // 超时上限: 提成 parameter 以便 -P 覆盖 —— 20 拍性能配置下重型程序总拍数远超 200 万
    // (magic 在 3 拍下已 81.9 万拍), 用默认值跑会得到"超时"而非"对/错", 那是无效结论
    parameter  MAX_CYCLE = 2000000;

    // ---- 消融可调参数 (默认 = 现状, 行为不变) ----
    // iverilog -P 只作用于 root 模块, 故参数须声明在 TB 层再下传 DUT; 覆盖示例:
    //   iverilog -g2005 -s tb_cpu_prog -P tb_cpu_prog.MEM_LATENCY_TB=20 \
    //            -P tb_cpu_prog.MEM_INFLIGHT_TB=16 -o /tmp/x.vvp $(ls verilog/*/*.v) tb/top/tb_cpu_prog.v
    // (注意: make 不会因 IV/-P 变化而重建 .vvp, 消融一律直接 iverilog + vvp 建到 /tmp)
    // 发射宽度是**唯一必须同时下传 cpu_top 与 memory 的旋钮**(取指是整批地址/整批数据);
    // 只改一处会让另外半批悬空 ⇒ 早期假停机, 不是 RTL 故障 (实测踩过)
    parameter ISSUE_WIDTH_TB  = 1;
    parameter MEM_LATENCY_TB  = 3;      // 性能档要求 20 (docs/description.md)
    parameter MEM_INFLIGHT_TB = 4;
    parameter ROB_SIZE_TB     = 32;
    parameter RS_SIZE_TB      = 16;
    parameter PRF_SIZE_TB     = 64;
    parameter LSQ_SIZE_TB     = 16;
    parameter BHT_SIZE_TB     = 32;
    parameter RAS_SIZE_TB     = 8;

    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    wire        halt;
    wire [7 : 0]  ret_val;
    wire [31 : 0] commit_count, flush_count, branch_count;
    wire [$clog2(32) - 1 : 0] rob_head;
    wire        rob_ready_head;

    // ---- 存储接口 (cpu_top 已不再内建 u_mem, 由本 TB 例化 core/memory.v) ----
    // 消融旋钮 MEM_* 随之下移到 memory 实例 (cpu_top 不再拥有存储)
    localparam LW = $clog2(LSQ_SIZE_TB);

    wire [ISSUE_WIDTH_TB * 32 - 1 : 0] imem_addr, inst_data;
    wire          ld_start_valid, ld_busy, ld_done_valid, sw_valid;
    wire [31 : 0] ld_start_addr, ld_done_data, sw_addr, sw_data;
    wire [1 : 0]  ld_start_width, sw_width;
    wire [LW - 1 : 0] ld_start_idx, ld_done_idx;

    cpu_top #(.ISSUE_WIDTH(ISSUE_WIDTH_TB),
              .ROB_SIZE(ROB_SIZE_TB), .RS_SIZE(RS_SIZE_TB), .PRF_SIZE(PRF_SIZE_TB),
              .LSQ_SIZE(LSQ_SIZE_TB), .BHT_SIZE(BHT_SIZE_TB), .RAS_SIZE(RAS_SIZE_TB)) dut (
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

    memory #(.ISSUE_WIDTH(ISSUE_WIDTH_TB), .MEM_SIZE(MEM_SIZE),
             .MEM_LATENCY(MEM_LATENCY_TB), .MEM_INFLIGHT(MEM_INFLIGHT_TB),
             .LSQ_SIZE(LSQ_SIZE_TB)) u_mem (
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
    reg [8 * 16 - 1 : 0] prog_name;
    integer dump_cyc;
    integer trace_n;
    integer trace_from;  // trace 窗口起点 (+FROM=M), 用于回放越界拍前后的若干拍
    integer cyc;
    integer perf_n;      // >0: 只跑 N 拍 (性能测量; 不看 ret, 供消融矩阵用)

    // ---- 失步探针 (+BAD=<hex 阈值>, 0 = 关): pc 越界即报第一拍并结束 (省得跑到 2M 拍) ----
    // 定位"pc 跑飞"类故障 (pc 越界而 commit 冻结): 先拿到越界拍号, 再用 +FROM/+TRACE 回放窗口
    integer bad_pc;
    reg     bad_seen = 1'b0;
    always @(negedge clk) begin
        if (rst_n && (bad_pc > 0) && !bad_seen && (dut.u_fetch.pc_r > bad_pc)) begin
            bad_seen <= 1'b1;
            $display("BAD: pc=%h > %h at cyc=%0d (stall=%b f2v=%b fl=%b halt=%b)",
                     dut.u_fetch.pc_r, bad_pc, cyc, dut.fetch_stall, dut.f2i_valid,
                     dut.flushing_r, dut.halt_q_r);
            $finish;
        end
    end

    // ---- 停滞归因计数 (纯 TB 侧采样, 不改 DUT、不进综合面积): 回答"IPC 为什么低" ----
    //   分类互斥: 冲刷拍 (misp/flushing) > 无批可取 (取指供给不上) > 有批未发射 (结构资源挡)
    //   结构资源四项可同时不满足, 故分别累计 (属"谁挡的"多重归因, 不求各分类之和等于总拍数)
    integer st_cyc, st_iss, st_flush, st_nob, st_rob, st_rs, st_fl, st_lsq, st_misp;
    always @(negedge clk) begin
        if (rst_n && !dut.halt_q_r) begin
            st_cyc = st_cyc + 1;
            if (dut.issue_en) begin
                st_iss = st_iss + 1;
            end else if (dut.misp_valid || dut.flushing_r) begin
                st_flush = st_flush + 1;
            end else if (!dut.have_batch) begin
                st_nob = st_nob + 1;
            end else begin
                if (dut.rob_full)                   st_rob = st_rob + 1;
                if ((dut.rs_free_w + dut.sel_cnt) < 1) st_rs = st_rs + 1;
                if (dut.fl_count < dut.n_wr)        st_fl = st_fl + 1;
                if (dut.lsq_free_w < dut.n_mem)     st_lsq = st_lsq + 1;
            end
            if (dut.misp_valid) st_misp = st_misp + 1;
        end
    end

    // ---- 控制转移按指令类型分 bin (纯 TB 解码, 不改 DUT): 回答"误预测该修 RAS 还是 BHT" ----
    //   bin: 0=jal 1=ret(jalr x0,0(x1)) 2=jalr(其他/间接跳转) 3=beq 4=bne 5=其他条件分支 6=非控制指令
    function integer bin_f;
        input [31 : 0] raw;
        reg [6 : 0] opc;
        reg [2 : 0] f3;
        begin
            opc = raw[6 : 0];
            f3  = raw[14 : 12];
            bin_f = (opc == 7'b1101111) ? 0
                  : (opc == 7'b1100111) ? (((raw[11 : 7] == 5'd0) && (raw[19 : 15] == 5'd1)) ? 1 : 2)
                  : (opc == 7'b1100011) ? ((f3 == 3'b000) ? 3 : (f3 == 3'b001) ? 4 : 5)
                  : 6;
        end
    endfunction

    integer kj [0 : 6];     // 预测取跳转次数 (每次伴随 1 拍取指气泡)
    integer mj [0 : 6];     // 误预测次数 (每次 2~3 拍重定向 + 错路已发射指令作废)
    wire [31 : 0] misp_raw_w = dut.rob_raw_w[dut.misp_fs_w * 32 +: 32];   // 误预测的那条指令
    integer kb;
    always @(negedge clk) begin
        if (rst_n && !dut.halt_q_r) begin
            if (dut.u_fetch.pc_jmp_w) begin
                kb = bin_f(dut.u_fetch.inst_data[31 : 0]);
                kj[kb] = kj[kb] + 1;
            end
            if (dut.misp_valid) begin
                kb = bin_f(misp_raw_w);
                mj[kb] = mj[kb] + 1;
            end
        end
    end

    // ---- 不变量: PRF 分配唯一性 (同一 preg 同时至多被一条在飞指令持有) ----
    // 违反 = free_list 池里有重复项 (把仍在用的 preg 提前/重复回收)。后果: 两条在飞指令分到同一
    // prd, 后者写入 PRF 而依赖者按前者判就绪 ⇒ 读到错值, 或生产者标签对不上 ⇒ 依赖者永不就绪
    // ⇒ 全机死锁 (W>=2 实测 gcd 卡在 blt 的 prs1)。批内两个槽同拍分配重复 preg 时, 跨拍检查
    // 看不出来 (两个槽读到的都是本拍前的值), 故同拍也要比。
    localparam PW_TB = $clog2(PRF_SIZE_TB);
    localparam RW_TB = $clog2(ROB_SIZE_TB);
    // 影子"持有集"初值 = 复位恒等映射占用的 0..31 (池初值 = 32..63); 此后 push 清、alloc 置。
    reg [PRF_SIZE_TB - 1 : 0] preg_held;
    integer pi, pj;
    always @(posedge clk) begin
        if (!rst_n) preg_held <= {{(PRF_SIZE_TB - 32){1'b0}}, {32{1'b1}}};
        else begin
            // 先回收 (commit/walker 的 push), 再分配 —— 与本拍语义一致 (分配读的是旧池)
            // 回收条件与 free_list.push_ok **逐字一致** (只挡 preg 0): 恒等映射区 1..31 被架构
            //   RAT 放弃时照常回池 (W=4 缺陷 8 的新策略), 旧影子模型在这里多挡了一道 `>= 32`。
            for (pi = 0; pi < ISSUE_WIDTH_TB; pi = pi + 1)
                if (dut.fl_push_valid[pi] && (dut.fl_push_preg[pi * PW_TB +: PW_TB] != {PW_TB{1'b0}}))
                    preg_held[dut.fl_push_preg[pi * PW_TB +: PW_TB]] <= 1'b0;
            for (pi = 0; pi < ISSUE_WIDTH_TB; pi = pi + 1) begin
                if (dut.rename_valid[pi]) begin
                    if (preg_held[dut.alloc_val[pi * PW_TB +: PW_TB]]) begin
                        $display("FAIL: PRF reused-while-held preg=%0d slot=%0d cyc=%0d",
                                 dut.alloc_val[pi * PW_TB +: PW_TB], pi, cyc);
                        errors = errors + 1;
                    end
                    for (pj = pi + 1; pj < ISSUE_WIDTH_TB; pj = pj + 1)
                        if (dut.rename_valid[pj] &&
                            (dut.alloc_val[pj * PW_TB +: PW_TB] == dut.alloc_val[pi * PW_TB +: PW_TB])) begin
                            $display("FAIL: PRF double-alloc same cycle preg=%0d slots=%0d,%0d cyc=%0d",
                                     dut.alloc_val[pi * PW_TB +: PW_TB], pi, pj, cyc);
                            errors = errors + 1;
                        end
                    preg_held[dut.alloc_val[pi * PW_TB +: PW_TB]] <= 1'b1;
                end
            end
        end
    end

    // ---- 调试: free_list 池内重复项扫描 (+FLCHK=1 开) ----
    // 池里出现重复项 ⇒ 同一 preg 会被发两次 ⇒ 两条在飞指令同 prd。扫描**真实数组** (不复制索引
    // 表达式, 免得镜像错误掩盖真相); O(FREE_NUM^2) 每拍, 仅调试时开。
    integer flchk, fi, fj;
    initial flchk = 0;
    integer nh, nrep;
    initial begin nh = 0; nrep = 0; end
    integer lsq_orphan_n, qi;
    initial lsq_orphan_n = 0;
    // 年龄差必须在 RW_TB 位宽内回绕: 写成 (tag - head) >= (ROB_SIZE - free) 会因上下文位宽
    // 先扩到 32 位再相减 ⇒ tag<head 时得到巨大无符号数 ⇒ 全是假违反 (函数内参数位宽=返回值位宽, 截断正确)
    function [RW_TB - 1 : 0] age5_f;
        input [RW_TB - 1 : 0] t, h;
        begin age5_f = t - h; end
    endfunction
    always @(posedge clk) begin
        if (flchk && rst_n) begin
            // 收支不变量: 池内空闲数 == PRF 总量 - 仍被持有的 preg 数 (持有 = 已分配且未回收),
            // 即"池 ∪ 持有 = 全部 PRF_SIZE 个" —— 新策略下恒等映射区也会回池, 故基数不再是 FREE_NUM
            // 而是 PRF_SIZE (空机: 持有=32 架构映射, 池=32)。
            // 破了就是**漏回收/多回收**: sp 偏小 ⇒ 有 preg 永久泄漏 ⇒ 池耗尽后改名全停
            // (ROB 空、commit=issue 也不动 = 死锁)。首次违反时把池与持有集全打出来定位。
            nh = 0;
            for (fi = 0; fi < PRF_SIZE_TB; fi = fi + 1)
                nh = nh + preg_held[fi];
            // 分配必须与本拍压入 ROB 的条目配对: 分配了却没进 ROB (或进的条目 new=0)
            // ⇒ 该 preg 永远不会被回收 (提交/walker 都按 rob_new!=0 产生 push) ⇒ 永久泄漏
            for (fi = 0; fi < ISSUE_WIDTH_TB; fi = fi + 1)
                if (dut.rename_valid[fi] && !dut.rob_push_valid[fi])
                    $display("FAIL: alloc without rob entry slot=%0d alloc=%0d cyc=%0d",
                             fi, dut.alloc_val[fi * PW_TB +: PW_TB], cyc);
            if ((dut.u_fl.sp != (PRF_SIZE_TB - nh)) && (nrep < 4)) begin
                nrep = nrep + 1;
                $display("FAIL: pool/held mismatch sp=%0d held=%0d expect_sp=%0d cyc=%0d",
                         dut.u_fl.sp, nh, PRF_SIZE_TB - nh, cyc);
                for (fi = 0; fi < PRF_SIZE_TB - 32; fi = fi + 1)
                    $display("   pool[%0d]=%0d", fi, dut.u_fl.pool[fi]);
                for (fi = 0; fi < PRF_SIZE_TB; fi = fi + 1)
                    if (preg_held[fi]) $display("   held preg=%0d", fi);
            end
            // RAT 必须是单射: 两个架构寄存器映到同一 preg ⇒ 两条在飞指令 old 相同 ⇒ 提交时
            // 同一 preg 被回收两次 ⇒ 池内出现重复项 ⇒ 同一 preg 发给两条在飞指令 ⇒ 死锁。
            // (任何时刻 32 个架构映射必互不相同 —— 与 preg 落在恒等区还是池区无关)
            for (fi = 0; fi < 31; fi = fi + 1)
                for (fj = fi + 1; fj < 32; fj = fj + 1)
                    if (dut.map_arch[fi * PW_TB +: PW_TB] == dut.map_arch[fj * PW_TB +: PW_TB]) begin
                        $display("FAIL: RAT non-injective x%0d,x%0d -> preg %0d cyc=%0d",
                                 fi, fj, dut.map_arch[fi * PW_TB +: PW_TB], cyc);
                        fi = 32;
                    end
            for (fi = 0; fi < PRF_SIZE_TB - 32; fi = fi + 1)
                for (fj = fi + 1; fj < PRF_SIZE_TB - 32; fj = fj + 1)
                    if ((fi < dut.u_fl.sp) && (fj < dut.u_fl.sp) &&
                        (dut.u_fl.pool[fi] == dut.u_fl.pool[fj])) begin
                        $display("FAIL: free_list duplicate preg=%0d at pool[%0d],[%0d] sp=%0d cyc=%0d",
                                 dut.u_fl.pool[fi], fi, fj, dut.u_fl.sp, cyc);
                        fi = PRF_SIZE_TB;   // 一拍只报一次
                    end
            // 本拍 push 的 preg 若已在活动区 ⇒ 就是它造出的重复项 (定位 push 来源)
            for (fi = 0; fi < ISSUE_WIDTH_TB; fi = fi + 1)
                if (dut.fl_push_valid[fi]) begin
                    for (fj = 0; fj < PRF_SIZE_TB - 32; fj = fj + 1)
                        if ((fj < dut.u_fl.sp) &&
                            (dut.u_fl.pool[fj] == dut.fl_push_preg[fi * PW_TB +: PW_TB])) begin
                            $display("FAIL: push dup preg=%0d slot=%0d (pool[%0d]) flushing=%b cyc=%0d",
                                     dut.fl_push_preg[fi * PW_TB +: PW_TB], fi, fj,
                                     dut.flushing_r, cyc);
                            fj = PRF_SIZE_TB;
                        end
                end
            // ROB 不得超发: 每拍接受的 push 数必须 <= 当拍空闲数 (free_r 是提交前的值)。
            // 破了 free_r 会下溢回绕 (ROB_SIZE 位宽) ⇒ 占用量 rob_occ = ROB_SIZE - free_r 越界
            // ⇒ (a) cmt_in_win 对窗口外槽也成立, 陈旧条目被当有效提交 ⇒ 其 old_pnum 被重复回收;
            //    (b) walker 从 last_r-1 起回滚, 走到从未 push 过的残留槽 ⇒ 其 new_pnum 被重复回收;
            //    (c) empty (free_r==ROB_SIZE) 长时间不成立 + last_r 越过真实占用 ⇒ 死锁。
            if (dut.u_rob.free_r > ROB_SIZE_TB)
                $display("FAIL: rob free_r underflow free=%0d head=%0d last=%0d cyc=%0d",
                         dut.u_rob.free_r, dut.u_rob.head_r, dut.u_rob.last_r, cyc);
            if (dut.issue_en && (dut.u_rob.free_r < dut.u_rob.push_cnt))
                $display("FAIL: rob overpush free=%0d push_cnt=%0d cyc=%0d",
                         dut.u_rob.free_r, dut.u_rob.push_cnt, cyc);
            // LSQ 孤儿条目: 有效条目的 rob_tag 必须落在 ROB 占用窗口 [head, head+occ) 内。
            // 落到窗口外 ⇒ 它的 ROB 条目已不存在 (已被提交或被 walker 回滚), 于是既不会被
            // commit 失效 (那条 ROB 条目永不再出现), 也不会再被 flush_mask 命中 ⇒ 永久有效
            // ⇒ lsq 的 dead=(~valid|kill)&~issued 恒 0 ⇒ head 不再前进 ⇒ 占满后全机死锁。
            // W=4 实测: 缺陷 9 (满窗被截断成"空窗", 31 条老条目的 ROB 有效性一并丢失) 就是本条
            // 在 cyc=3296 首次报出的 —— occ 归零后所有有效条目都落在窗口外。
            // 只在非冲刷拍查 (冲刷中窗口本就在被逐拍截断, 有 1 拍级的正常时序偏斜)。
            for (fi = 0; fi < LSQ_SIZE_TB; fi = fi + 1)
                if (rst_n && !dut.flushing_r && !dut.misp_valid && dut.u_lsq.valid_r[fi]
                    && (lsq_orphan_n < 4)) begin
                    if (age5_f(dut.u_lsq.rob_tag_r[fi * RW_TB +: RW_TB], dut.rob_head_w)
                        >= (ROB_SIZE_TB - dut.u_rob.free_r)) begin
                        lsq_orphan_n = lsq_orphan_n + 1;
                        $display("FAIL: lsq orphan idx=%0d rob_tag=%0d head=%0d occ=%0d iss=%b ld=%b ar=%b dr=%b dn=%b cyc=%0d",
                                 fi, dut.u_lsq.rob_tag_r[fi * RW_TB +: RW_TB], dut.rob_head_w,
                                 ROB_SIZE_TB - dut.u_rob.free_r, dut.u_lsq.issued_r[fi],
                                 dut.u_lsq.is_load_r[fi], dut.u_lsq.addr_ready_r[fi],
                                 dut.u_lsq.data_ready_r[fi], dut.u_lsq.done_r[fi], cyc);
                        if (lsq_orphan_n == 1) begin
                            $display("   LSQDUMP head=%0d last=%0d winlen=%0d free=%0d inv=%h kill=%h dead=%h",
                                     dut.u_lsq.head_r, dut.u_lsq.last_r, dut.u_lsq.winlen,
                                     dut.u_lsq.free_count_w, dut.lsq_invalidate,
                                     dut.lsq_flush_mask, dut.u_lsq.dead);
                            for (qi = 0; qi < LSQ_SIZE_TB; qi = qi + 1)
                                $display("   LSQE[%0d] v=%b kl=%b ld=%b ar=%b dr=%b dn=%b iss=%b tag=%0d robv=%b pc=%h",
                                         qi, dut.u_lsq.valid_r[qi], dut.u_lsq.kill[qi],
                                         dut.u_lsq.is_load_r[qi], dut.u_lsq.addr_ready_r[qi],
                                         dut.u_lsq.data_ready_r[qi], dut.u_lsq.done_r[qi],
                                         dut.u_lsq.issued_r[qi],
                                         dut.u_lsq.rob_tag_r[qi * RW_TB +: RW_TB],
                                         dut.rob_ready_w[dut.u_lsq.rob_tag_r[qi * RW_TB +: RW_TB]],
                                         dut.rob_raw_w[dut.u_lsq.rob_tag_r[qi * RW_TB +: RW_TB] * 32 +: 32]);
                        end
                    end
                end
        end
    end

    // ---- 可选逐拍 trace (+TRACE=N 止, +FROM=M 起, 缺省 0 = 关): rob 头 / rs / lsq / 取指 ----
    integer te;
    always @(negedge clk) begin
        if (rst_n && (cyc <= trace_n) && (cyc >= trace_from) && (trace_n > 0)) begin
            $display("T %0d pc=%h exp=%h arrd=%h f2v=%b raw=%h iss=%b hb=%b misp=%b flsh=%b halt=%b robh=%0d robl=%0d rdy=%b raw_h=%h",
                     cyc, dut.u_fetch.pc_r, dut.u_fetch.exp_pc_r, dut.u_fetch.imem_addr_d[31 : 0],
                     dut.f2i_valid, dut.f2i_raw,
                     dut.issue_en, dut.have_batch, dut.misp_valid, dut.flushing_r,
                     dut.halt_q_r, dut.rob_head_w, dut.rob_last_w,
                     dut.rob_ready_w[dut.rob_head_w],
                     dut.rob_raw_w[dut.rob_head_w * 32 +: 32]);
            $display("   FCH arr=%b cap=%b rw=%b predok=%b pcwr=%b stall=%b rasops=%b",
                     dut.u_fetch.arr_ok_w, dut.u_fetch.cap_w, dut.u_fetch.rewind_w,
                     dut.u_fetch.pred_ok_w, dut.u_fetch.pc_wr_w, dut.fetch_stall,
                     dut.u_fetch.ras_ops_w);
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
            // 改名/自由表 (定位 preg 重复分配: 谁把仍在用的 preg 还进了池子)
            for (te = 0; te < ISSUE_WIDTH_TB; te = te + 1)
                $display("   REN[%0d] v=%b rd=%0d old=%0d new=%0d robv=%b pushv=%b pushp=%0d sp=%0d",
                         te, dut.rename_valid[te], dut.d_rd[te * 5 +: 5],
                         dut.old_map_chain[te * PW_TB +: PW_TB], dut.alloc_val[te * PW_TB +: PW_TB],
                         dut.rob_push_valid[te],
                         dut.fl_push_valid[te], dut.fl_push_preg[te * PW_TB +: PW_TB],
                         dut.fl_count);
            // walker 回滚口 (定位 RAT 被写成非单射/池内重复的老 old)
            if (dut.flushing_r || dut.misp_valid)
                for (te = 0; te < ISSUE_WIDTH_TB; te = te + 1)
                    $display("   FLU[%0d] v=%b rd=%0d old=%0d widx=%0d fs=%0d wp=%0d rem=%0d",
                             te, dut.walk_flush_valid[te], dut.walk_flush_rd[te * 5 +: 5],
                             dut.walk_flush_old[te * PW_TB +: PW_TB],
                             dut.walk_idx_w[te * RW_TB +: RW_TB], dut.fs_eff_w,
                             dut.walk_ptr_r, dut.rem_w);
            $display("   MEM ldbusy=%b ldv=%b ldi=%0d lda=%h lsqh=%0d lsql=%0d",
                     dut.ld_busy, dut.ld_start_valid, dut.ld_start_idx, dut.ld_start_addr,
                     dut.u_lsq.head_r, dut.u_lsq.last_r);
            // 访存写口 (定位"执行了却没写进 lsq"的错位)
            $display("   SET ar=%b ai=%h av=%h | dr=%b di=%h dv=%h | pushv=%b robl=%0d nmem=%0d",
                     dut.set_addr_req, dut.set_addr_idx, dut.set_addr_val[31 : 0],
                     dut.set_data_req, dut.set_data_idx, dut.set_data_val[31 : 0],
                     dut.lsq_push_valid, dut.rob_last_w, dut.n_mem);
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
                      : (n == "add100")         ? 8'd186      // 官方 correctness_add_to_100: expected 5050, 取低 8 位
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
                u_mem.mem[mi] = 8'h00;          // 清零 (镜像只覆盖部分地址)
            $readmemh($sformatf("tb/top/prog/%0s.data", nm), u_mem.mem);
            rst_n = 1'b0;
            #1; #8; #1;
            rst_n = 1'b1;
            #1; #8; #1;
            cyc = 0;
            st_cyc = 0; st_iss = 0; st_flush = 0; st_nob = 0;
            st_rob = 0; st_rs = 0; st_fl = 0; st_lsq = 0; st_misp = 0;
            for (mi = 0; mi < 7; mi = mi + 1) begin
                kj[mi] = 0; mj[mi] = 0;
            end
            while (!dut.ret_latched_r && cyc < MAX_CYCLE
                   && ((perf_n == 0) || (cyc < perf_n))) begin
                #1; #8; #1;
                cyc = cyc + 1;
                if (dump_cyc > 0 && cyc == dump_cyc) $dumpoff;
                if ((cyc % 20000) == 0)
                    $display("   ... %0s cyc=%0d commit=%0d pc=%h robh=%0d robl=%0d empty=%b sp=%0d rdy=%b",
                             nm, cyc, commit_count, dut.u_fetch.pc_r,
                             dut.rob_head_w, dut.rob_last_w, dut.rob_empty,
                             dut.u_fl.sp, dut.rob_ready_w[dut.rob_head_w]);
            end
            if ((perf_n > 0) && !dut.ret_latched_r) begin
                // 性能模式: 只跑固定拍数, 报 IPC (提交数/拍); 不作对错判定
                // ipc 定点打印: 整数部分 + 千分位。不可写成 (commit*1000000)/cyc % 1000 ——
                // commit*1000000 在 32 位下回绕 (实测 basicopt1 打出 ipc=634.114 这种垃圾)。
                // 先取余: commit%cyc < cyc ≤ MAX_CYCLE=2e6, 再 *1000 = 2e9 < 2^31-1, 不溢出
                $display("PERF: %0s cycles=%0d commit=%0d ipc=%0d.%03d flush=%0d branch=%0d",
                         nm, cyc, commit_count,
                         commit_count / cyc,
                         ((commit_count % cyc) * 1000) / cyc,
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
            // 停滞归因: nobatch=取指没批 / flushcyc=冲刷拍 / block.*=有批但资源挡 (可重叠归因)
            $display("STALL: %0s cyc=%0d issue=%0d nobatch=%0d flushcyc=%0d misp=%0d | block rob=%0d rs=%0d fl=%0d lsq=%0d",
                     nm, st_cyc, st_iss, st_nob, st_flush, st_misp,
                     st_rob, st_rs, st_fl, st_lsq);
            $display("JUMP: %0s taken jal=%0d ret=%0d jalr=%0d beq=%0d bne=%0d bxx=%0d | misp jal=%0d ret=%0d jalr=%0d beq=%0d bne=%0d bxx=%0d",
                     nm, kj[0], kj[1], kj[2], kj[3], kj[4], kj[5],
                     mj[0], mj[1], mj[2], mj[3], mj[4], mj[5]);
            // 自由表分布 (诊断): 池内空闲 sp / 架构映射落在池区的个数 mapped_ge32。
            // 空机时 sp 恒为 FREE_NUM (架构映射全在恒等区 0..31) —— 恒等区被放弃时也会回池, 不再是泄漏
            nh = 0;
            for (fi = 0; fi < 32; fi = fi + 1)
                if (dut.map_arch[fi * PW_TB +: PW_TB] >= 32) nh = nh + 1;
            $display("FREELIST: %0s sp=%0d FREE_NUM=%0d mapped_ge32=%0d rob_empty=%b",
                     nm, dut.u_fl.sp, PRF_SIZE_TB - 32, nh, dut.rob_empty);
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
        if (!$value$plusargs("FROM=%d", trace_from)) trace_from = 0;
        if (!$value$plusargs("PERF=%d", perf_n))    perf_n    = 0;
        if (!$value$plusargs("BAD=%h", bad_pc))     bad_pc    = 0;
        if (!$value$plusargs("FLCHK=%d", flchk))    flchk     = 0;
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
