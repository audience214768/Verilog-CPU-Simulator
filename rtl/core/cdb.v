// 公共数据总线: 纯组合写回扇出 — PRF 写回 / ready_table 置位 / ROB ready 置位
// 槽 0..W-1 = 执行 (cdb 无寄存器: 当拍旁路 + 当拍 posedge 写回), 槽 W = load 完成
// prd==0 的槽不写 PRF 不置 ready; rob_wr 槽按 rob_tag 置 ROB ready
module cdb #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64,
    parameter ROB_SIZE    = 32
) (
    // 生产者 A: 执行槽 (W 个)
    input  [ISSUE_WIDTH - 1 : 0]    exec_valid,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] exec_prd,
    input  [ISSUE_WIDTH * 32 - 1 : 0] exec_result,
    input  [ISSUE_WIDTH * $clog2(ROB_SIZE) - 1 : 0] exec_rob_tag,
    input  [ISSUE_WIDTH - 1 : 0]    exec_rob_wr,
    // 生产者 B: load 完成 (每周期 ≤1)
    input               load_valid,
    input  [$clog2(PRF_SIZE) - 1 : 0]     load_prd,
    input  [31 : 0]       load_result,
    input  [$clog2(ROB_SIZE) - 1 : 0]     load_rob_tag,
    input               load_rob_wr,
    // 汇出: PRF 写回
    output [ISSUE_WIDTH : 0]          prf_valid,
    output [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] prf_preg,
    output [(ISSUE_WIDTH + 1) * 32 - 1 : 0] prf_data,
    // 汇出: ready_table 置位掩码
    output [PRF_SIZE - 1 : 0] rt_set_req,
    // 汇出: ROB ready 置位掩码
    output [ROB_SIZE - 1 : 0] rob_ready_req
);
    localparam PW = $clog2(PRF_SIZE);
    localparam RW = $clog2(ROB_SIZE);
    // TODO(Phase B): 全部 assign (逐槽/逐位)
    assign prf_valid    = {(ISSUE_WIDTH + 1){1'b0}};
    assign prf_preg     = {(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE){1'b0}};
    assign prf_data     = {(ISSUE_WIDTH + 1) * 32{1'b0}};
    assign rt_set_req   = {PRF_SIZE{1'b0}};
    assign rob_ready_req = {ROB_SIZE{1'b0}};
endmodule
