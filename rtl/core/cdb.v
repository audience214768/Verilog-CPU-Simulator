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

    // 执行槽 0..W-1: prd==0 不写 PRF/不置 ready; rob_wr 与 prd 无关 (按 tag 置 ROB ready)
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : ex
            wire prd_nz = (exec_prd[g * PW +: PW] != {PW{1'b0}});
            assign prf_valid[g]    = exec_valid[g] && prd_nz;
            assign prf_preg[g * PW +: PW] = exec_prd[g * PW +: PW];
            assign prf_data[g * 32 +: 32] = exec_result[g * 32 +: 32];
        end
    endgenerate
    // 槽 W: load 完成 (每周期 ≤1)
    assign prf_valid[ISSUE_WIDTH] = load_valid && (load_prd != {PW{1'b0}});
    assign prf_preg[ISSUE_WIDTH * PW +: PW] = load_prd;
    assign prf_data[ISSUE_WIDTH * 32 +: 32] = load_result;

    // rt_set_req / rob_ready_req: 独热译码后逐位归约 (assign 目标必须常量索引)
    function [PRF_SIZE - 1 : 0] dec_p;
        input [PW - 1 : 0] p;
        integer k;
        begin
            dec_p = {PRF_SIZE{1'b0}};
            for (k = 0; k < PRF_SIZE; k = k + 1)
                if (k == p) dec_p[k] = 1'b1;
        end
    endfunction
    function [ROB_SIZE - 1 : 0] dec_t;
        input [RW - 1 : 0] t;
        integer k;
        begin
            dec_t = {ROB_SIZE{1'b0}};
            for (k = 0; k < ROB_SIZE; k = k + 1)
                if (k == t) dec_t[k] = 1'b1;
        end
    endfunction
    wire [ISSUE_WIDTH * PRF_SIZE - 1 : 0] rt_slot;
    wire [ISSUE_WIDTH * ROB_SIZE - 1 : 0] rr_slot;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : rtg
            assign rt_slot[g * PRF_SIZE +: PRF_SIZE]
                 = (exec_valid[g] && (exec_prd[g * PW +: PW] != {PW{1'b0}}))
                   ? dec_p(exec_prd[g * PW +: PW]) : {PRF_SIZE{1'b0}};
            assign rr_slot[g * ROB_SIZE +: ROB_SIZE]
                 = (exec_valid[g] && exec_rob_wr[g])
                   ? dec_t(exec_rob_tag[g * RW +: RW]) : {ROB_SIZE{1'b0}};
        end
    endgenerate
    genvar gr, gx;
    generate
        for (gr = 0; gr < PRF_SIZE; gr = gr + 1) begin : rtm
            wire [ISSUE_WIDTH - 1 : 0] b;
            for (gx = 0; gx < ISSUE_WIDTH; gx = gx + 1) begin : rtb
                assign b[gx] = rt_slot[gx * PRF_SIZE + gr];
            end
            assign rt_set_req[gr] = |b
                || (load_valid && (load_prd != {PW{1'b0}}) && (load_prd == gr));
        end
        for (gr = 0; gr < ROB_SIZE; gr = gr + 1) begin : rrm
            wire [ISSUE_WIDTH - 1 : 0] b;
            for (gx = 0; gx < ISSUE_WIDTH; gx = gx + 1) begin : rrb
                assign b[gx] = rr_slot[gx * ROB_SIZE + gr];
            end
            assign rob_ready_req[gr] = |b
                || (load_valid && load_rob_wr && (load_rob_tag == gr));
        end
    endgenerate
endmodule
