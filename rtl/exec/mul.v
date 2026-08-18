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
            // 行值 pp (34 位): 负值取反, +1 由校正位行提供
            wire [33 : 0] pp = neg ? ~val : val;
            // 64 位列值: 值位列 2i..2i+33, 符号扩展至列 63; 最高行 (i=16) 截断到 32 位
            if (2 * i + 34 <= 64) begin : ext
                assign rows_pk[i * 64 +: 64] =
                    {{(64 - (2 * i + 34)){pp[33]}}, pp, {(2 * i){1'b0}}};
            end else begin : trunc
                assign rows_pk[i * 64 +: 64] =
                    {pp[(64 - (2 * i) - 1) : 0], {(2 * i){1'b0}}};
            end
        end
        // 校正位行: hot[i] 在列 2i (负部分积的补码 +1)
        for (i = 0; i < 64; i = i + 1) begin : hot
            if ((i & 1) == 0 && i < 34) begin : set
                assign rows_pk[17 * 64 + i] = pp_neg[i / 2];
            end else begin : clear
                assign rows_pk[17 * 64 + i] = 1'b0;
            end
        end
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
    localparam TOT = 2 * F + 2 * H + R; // 总输出行数 = 本列输出 + 进位

    genvar c, k;
    generate
        for (c = 0; c < 64; c = c + 1) begin : col
            for (k = 0; k < TOT; k = k + 1) begin : bit_
                if (k < OUT) begin : outbit
                    if (k < F) begin : fa
                        assign out[k * 64 + c] =
                            in[(3 * k + 0) * 64 + c] ^
                            in[(3 * k + 1) * 64 + c] ^
                            in[(3 * k + 2) * 64 + c];
                    end else if (k < F + H) begin : ha
                        assign out[k * 64 + c] =
                            in[(3 * F + 0) * 64 + c] ^ in[(3 * F + 1) * 64 + c];
                    end else begin : thru
                        assign out[k * 64 + c] = in[(3 * F + 2 * H) * 64 + c];
                    end
                end else begin : carrybit
                    if (c > 0) begin : src
                        if (k - OUT < F) begin : fa2
                            assign out[k * 64 + c] =
                                (in[(3 * (k - OUT) + 0) * 64 + c - 1] &
                                 in[(3 * (k - OUT) + 1) * 64 + c - 1]) |
                                (in[(3 * (k - OUT) + 2) * 64 + c - 1] &
                                 (in[(3 * (k - OUT) + 0) * 64 + c - 1] |
                                  in[(3 * (k - OUT) + 1) * 64 + c - 1]));
                        end else begin : ha2
                            assign out[k * 64 + c] =
                                in[(3 * F + 0) * 64 + c - 1] & in[(3 * F + 1) * 64 + c - 1];
                        end
                    end else begin : zero
                        assign out[k * 64 + c] = 1'b0; // 列 0 无低列进位
                    end
                end
            end
        end
    endgenerate
endmodule
