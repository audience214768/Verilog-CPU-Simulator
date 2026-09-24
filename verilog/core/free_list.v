// 空闲物理寄存器池: LIFO 栈 (FREE_NUM 项 × PW 位真实存储)
// 复位 sp=FREE_NUM, 栈顶 pool[FREE_NUM-1]=BASE → 首次分配得 preg 32, 依次递增
// 只回收 preg >= BASE (32): RAT 复位恒等映射占用 0..31, 被覆盖即永久退休, 池中无法表示,
//   计入 count 会使计数虚高 → 头指针绕圈时会分配出仍在使用的 preg (旧实现缺陷)
// 存真实值而非"head+i 组合计算": 回收 (commit 的 old_pnum / walker 的 new_pnum) 不按分配序
//   到达 (同批内不同 rd 的 old 次序任意), 空闲集不是环形连续区间 → 组合计算会算错
// 同拍 push/pop: pop 读 pool[sp-1-pc_pre[i]], push 写 pool[sp-pop_cnt+ps_pre[i]] ——
//   push 正好落在本拍 pop 腾出的槽位 (组合读先于边沿写, 读到的是旧值, 不冲突);
//   本拍 push 的项本拍不可分配 (无旁路) → count_out = sp
module free_list #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] alloc_val,      // 槽 i: 栈顶起第 pc_pre[i] 个 (仅 pop_req[i] 时有效)
    output [$clog2(PRF_SIZE + 1) - 1 : 0]            count_out,      // 本拍可分配量 (= 栈内空闲数)
    input  [ISSUE_WIDTH - 1 : 0]    pop_req,        // 弹出 (逐槽; 同拍多槽按槽序取栈顶起连续项)
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,     // 回收 (commit 与 walker 复用, 二者互斥)
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_preg
);
    localparam PW  = $clog2(PRF_SIZE);
    localparam PCW = $clog2(PRF_SIZE + 1);
    localparam BASE     = 32;                 // 恒等映射区上界 (preg 0..31 永不复用)
    localparam FREE_NUM = PRF_SIZE - BASE;    // 池容量

    reg [PW - 1 : 0]  pool [0 : FREE_NUM - 1];
    reg [PCW - 1 : 0] sp;                     // 栈内空闲数 (= 栈顶下标 + 1)

    // ---- 有效回收 (仅可分配区) + 逐槽前缀计数 ----
    wire [ISSUE_WIDTH - 1 : 0] push_ok;
    wire [ISSUE_WIDTH * PCW - 1 : 0] pc_pre, ps_pre;   // 槽 i 之前的 pop/push 数 (排他前缀)
    wire [ISSUE_WIDTH * PCW - 1 : 0] pc_inc, ps_inc;   // 含槽 i 的累计
    genvar i, c;
    generate
        for (c = 0; c < ISSUE_WIDTH; c = c + 1) begin : ok
            assign push_ok[c] = push_valid[c] && (push_preg[c * PW +: PW] >= BASE);
        end
        for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin : cnt
            // 槽 i 之前 = 前一槽的含己累计
            wire [PCW - 1 : 0] pc_pv = (i == 0) ? {PCW{1'b0}} : pc_inc[(i - 1) * PCW +: PCW];
            wire [PCW - 1 : 0] ps_pv = (i == 0) ? {PCW{1'b0}} : ps_inc[(i - 1) * PCW +: PCW];
            assign pc_pre[i * PCW +: PCW] = pc_pv;
            assign ps_pre[i * PCW +: PCW] = ps_pv;
            assign pc_inc[i * PCW +: PCW] = pc_pv + {{(PCW - 1){1'b0}}, pop_req[i]};
            assign ps_inc[i * PCW +: PCW] = ps_pv + {{(PCW - 1){1'b0}}, push_ok[i]};
            assign alloc_val[i * PW +: PW] = pool[sp - 1'b1 - pc_pv];
        end
    endgenerate
    wire [PCW - 1 : 0] pop_cnt  = pc_inc[(ISSUE_WIDTH - 1) * PCW +: PCW];
    wire [PCW - 1 : 0] push_cnt = ps_inc[(ISSUE_WIDTH - 1) * PCW +: PCW];

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
            for (k = 0; k < ISSUE_WIDTH; k = k + 1)
                if (push_ok[k])
                    pool[sp - pop_cnt + ps_pre[k * PCW +: PCW]] <= push_preg[k * PW +: PW];
        end
    end
endmodule
