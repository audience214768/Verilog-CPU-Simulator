// 返回地址栈: call push / ret pop, 误预测恢复 head
// top[i]      = 处理 ops[0..i-1] 后的栈顶 (ret 的预测目标: 必须在该槽 ops **之前**)
// head_snap[i]= 处理 ops[0..i]   后的 head  (误预测恢复载荷: 必须**含**该槽自己的 ops, 见下)
// 空栈 pop 忽略, 满栈 push 丢弃; restore 优先级 > 本拍 ops (posedge 应用)
// 深度: head 只有 RA=$clog2(RAS_SIZE) 位 (head_snap 要原样喂给恢复通路, 宽度必须能表示),
//       故满栈判定为 head == RAS_SIZE-1 → 有效深度 RAS_SIZE-1 条
module ras #(
    parameter ISSUE_WIDTH = 1,
    parameter RAS_SIZE    = 8
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * 32 - 1 : 0] top,          // top[i] = 处理 ops[0..i-1] 后栈顶 (ret 预测目标)
    output [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0] head_snap,    // head_snap[i] = 处理 ops[0..i-1] 后 head
    input  [ISSUE_WIDTH * 2 - 1 : 0]  ops,          // 槽 i: 0=无 1=push 2=pop
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_val,     // 槽 i: push 值 (pc+4)
    input                       restore_valid,     // 误预测恢复 (优先级 > fetch ops)
    input  [$clog2(RAS_SIZE) - 1 : 0]             restore_head
);
    localparam RA = $clog2(RAS_SIZE);
    localparam [RA : 0] FULL_H = RAS_SIZE - 1;      // 满栈时的 head

    reg [31 : 0]   stack [0 : RAS_SIZE - 1];
    reg [RA - 1 : 0] head_r;

    // 组合链: h[i] = 处理 ops[0..i-1] 后 head (RA+1 位防溢出)
    wire [(ISSUE_WIDTH + 1) * (RA + 1) - 1 : 0] h;
    wire [ISSUE_WIDTH - 1 : 0]                   push_ok;
    genvar gi;
    generate
        assign h[0 * (RA + 1) +: (RA + 1)] = {1'b0, head_r};
        for (gi = 0; gi < ISSUE_WIDTH; gi = gi + 1) begin : ch
            wire [RA : 0] hprev = h[gi * (RA + 1) +: (RA + 1)];
            wire          is_push = (ops[gi * 2 +: 2] == 2'd1);
            wire          is_pop  = (ops[gi * 2 +: 2] == 2'd2);
            assign push_ok[gi] = is_push && (hprev != FULL_H);
            wire pop_ok = is_pop && (hprev != {RA + 1{1'b0}});
            assign h[(gi + 1) * (RA + 1) +: (RA + 1)]
                 = push_ok[gi] ? (hprev + 1'b1)
                 : pop_ok      ? (hprev - 1'b1)
                 : hprev;
        end
    endgenerate
    // top[i] = ops[i] 处理前栈顶: h==0 (空) → 0
    // head_snap[i] = ops[i] 处理 **后** 的 head (h[i+1]): 误预测时重定向去的是该指令的**目标**,
    //   它自己不重新取指 ⇒ 恢复值必须保留它自己的 push/pop。用 h[i] (ops 之前) 会把它自己的
    //   操作撤销 —— 而 jalr 调用 (auipc+jalr) 取指时不可预测目标, 必定误预测一次, 于是每次
    //   调用的 push 都被自己的误预测撤销, RAS 恒空 (2026-10-02 实测: 只改 is_call 时六案周期
    //   逐位不变)。分支槽无 ops, h[i+1] == h[i], 故原语义对分支不变。
    genvar go;
    generate
        for (go = 0; go < ISSUE_WIDTH; go = go + 1) begin : out
            wire [RA : 0] hcur = h[go * (RA + 1) +: (RA + 1)];
            assign top[go * 32 +: 32] = (hcur == {RA + 1{1'b0}}) ? 32'd0
                                      : stack[hcur[RA - 1 : 0] - 1'b1];
            assign head_snap[go * RA +: RA] = h[(go + 1) * (RA + 1) +: RA];
        end
    endgenerate

    // posedge: restore > ops 应用 (push 写栈 + head 更新; pop 只动 head)
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            head_r <= {RA{1'b0}};
            // 栈内容一并复位: head 被 restore 到一个尚未 push 过的位置时 (误预测恢复),
            // 若栈未初始化会读出 X/垃圾目标 → 复位为 0 (与空栈预测 0 一致)
            for (i = 0; i < RAS_SIZE; i = i + 1)
                stack[i] <= 32'd0;
        end else if (restore_valid) begin
            head_r <= restore_head;
        end else begin
            for (i = 0; i < ISSUE_WIDTH; i = i + 1)
                if (push_ok[i])
                    stack[h[i * (RA + 1) +: RA]] <= push_val[i * 32 +: 32];
            head_r <= h[ISSUE_WIDTH * (RA + 1) +: RA];
        end
    end
endmodule
