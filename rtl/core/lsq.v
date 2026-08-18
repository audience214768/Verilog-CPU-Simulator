// 装载/存储队列: 发射建条目, 执行写 addr/data, load 发起需所有更老 store 已执行,
// 完成时字节合并前向 (store 前向), 提交时 store 直写主存 / 条目失效
// 写优先级: flush > invalidate(commit) > push > set_*
module lsq #(
    parameter ISSUE_WIDTH = 1,
    parameter LSQ_SIZE    = 16,
    parameter PRF_SIZE    = 64,
    parameter ROB_SIZE    = 32
) (
    // A: 指针/状态
    output [$clog2(LSQ_SIZE) - 1 : 0]     head, last,
    output              full,
    output [$clog2(LSQ_SIZE + 1) - 1 : 0]    free_count,     // 当前空闲 (本拍失效数由 cpu_top 相加)
    output [LSQ_SIZE - 1 : 0] valid, is_load, addr_ready, data_ready,
    // A: 内容 (commit 读 store 数据)
    output [LSQ_SIZE * 32 - 1 : 0] addr, data,
    output [LSQ_SIZE * $clog2(ROB_SIZE) - 1 : 0] rob_tag,
    output [LSQ_SIZE * $clog2(PRF_SIZE) - 1 : 0] prs2_or_prd,   // store: rs2 的 preg; load: 目的 preg
    output [LSQ_SIZE * 2 - 1 : 0]  width,         // 1/2/4 字节
    output [LSQ_SIZE - 1 : 0]    is_unsigned,
    // C: 年龄比较
    input  [$clog2(ROB_SIZE) - 1 : 0]     rob_head,
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * $clog2(ROB_SIZE) - 1 : 0] push_rob_tag,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_prs2_or_prd,
    input  [ISSUE_WIDTH * 2 - 1 : 0]  push_width,
    input  [ISSUE_WIDTH - 1 : 0]    push_is_unsigned, push_is_load,
    input  [ISSUE_WIDTH - 1 : 0]    set_addr_req,   // 执行槽 i (地址 = alu 结果)
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] set_addr_idx,   // 槽 i 的 lsq_tag
    input  [ISSUE_WIDTH * 32 - 1 : 0] set_addr_val,
    input  [ISSUE_WIDTH - 1 : 0]    set_data_req,   // 仅 store
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] set_data_idx,
    input  [ISSUE_WIDTH * 32 - 1 : 0] set_data_val,
    input  [LSQ_SIZE - 1 : 0]       flush_mask,     // 窗口内条目失效
    input  [LSQ_SIZE - 1 : 0]       invalidate,     // store/load 提交后失效
    // 内存接口
    input               mem_done_valid,
    input  [$clog2(LSQ_SIZE) - 1 : 0]     mem_done_idx,
    input  [31 : 0]       mem_done_data,
    output              ld_start_valid,     // 组合发起: 最老未完成 load + 更老 store 全执行 + 有空槽
    output [31 : 0]       ld_start_addr,
    output [1 : 0]        ld_start_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]     ld_start_idx,
    input               ld_busy,            // memory 飞行槽满
    // 汇出: load 完成 → CDB 槽 W
    output              load_cdb_valid,
    output [$clog2(PRF_SIZE) - 1 : 0]     load_cdb_prd,
    output [31 : 0]       load_cdb_result,
    output [$clog2(ROB_SIZE) - 1 : 0]     load_cdb_rob_tag,
    output              load_cdb_rob_wr
);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam LCW = $clog2(LSQ_SIZE + 1);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);
    // TODO(Phase B): 条目数组 + 发起/完成/字节合并/前向 + head 推进跳过失效
    assign head      = {$clog2(LSQ_SIZE){1'b0}};
    assign last      = {$clog2(LSQ_SIZE){1'b0}};
    assign full      = 1'b0;
    assign free_count = {$clog2(LSQ_SIZE + 1){1'b0}};
    assign valid      = {LSQ_SIZE{1'b0}};
    assign is_load    = {LSQ_SIZE{1'b0}};
    assign addr_ready = {LSQ_SIZE{1'b0}};
    assign data_ready = {LSQ_SIZE{1'b0}};
    assign addr       = {LSQ_SIZE * 32{1'b0}};
    assign data       = {LSQ_SIZE * 32{1'b0}};
    assign rob_tag    = {LSQ_SIZE * $clog2(ROB_SIZE){1'b0}};
    assign prs2_or_prd = {LSQ_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign width      = {LSQ_SIZE * 2{1'b0}};
    assign is_unsigned = {LSQ_SIZE{1'b0}};
    assign ld_start_valid = 1'b0;
    assign ld_start_addr  = 32'd0;
    assign ld_start_width = 2'd0;
    assign ld_start_idx   = {$clog2(LSQ_SIZE){1'b0}};
    assign load_cdb_valid  = 1'b0;
    assign load_cdb_prd    = {$clog2(PRF_SIZE){1'b0}};
    assign load_cdb_result = 32'd0;
    assign load_cdb_rob_tag = {$clog2(ROB_SIZE){1'b0}};
    assign load_cdb_rob_wr  = 1'b0;
endmodule
