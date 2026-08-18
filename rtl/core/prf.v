// 物理寄存器堆: 2W 索引读口 (读地址 = preg; preg==0 短路输出 0) + W+1 CDB 写回口
// 复位全 0; 每个 preg 每生命周期恰好写一次 (D1 不变式, 见计划)
module prf #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    output [ISSUE_WIDTH * 32 - 1 : 0]     data_out1, data_out2,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0]     rd1_preg, rd2_preg,
    input  [ISSUE_WIDTH : 0]          wr_valid,
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] wr_preg,
    input  [(ISSUE_WIDTH + 1) * 32 - 1 : 0] wr_data
);
    localparam PW = $clog2(PRF_SIZE);
    // TODO(Phase B): reg [31:0] regs[0:PRF_SIZE-1]
    assign data_out1 = {ISSUE_WIDTH * 32{1'b0}};
    assign data_out2 = {ISSUE_WIDTH * 32{1'b0}};
endmodule
