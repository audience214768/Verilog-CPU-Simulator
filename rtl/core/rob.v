// 重排序缓冲: 环形 (ROB_SIZE = 2^$clog2(ROB_SIZE)), 乱序完成按序提交
// 写优先级: set_last (flush 截断, 最高; head 若在窗口内收敛) > set_head (提交) > set_ready (CDB) > push
module rob #(
    parameter ISSUE_WIDTH = 1,
    parameter ROB_SIZE    = 32,
    parameter PRF_SIZE    = 64,
    parameter LSQ_SIZE    = 16
) (
    // A: 指针/状态
    output [$clog2(ROB_SIZE) - 1 : 0]     head, last,
    output              empty, full,
    output [$clog2(ROB_SIZE + 1) - 1 : 0]    free_count,     // 当前空闲 (本拍提交数由 cpu_top 另行相加)
    // A: 条目数组 (commit/walker 用)
    output [ROB_SIZE - 1 : 0]       ready,          // 完成位 (唯一写者: set_ready_req)
    output [ROB_SIZE * 7 - 1 : 0]     opcode,         // 原始 opcode[6:0] (commit 分派)
    output [ROB_SIZE * 5 - 1 : 0]     rd,
    output [ROB_SIZE * $clog2(PRF_SIZE) - 1 : 0]    new_pnum,       // 目的 preg; ==0 ⟺ 无 prd
    output [ROB_SIZE * $clog2(PRF_SIZE) - 1 : 0]    old_pnum,       // rename 前映射 (commit 回收/walker 回滚)
    output [ROB_SIZE * $clog2(LSQ_SIZE) - 1 : 0]    lsq_tag,        // store/load 的 LSQ 条目号
    output [ROB_SIZE * 32 - 1 : 0]    ins_raw,        // 终止标记检测
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_opcode,
    input  [ISSUE_WIDTH * 5 - 1 : 0]  push_rd,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_new, push_old,
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] push_lsq_tag,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_ins_raw,
    input               set_head_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]     set_head_val,
    input               set_last_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]     set_last_val,
    input  [ROB_SIZE - 1 : 0] set_ready_req
);
    localparam RW  = $clog2(ROB_SIZE);
    localparam PW  = $clog2(PRF_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam RCW = $clog2(ROB_SIZE + 1);
    // TODO(Phase B): 环形指针 + 数组
    assign head       = {$clog2(ROB_SIZE){1'b0}};
    assign last       = {$clog2(ROB_SIZE){1'b0}};
    assign empty      = 1'b0;
    assign full       = 1'b0;
    assign free_count = {$clog2(ROB_SIZE + 1){1'b0}};
    assign ready      = {ROB_SIZE{1'b0}};
    assign opcode     = {ROB_SIZE * 7{1'b0}};
    assign rd         = {ROB_SIZE * 5{1'b0}};
    assign new_pnum   = {ROB_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign old_pnum   = {ROB_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign lsq_tag    = {ROB_SIZE * $clog2(LSQ_SIZE){1'b0}};
    assign ins_raw    = {ROB_SIZE * 32{1'b0}};
endmodule
