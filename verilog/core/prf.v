// 物理寄存器堆: 2W 索引读口 (读地址 = preg; preg==0 短路输出 0) + W+2 CDB 写回口
// ★ **无复位** (2026-10-10 净删): 原来每个 preg 复位成 0, 唯一用途是"架构寄存器初值为 0"。
//   那件事改由 rat.v 复位时把**全部架构寄存器映射到 preg 0** 表达 —— 读口本就有
//   `preg==0 短路输出 0` ⇒ 初值语义逐位不变, 而 2048 个触发器不再需要复位软逻辑
//   (ASAP7 r28 无同步复位触发器, 每个都要 1 个门; 复位网少 2048 个负载脚)。
//   安全性: 每个 preg 每生命周期恰好写一次 (D1 不变式), 且 PRF **只在就绪条目上被读**
//   (rs.v 仲裁出的条目必满足 prs==0 || CDB 命中 || rt_ready) ⇒ 未写过的 preg 永不被读到,
//   去掉复位不会让 X 进入数据通路。
// 写回仅 CDB 单一来源 (load 完成经槽 W, div 完成经槽 W+1); 读口组合输出
module prf #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
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
        for (i = 0; i <= ISSUE_WIDTH + 1; i = i + 1)
            if (wr_valid[i])
                regs[wr_preg[i * PW +: PW]] <= wr_data[i * 32 +: 32];
    end

    // 读口: preg==0 短路输出 0 (x0 硬连线)
    // **one-hot + AND-OR**, 不写 `regs[rd1_preg]`: 索引读综合出 64 选 1 的 mux 树,
    // 地址**最低位落在最宽的一级** ⇒ 扇出 = 32 × 32 位 = 1024 (实测 1025)。
    // 官方 abc 没带 `-constr` ⇒ 不做 buffer/upsize (§15.10.8), 那一级实测 1.3 ns。
    // 改成 one-hot: oh1[p] 只驱动寄存器 p 的那 32 位 ⇒ 峰值扇出 1024 → 32。
    // 面积持平 (mux ≈ 2 门 vs AND2 + OR2 ≈ 2 门; 译码器 64 项 × 6 门 ≈ 384 门/口 —— 刀 P 后译码
    // 重写成 16 个 3 输入与 + 64 个 2 输入与, 比这还少)。
    // ★ 刀 P (2026-10-11): one-hot 的**译码**也拆两级 (8×8)。上一版把数据侧扇出 1024 → 32, 但译码
    //   写成一个 6 输入比较器 × 64 ⇒ **地址侧**每根位驱动 64 个门 (实测 91 脚/网) —— 官方 ABC 无
    //   buffer, 这一根就是头名家族 (b) (`sel_all_q` → `div.a_r/b_r`) 的级 3 (0.53 ns)。拆成
    //   "高位 8 选 1 + 低位 8 选 1 + AND2" 后每根地址位只驱动 8 个门, 且门数净减 (16 个 3 输入与
    //   + 64 个 2 输入与 < 64 个 6 输入与)。逐位等价: 两个子比较成立 ⇔ 整字相等。
    localparam LO = PW / 2;                                 // 低位译码宽度 (64 项 ⇒ 3/3)
    genvar g, gp, gb;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : rd
            wire [31 : 0] d1, d2;
            wire [PRF_SIZE - 1 : 0] oh1, oh2;
            for (gp = 0; gp < PRF_SIZE; gp = gp + 1) begin : dec
                assign oh1[gp] = (rd1_preg[g * PW + LO +: PW - LO] == gp[PW - 1 : LO])
                               & (rd1_preg[g * PW       +: LO] == gp[LO - 1 : 0]);
                assign oh2[gp] = (rd2_preg[g * PW + LO +: PW - LO] == gp[PW - 1 : LO])
                               & (rd2_preg[g * PW       +: LO] == gp[LO - 1 : 0]);
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
