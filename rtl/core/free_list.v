// 空闲物理寄存器表: 复位 head=32, count=PRF_SIZE-32 (phys 0..31 被 RAT 恒等映射占用)
// alloc_val[i] 组合 = (head+i) 环形 (回绕到 32, 绝不分配 preg 0..31)
// 优先级: push (commit/walker 回收) > pop (同拍先回收后分配, count 先加后减)
// count_out = 当前空闲 + 本拍 push 数 (供 issue 判断本拍可分配量)
module free_list #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] alloc_val,      // 组合分配值 (仅在 count 足够时有意义)
    output [$clog2(PRF_SIZE + 1) - 1 : 0]            count_out,      // 当前空闲 + 本拍 push 数 (issue 判断)
    input  [ISSUE_WIDTH - 1 : 0]    pop_req,        // 弹出 (prefix)
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,     // 回收 (commit 与 walker 复用, 二者互斥)
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_preg
);
    localparam PW  = $clog2(PRF_SIZE);
    localparam PCW = $clog2(PRF_SIZE + 1);
    localparam FREE_NUM = PRF_SIZE - 32;            // 可分配区大小 (2 的幂)
    localparam BASE = 6'd32;                        // 可分配区下界

    reg [PW - 1 : 0]  head;
    reg [PCW - 1 : 0] count;

    // ---- pop/push 计数 (逐槽加法链) ----
    wire [ISSUE_WIDTH * PCW - 1 : 0] pc_sum, ps_sum;
    genvar c;
    generate
        for (c = 0; c < ISSUE_WIDTH; c = c + 1) begin : cnt
            if (c == 0) begin : b0
                assign pc_sum[0 * PCW +: PCW] = {{(PCW - 1){1'b0}}, pop_req[0]};
                assign ps_sum[0 * PCW +: PCW] = {{(PCW - 1){1'b0}}, push_valid[0]};
            end else begin : bn
                assign pc_sum[c * PCW +: PCW] = pc_sum[(c - 1) * PCW +: PCW]
                                              + {{(PCW - 1){1'b0}}, pop_req[c]};
                assign ps_sum[c * PCW +: PCW] = ps_sum[(c - 1) * PCW +: PCW]
                                              + {{(PCW - 1){1'b0}}, push_valid[c]};
            end
        end
    endgenerate
    wire [PCW - 1 : 0] pop_cnt  = pc_sum[(ISSUE_WIDTH - 1) * PCW +: PCW];
    wire [PCW - 1 : 0] push_cnt = ps_sum[(ISSUE_WIDTH - 1) * PCW +: PCW];

    // ---- alloc_val: (head+i) 环形 (超出 PRF_SIZE 回绕到 32) ----
    genvar i;
    generate
        for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin : al
            assign alloc_val[i * PW +: PW] = ((head + i) >= PRF_SIZE)
                                           ? (head + i - FREE_NUM) : (head + i);
        end
    endgenerate

    assign count_out = count + push_cnt;            // 本拍可分配量 (push 先入队)

    // ---- 时序: push > pop, 环形 head ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head  <= BASE;
            count <= FREE_NUM;
        end else begin
            head  <= ((head + pop_cnt) >= PRF_SIZE) ? (head + pop_cnt - FREE_NUM) : (head + pop_cnt);
            count <= count - pop_cnt + push_cnt;
        end
    end
endmodule
