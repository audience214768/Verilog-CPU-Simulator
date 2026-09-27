// 物理寄存器堆: 2W 索引读口 (读地址 = preg; preg==0 短路输出 0) + W+2 CDB 写回口
// 复位全 0; 每个 preg 每生命周期恰好写一次 (D1 不变式, 见计划)
// 写回仅 CDB 单一来源 (load 完成经槽 W, div 完成经槽 W+1); 读口组合输出
module prf #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
    input  rst_n,
    output [ISSUE_WIDTH * 32 - 1 : 0]                data_out1, data_out2,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0]  rd1_preg, rd2_preg,
    input  [ISSUE_WIDTH + 1 : 0]                     wr_valid,
    input  [(ISSUE_WIDTH + 2) * $clog2(PRF_SIZE) - 1 : 0] wr_preg,
    input  [(ISSUE_WIDTH + 2) * 32 - 1 : 0]          wr_data
);
    localparam PW = $clog2(PRF_SIZE);

    reg [31 : 0] regs [0 : PRF_SIZE - 1];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < PRF_SIZE; i = i + 1)
                regs[i] <= 32'd0;
        end else begin
            for (i = 0; i <= ISSUE_WIDTH + 1; i = i + 1)
                if (wr_valid[i])
                    regs[wr_preg[i * PW +: PW]] <= wr_data[i * 32 +: 32];
        end
    end

    // 读口: preg==0 短路输出 0 (x0 硬连线)
    // **one-hot + AND-OR**, 不写 `regs[rd1_preg]`: 索引读综合出 64 选 1 的 mux 树,
    // 地址**最低位落在最宽的一级** ⇒ 扇出 = 32 × 32 位 = 1024 (实测 1025)。
    // 官方 abc 没带 `-constr` ⇒ 不做 buffer/upsize (§15.10.8), 那一级实测 1.3 ns。
    // 改成 one-hot: oh1[p] 只驱动寄存器 p 的那 32 位 ⇒ 峰值扇出 1024 → 32。
    // 面积持平 (mux ≈ 2 门 vs AND2 + OR2 ≈ 2 门; 译码器 64 项 × 6 门 ≈ 384 门/口)。
    genvar g, gp, gb;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : rd
            wire [31 : 0] d1, d2;
            wire [PRF_SIZE - 1 : 0] oh1, oh2;
            for (gp = 0; gp < PRF_SIZE; gp = gp + 1) begin : dec
                assign oh1[gp] = (rd1_preg[g * PW +: PW] == gp[PW - 1 : 0]);
                assign oh2[gp] = (rd2_preg[g * PW +: PW] == gp[PW - 1 : 0]);
            end
            // 逐位归约 (constant 索引读存储器字, 不会退回 mux 树)
            for (gb = 0; gb < 32; gb = gb + 1) begin : red
                wire [PRF_SIZE - 1 : 0] m1, m2;
                for (gp = 0; gp < PRF_SIZE; gp = gp + 1) begin : e
                    assign m1[gp] = regs[gp][gb] & oh1[gp];
                    assign m2[gp] = regs[gp][gb] & oh2[gp];
                end
                assign d1[gb] = |m1;
                assign d2[gb] = |m2;
            end
            assign data_out1[g * 32 +: 32] = (rd1_preg[g * PW +: PW] == {PW{1'b0}}) ? 32'd0 : d1;
            assign data_out2[g * 32 +: 32] = (rd2_preg[g * PW +: PW] == {PW{1'b0}}) ? 32'd0 : d2;
        end
    endgenerate
endmodule
