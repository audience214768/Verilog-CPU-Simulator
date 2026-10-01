// 空闲物理寄存器池: LIFO 栈 (FREE_NUM 项 × PW 位真实存储)
// 复位 sp=FREE_NUM, 栈顶 pool[FREE_NUM-1]=BASE → 首次分配得 preg 32, 依次递增
// 只挡 preg 0 (x0 的恒等映射, 永不复用): 恒等映射区 1..31 在被架构 RAT 放弃 (提交改写) 时
//   照常回池 —— 池是真实栈, 能表示任何 preg; 详见下方 push_ok 处的缺陷 8 说明
// 存真实值而非"head+i 组合计算": 回收 (commit 的 old_pnum / walker 的 new_pnum) 不按分配序
//   到达 (同批内不同 rd 的 old 次序任意), 空闲集不是环形连续区间 → 组合计算会算错
// 同拍 push/pop: pop 读 pool[sp-1-pc_pre[i]], push 写 pool[sp-pop_cnt+ps_pre[i]] ——
//   push 正好落在本拍 pop 腾出的槽位 (组合读先于边沿写, 读到的是旧值, 不冲突);
//   本拍 push 的项本拍不可分配 (无旁路) → count_out = sp
module free_list #(
    parameter ISSUE_WIDTH    = 1,
    parameter PRF_SIZE       = 64,
    parameter ROLLBACK_WIDTH = 1
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] alloc_val,      // 槽 i: 栈顶起第 pc_pre[i] 个 (仅 pop_req[i] 时有效)
    output [$clog2(PRF_SIZE + 1) - 1 : 0]            count_out,      // 本拍可分配量 (= 栈内空闲数)
    input  [ISSUE_WIDTH - 1 : 0]    pop_req,        // 弹出 (逐槽; 同拍多槽按槽序取栈顶起连续项)
    input  [ROLLBACK_WIDTH - 1 : 0]    push_valid,     // 回收 (commit 与 walker 复用, 二者互斥)
    input  [ROLLBACK_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_preg
);
    localparam PW  = $clog2(PRF_SIZE);
    localparam PCW = $clog2(PRF_SIZE + 1);
    localparam BASE     = 32;                 // 恒等映射区上界 (preg 0..31 永不复用)
    localparam FREE_NUM = PRF_SIZE - BASE;    // 池容量

    reg [PW - 1 : 0]  pool [0 : FREE_NUM - 1];
    reg [PCW - 1 : 0] sp;                     // 栈内空闲数 (= 栈顶下标 + 1)

    // ---- 有效回收 + 逐槽前缀计数 ----
    // ★ 2026-09-28 (W=4 缺陷 8): 原来只回收 preg >= BASE(32), 整个恒等映射区 0..31 被排除,
    //   理由是"复位恒等映射占用它, 被覆盖即永久退休, 池中无法表示"。但本实现是**真实栈**
    //   (pool[] 存真值, 不靠 head+i 组合计算), 任何 preg 都能表示 ⇒ 该排除纯属浪费:
    //   架构 RAT 每把一个寄存器改写到池 preg 上, 就永久占住池里一项, 32 项池最多只剩 1 项。
    //   实测 (官方 correctness_hanoi, W=4): map_arch 占 29 项 ⇒ sp=3, 而冻结处批
    //   {addi a5,s0,0 / addi a5,a5,-1 / addi a0,a5,0 / addi s1,a1,0} 是 4 条全写 rd ⇒
    //   fl_count(3) < n_wr(4) 恒成立, ROB 已空、pc 冻结在 0x190 ⇒ 永久死锁。
    //   (W<=3 时 n_wr<=3 恰好不超过 3, 侥幸不触发 —— 幸存者偏差, 不是正确性。)
    //   改法: 只挡 preg 0 (x0 的恒等映射, 永不复用) —— walker 侧 walked_valid 不排除
    //   new_pnum==0 的条目 (cpu_top 的 fl_push_valid 直接用 walked_valid), 必须留这一挡,
    //   否则 preg 0 进池后被分配出去, x0 不再恒为 0。其余 1..31 在架构映射放弃它时照常回池,
    //   空机时池恒为 PRF_SIZE - 32 = 32 项 >= ISSUE_WIDTH ⇒ 结构性死锁消失。
    // push 端口按 ROLLBACK_WIDTH 定宽 (walker 与 commit 复用, 二者互斥), pop 仍是 ISSUE_WIDTH
    wire [ROLLBACK_WIDTH - 1 : 0] push_ok;
    wire [ISSUE_WIDTH * PCW - 1 : 0] pc_pre, pc_inc;   // pop 前缀 (发射宽度)
    wire [ROLLBACK_WIDTH * PCW - 1 : 0] ps_pre, ps_inc; // push 前缀 (回滚宽度)
    genvar i, c;
    generate
        for (c = 0; c < ROLLBACK_WIDTH; c = c + 1) begin : ok
            assign push_ok[c] = push_valid[c] && (push_preg[c * PW +: PW] != {PW{1'b0}});
        end
        // pop 计数链: 只到 ISSUE_WIDTH
        for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin : cnt
            wire [PCW - 1 : 0] pc_pv = (i == 0) ? {PCW{1'b0}} : pc_inc[(i - 1) * PCW +: PCW];
            assign pc_pre[i * PCW +: PCW] = pc_pv;
            assign pc_inc[i * PCW +: PCW] = pc_pv + {{(PCW - 1){1'b0}}, pop_req[i]};
            assign alloc_val[i * PW +: PW] = pool[sp - 1'b1 - pc_pv];
        end
        // push 计数链: 到 ROLLBACK_WIDTH (walker 一拍可归还的项数)
        for (i = 0; i < ROLLBACK_WIDTH; i = i + 1) begin : pcnt
            wire [PCW - 1 : 0] ps_pv = (i == 0) ? {PCW{1'b0}} : ps_inc[(i - 1) * PCW +: PCW];
            assign ps_pre[i * PCW +: PCW] = ps_pv;
            assign ps_inc[i * PCW +: PCW] = ps_pv + {{(PCW - 1){1'b0}}, push_ok[i]};
        end
    endgenerate
    wire [PCW - 1 : 0] pop_cnt  = pc_inc[(ISSUE_WIDTH - 1) * PCW +: PCW];
    wire [PCW - 1 : 0] push_cnt = ps_inc[(ROLLBACK_WIDTH - 1) * PCW +: PCW];

    assign count_out = sp;

    // ---- 时序: pop 从栈顶取下, push 写到本拍 pop 腾出的槽位 ----
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            sp <= FREE_NUM[PCW - 1 : 0];
            for (k = 0; k < FREE_NUM; k = k + 1)
                pool[k] <= BASE + (FREE_NUM - 1 - k);
        end else begin
            sp <= sp - pop_cnt + push_cnt;
            for (k = 0; k < ROLLBACK_WIDTH; k = k + 1)
                if (push_ok[k])
                    pool[sp - pop_cnt + ps_pre[k * PCW +: PCW]] <= push_preg[k * PW +: PW];
        end
    end
endmodule
