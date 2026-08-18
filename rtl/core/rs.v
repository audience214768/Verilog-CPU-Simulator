// 保留站: 状态式 (只存 preg 号 + 译码字段, 不存操作数值)
// 每周期 W 级年龄优先仲裁 (年龄 = (rob_tag - rob_head) 无符号回绕, 槽间互斥, 同年龄低槽赢)
// 就绪 = prs==0 || CDB 标签命中 || rt_ready[prs]; 选中条目自清 (同拍执行广播)
// 写优先级: flush_mask > 自清(选中) > push
module rs #(
    parameter ISSUE_WIDTH = 1,
    parameter RS_SIZE     = 16,
    parameter PRF_SIZE    = 64,
    parameter ROB_SIZE    = 32,
    parameter LSQ_SIZE    = 16,
    parameter BHT_SIZE    = 32,
    parameter RAS_SIZE    = 8
) (
    // A: 选择结果 (组合, 年龄优先, 槽 0 最老)
    output [ISSUE_WIDTH - 1 : 0]     sel_valid,
    output [ISSUE_WIDTH * $clog2(RS_SIZE) - 1 : 0] sel_idx,
    output [$clog2(RS_SIZE + 1) - 1 : 0]             free_count,   // 当前空槽 (本拍选中数由 cpu_top 相加)
    // A: 条目字段 (cpu_top 按 sel_idx 取)
    output [RS_SIZE - 1 : 0]        entry_valid,
    output [RS_SIZE * 7 - 1 : 0]      entry_opcode,
    output [RS_SIZE * 3 - 1 : 0]      entry_func3,
    output [RS_SIZE * 7 - 1 : 0]      entry_func7,
    output [RS_SIZE * $clog2(PRF_SIZE) - 1 : 0]     entry_prs1, entry_prs2, entry_prd,
    output [RS_SIZE * 32 - 1 : 0]     entry_pc, entry_imm,
    output [RS_SIZE * $clog2(LSQ_SIZE) - 1 : 0]     entry_lsq_tag,
    output [RS_SIZE * $clog2(ROB_SIZE) - 1 : 0]     entry_rob_tag,
    output [RS_SIZE - 1 : 0]        entry_pred_taken,
    output [RS_SIZE * 32 - 1 : 0]     entry_pred_target,
    output [RS_SIZE * $clog2(RAS_SIZE) - 1 : 0]     entry_ras_snap,
    // C: 就绪判断输入
    input  [PRF_SIZE - 1 : 0]       rt_ready,
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] cdb_tag,        // 槽 0..W-1 执行, 槽 W load
    input  [ISSUE_WIDTH : 0]      cdb_slot_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]             rob_head,           // 年龄比较
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_opcode,
    input  [ISSUE_WIDTH * 3 - 1 : 0]  push_func3,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_func7,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_prs1, push_prs2, push_prd,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_pc, push_imm,
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] push_lsq_tag,
    input  [ISSUE_WIDTH * $clog2(ROB_SIZE) - 1 : 0] push_rob_tag,
    input  [ISSUE_WIDTH - 1 : 0]    push_pred_taken,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_pred_target,
    input  [ISSUE_WIDTH * $clog2(RAS_SIZE) - 1 : 0] push_ras_snap,
    // B: 执行槽清空 (自清; 与 sel 同拍)
    input  [ISSUE_WIDTH - 1 : 0]    clear_valid,
    input  [ISSUE_WIDTH * $clog2(RS_SIZE) - 1 : 0] clear_idx,
    input  [RS_SIZE - 1 : 0]        flush_mask          // 窗口内条目失效
);
    localparam SRW = $clog2(RS_SIZE);
    localparam CSW = $clog2(RS_SIZE + 1);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam RA  = $clog2(RAS_SIZE);
    // TODO(Phase B): 条目数组 + W 级串行年龄仲裁
    assign sel_valid = {ISSUE_WIDTH{1'b0}};
    assign sel_idx   = {ISSUE_WIDTH * $clog2(RS_SIZE){1'b0}};
    assign free_count = {$clog2(RS_SIZE + 1){1'b0}};
    assign entry_valid = {RS_SIZE{1'b0}};
    assign entry_opcode = {RS_SIZE * 7{1'b0}};
    assign entry_func3  = {RS_SIZE * 3{1'b0}};
    assign entry_func7  = {RS_SIZE * 7{1'b0}};
    assign entry_prs1   = {RS_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign entry_prs2   = {RS_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign entry_prd    = {RS_SIZE * $clog2(PRF_SIZE){1'b0}};
    assign entry_pc     = {RS_SIZE * 32{1'b0}};
    assign entry_imm    = {RS_SIZE * 32{1'b0}};
    assign entry_lsq_tag = {RS_SIZE * $clog2(LSQ_SIZE){1'b0}};
    assign entry_rob_tag = {RS_SIZE * $clog2(ROB_SIZE){1'b0}};
    assign entry_pred_taken  = {RS_SIZE{1'b0}};
    assign entry_pred_target = {RS_SIZE * 32{1'b0}};
    assign entry_ras_snap    = {RS_SIZE * $clog2(RAS_SIZE){1'b0}};
endmodule
