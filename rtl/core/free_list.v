// 空闲物理寄存器表: 复位 {32..PRF_SIZE-1} (phys 0..31 被 RAT 恒等映射占用)
// alloc_val[i] 组合 = head 起连续第 i 个空闲 (回绕到 32, 绝不分配 preg 0)
// 优先级: push (commit/walker 回收) > pop
module free_list #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] alloc_val,      // 组合分配值 (仅在 count 足够时有意义)
    output [$clog2(PRF_SIZE + 1) - 1 : 0]            count_out,      // 当前空闲 + 本拍 push 数 (issue 判断)
    input  [ISSUE_WIDTH - 1 : 0]    pop_req,        // 弹出 (prefix)
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,     // 回收 (commit 与 walker 复用, 二者互斥)
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_preg
);
    localparam PW  = $clog2(PRF_SIZE);
    localparam PCW = $clog2(PRF_SIZE + 1);
    // TODO(Phase B): head/count 寄存器, 环形 (范围 32..PRF_SIZE-1)
    assign alloc_val = {ISSUE_WIDTH * $clog2(PRF_SIZE){1'b0}};
    assign count_out = {$clog2(PRF_SIZE + 1){1'b0}};
endmodule
