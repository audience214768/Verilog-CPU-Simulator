// 取指: PC → imem (同步读 1 拍) → 寄存批 f2i_*; BHT/JAL/RAS 预测随指令流动
// 内部实例化 bht + ras; 每批 RAS 操作在取指时一次性应用 (stall 保持批不重复应用)
// stall 保持 PC 与输出; redirect 清空当前批并改 PC; halt 停止取指
module fetch #(
    parameter ISSUE_WIDTH = 1,
    parameter BHT_SIZE    = 32,
    parameter RAS_SIZE    = 8
) (
    // A: 到 decode/issue (寄存; stall 保持; redirect 清 0)
    output [ISSUE_WIDTH - 1 : 0]     f2i_valid,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_raw,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_pc,
    output [ISSUE_WIDTH - 1 : 0]     f2i_pred_taken,
    output [ISSUE_WIDTH * 32 - 1 : 0]  f2i_pred_target,
    output [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0]  f2i_ras_snap,   // 取指时 ras head (仅 branch/jalr 有意义)
    output [ISSUE_WIDTH * 32 - 1 : 0]  imem_addr,      // 到 memory 的取指地址 (pc+4i)
    // B: 输入 (透传内部 bht/ras)
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_req,    // 执行槽 i: 条件分支更新 (透传 bht)
    input  [ISSUE_WIDTH * $clog2(BHT_SIZE) - 1 : 0]  bht_upd_idx,    // 执行槽 i: 索引 (pc>>2)%BHT_SIZE
    input  [ISSUE_WIDTH - 1 : 0]     bht_upd_taken,  // 执行槽 i: 实际方向
    input                        ras_restore_valid,  // 误预测 head 恢复 (透传 ras)
    input  [$clog2(RAS_SIZE) - 1 : 0]              ras_restore_head,
    input  [ISSUE_WIDTH * 32 - 1 : 0] inst_data,       // memory 同步读 (1 拍延迟)
    input                 stall,                 // 保持 PC 与输出
    input                 redirect_valid,
    input  [31 : 0]         redirect_pc,
    input                 halt
);
    localparam RA = $clog2(RAS_SIZE);
    localparam BW = $clog2(BHT_SIZE);
    // TODO(Phase B): PC 寄存器 + bht/ras 实例 + 预测组合 + 批寄存器
    assign f2i_valid      = {ISSUE_WIDTH{1'b0}};
    assign f2i_raw        = {ISSUE_WIDTH * 32{1'b0}};
    assign f2i_pc         = {ISSUE_WIDTH * 32{1'b0}};
    assign f2i_pred_taken = {ISSUE_WIDTH{1'b0}};
    assign f2i_pred_target= {ISSUE_WIDTH * 32{1'b0}};
    assign f2i_ras_snap   = {ISSUE_WIDTH * $clog2(RAS_SIZE){1'b0}};
    assign imem_addr      = {ISSUE_WIDTH * 32{1'b0}};
endmodule
