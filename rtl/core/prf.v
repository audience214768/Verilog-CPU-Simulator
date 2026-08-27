// 物理寄存器堆: 2W 索引读口 (读地址 = preg; preg==0 短路输出 0) + W+1 CDB 写回口
// 复位全 0; 每个 preg 每生命周期恰好写一次 (D1 不变式, 见计划)
// 写回仅 CDB 单一来源 (load 完成经槽 W); 读口组合输出
module prf #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * 32 - 1 : 0]                data_out1, data_out2,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0]  rd1_preg, rd2_preg,
    input  [ISSUE_WIDTH : 0]                         wr_valid,
    input  [(ISSUE_WIDTH + 1) * $clog2(PRF_SIZE) - 1 : 0] wr_preg,
    input  [(ISSUE_WIDTH + 1) * 32 - 1 : 0]          wr_data
);
    localparam PW = $clog2(PRF_SIZE);

    reg [31 : 0] regs [0 : PRF_SIZE - 1];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < PRF_SIZE; i = i + 1)
                regs[i] <= 32'd0;
        end else begin
            for (i = 0; i <= ISSUE_WIDTH; i = i + 1)
                if (wr_valid[i])
                    regs[wr_preg[i * PW +: PW]] <= wr_data[i * 32 +: 32];
        end
    end

    // 读口: preg==0 短路输出 0 (x0 硬连线)
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : rd
            assign data_out1[g * 32 +: 32] = (rd1_preg[g * PW +: PW] == {PW{1'b0}})
                                           ? 32'd0 : regs[rd1_preg[g * PW +: PW]];
            assign data_out2[g * 32 +: 32] = (rd2_preg[g * PW +: PW] == {PW{1'b0}})
                                           ? 32'd0 : regs[rd2_preg[g * PW +: PW]];
        end
    endgenerate
endmodule
