// 32-bit 乘法器: radix-4 (2位) Booth 编码 + Wallace 树列压缩 + 64 位加法器
// 支持 RV32M 四种乘法语义 (MUL/MULH/MULHSU/MULHU), 由 a_signed/b_signed 选择符号模式
// 结构: 17 个部分积 + 1 行校正位 → 6 层列压缩 (18→12→8→6→4→3→2) → adder32(WIDTH=64)
module mul (
    input  [31 : 0] a,
    input  [31 : 0] b,
    input         a_signed,   // a 按有符号处理 (MULH/MULHSU)
    input         b_signed,   // b 按有符号处理 (MULH)
    output [63 : 0] product
);

    wire [34 : 0] be;
    assign be[0]     = 1'b0;
    assign be[34 : 33] = b_signed ? {b[31], b[31]} : 2'b00;
    assign be[32 : 1]  = b;

    // 被乘数扩展为 33 位补码 A (a_signed=1 时符号扩展 1 位)
    wire [32 : 0] A;
    assign A = {a_signed ? a[31] : 1'b0, a};

    wire [18 * 64 - 1 : 0] rows_pk;
    wire [16 : 0] pp_neg;

    // 校正位行: 位 2i = pp_neg[i] (负部分积的补码 +1), 其余位为 0
    wire [63 : 0] hot_row;
    assign hot_row = { 31'b0, pp_neg[16], 1'b0, pp_neg[15], 1'b0, pp_neg[14], 1'b0,
                       pp_neg[13], 1'b0, pp_neg[12], 1'b0, pp_neg[11], 1'b0, pp_neg[10], 1'b0,
                       pp_neg[9], 1'b0, pp_neg[8], 1'b0, pp_neg[7], 1'b0, pp_neg[6], 1'b0,
                       pp_neg[5], 1'b0, pp_neg[4], 1'b0, pp_neg[3], 1'b0, pp_neg[2], 1'b0,
                       pp_neg[1], 1'b0, pp_neg[0] };

    genvar i;
    generate
        for (i = 0; i < 17; i = i + 1) begin : booth
            wire x2 = be[2 * i + 2];
            wire x1 = be[2 * i + 1];
            wire x0 = be[2 * i];
            wire neg  = x2 & ~(x1 & x0);                    // 100/101/110
            wire mag0 = x1 ^ x0;                            // 001/010/101/110
            wire mag1 = (x2 & ~x1 & ~x0) | (~x2 & x1 & x0); // 011/100
            assign pp_neg[i] = neg;
            wire [33 : 0] val = mag1 ? {A[32], A[31 : 0], 1'b0}
 : (mag0 ? {A[32], A} : 34'b0);
            wire [33 : 0] pp = neg ? ~val : val;
            if (2 * i + 34 <= 64) begin : ext
                assign rows_pk[i * 64 +: 64] =
                    {{(64 - (2 * i + 34)){pp[33]}}, pp, {(2 * i){1'b0}}};
            end else begin : trunc
                assign rows_pk[i * 64 +: 64] =
                    {pp[(64 - (2 * i) - 1) : 0], {(2 * i){1'b0}}};
            end
        end
        // 校正位行整行单驱动写入
        assign rows_pk[17 * 64 +: 64] = hot_row;
    endgenerate

    wire [12 * 64 - 1 : 0] l1;
    wire [8 * 64 - 1 : 0]  l2;
    wire [6 * 64 - 1 : 0]  l3;
    wire [4 * 64 - 1 : 0]  l4;
    wire [3 * 64 - 1 : 0]  l5;
    wire [2 * 64 - 1 : 0]  l6;

    tree_level #(.IN(18), .F(6), .H(0), .R(0)) t1 (.in(rows_pk), .out(l1));
    tree_level #(.IN(12), .F(4), .H(0), .R(0)) t2 (.in(l1),      .out(l2));
    tree_level #(.IN(8),  .F(2), .H(1), .R(0)) t3 (.in(l2),      .out(l3));
    tree_level #(.IN(6),  .F(2), .H(0), .R(0)) t4 (.in(l3),      .out(l4));
    tree_level #(.IN(4),  .F(1), .H(0), .R(1)) t5 (.in(l4),      .out(l5));
    tree_level #(.IN(3),  .F(1), .H(0), .R(0)) t6 (.in(l5),      .out(l6));

    wire cout_unused;
    adder32 #(.WIDTH(64)) fin (
        .a(l6[63 : 0]), .b(l6[127 : 64]), .cin(1'b0), .sum(product), .cout(cout_unused)
    );

endmodule

module tree_level #(
    parameter IN = 18,  // 输入行数
    parameter F  = 6,   // 全加器数
    parameter H  = 0,   // 半加器数 (0 或 1)
    parameter R  = 0    // 直通位数 (0 或 1)
) (
    input  [IN * 64 - 1 : 0]              in,
    output [(2 * F + 2 * H + R) * 64 - 1 : 0] out
);
    localparam OUT = F + H + R;         // 本列输出行数 (和位 + 直通)

    // 以 64 位整行为单位做压缩 (行 k = 一列部分积); 进位行 << 1 等价于逐位列取 c-1,
    // 列 0 自然得 0, 列 63 的进位同样丢弃 (与逐位版一致), 且是确定 0 而非 X
    genvar k;
    generate
        for (k = 0; k < F; k = k + 1) begin : fa
            wire [63 : 0] x = in[(3 * k + 0) * 64 +: 64];
            wire [63 : 0] y = in[(3 * k + 1) * 64 +: 64];
            wire [63 : 0] z = in[(3 * k + 2) * 64 +: 64];
            assign out[k * 64 +: 64]         = x ^ y ^ z;
            assign out[(OUT + k) * 64 +: 64] = ((x & y) | (x & z) | (y & z)) << 1;
        end
        if (H == 1) begin : ha
            wire [63 : 0] x = in[(3 * F + 0) * 64 +: 64];
            wire [63 : 0] y = in[(3 * F + 1) * 64 +: 64];
            assign out[F * 64 +: 64]         = x ^ y;         // 半加器和
            assign out[(OUT + F) * 64 +: 64] = (x & y) << 1;  // 半加器进位是 AND, 非多数
        end
        if (R == 1) begin : thru
            assign out[(F + H) * 64 +: 64] = in[(3 * F + 2 * H) * 64 +: 64]; // 整行原样搬运
        end
    endgenerate
endmodule
