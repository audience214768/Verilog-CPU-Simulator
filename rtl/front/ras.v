// 返回地址栈: 深度 RAS_SIZE, call push / ret pop, 误预测恢复 head
// top[i]/head_snap[i] = 处理 ops[0..i-1] 后的栈顶/head (W 路顺序组合链)
module ras #(
    parameter ISSUE_WIDTH = 1,
    parameter RAS_SIZE    = 8
) (
    output [ISSUE_WIDTH * 32 - 1 : 0] top,          // top[i] = 处理 ops[0..i-1] 后栈顶 (ret 预测目标)
    output [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0] head_snap,    // head_snap[i] = 处理 ops[0..i-1] 后 head (误预测恢复)
    input  [ISSUE_WIDTH * 2 - 1 : 0]  ops,          // 槽 i: 0=无 1=push 2=pop
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_val,     // 槽 i: push 值 (pc+4)
    input                       restore_valid,// 误预测恢复 (优先级 > fetch ops)
    input  [$clog2(RAS_SIZE) - 1 : 0]             restore_head
);
    localparam RA = $clog2(RAS_SIZE);
    // TODO(Phase B): 栈数组 + head 寄存器; 空栈 pop 忽略, 满栈 push 丢弃
    assign top       = {ISSUE_WIDTH * 32{1'b0}};
    assign head_snap = {ISSUE_WIDTH * $clog2(RAS_SIZE){1'b0}};
endmodule
