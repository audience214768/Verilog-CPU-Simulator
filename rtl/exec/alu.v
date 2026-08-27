// ALU: 纯组合, 支持 RV32IM 的 14 种运算
// op 编码: 0=add 1=sub 2=sll 3=slt 4=sltu 5=xor 6=srl 7=sra 8=or 9=and
//          10=mul 11=mulh 12=mulhsu 13=mulhu
// 内部实例化 adder32 (add/sub/slt/sltu 差分校准) + mul (2位Booth+华莱士树, 符号模式按 op)
module alu (
    input  [31 : 0] a,
    input  [31 : 0] b,
    input  [4 : 0]  op,
    output [31 : 0] result
);
    wire [31 : 0] sum;                       // a + b
    wire [31 : 0] diff;                      // a - b
    wire          cadd, csub;
    adder32 uadd (.a(a),     .b(b),  .cin(1'b0), .sum(sum),   .cout(cadd));
    adder32 usub (.a(a),     .b(~b), .cin(1'b1), .sum(diff),  .cout(csub));
    // 有符号小于: 异号看 a 符号位, 同号看差符号位
    wire slt  = (a[31] && !b[31]) || (a[31] == b[31] && diff[31]);
    wire sltu = !csub;                       // 无符号小于 = 借位

    // 乘法: 符号模式按 op (mul 低 32 位与符号无关, 用无符号即可)
    wire [63 : 0] product;
    wire m_as = (op == 5'd11) || (op == 5'd12);
    wire m_bs = (op == 5'd11);
    mul umul (.a(a), .b(b), .a_signed(m_as), .b_signed(m_bs), .product(product));

    // 算术右移: 64 位符号位复制后逻辑右移 (避免 ?: 上下文把 >>> 降级为逻辑右移)
    wire [63 : 0] sra64 = {{32{a[31]}}, a} >> b[4 : 0];
    wire [31 : 0] sra_r  = sra64[31 : 0];

    assign result = (op == 5'd0)  ? sum
                  : (op == 5'd1)  ? diff
                  : (op == 5'd2)  ? (a << b[4 : 0])
                  : (op == 5'd3)  ? {31'd0, slt}
                  : (op == 5'd4)  ? {31'd0, sltu}
                  : (op == 5'd5)  ? (a ^ b)
                  : (op == 5'd6)  ? (a >> b[4 : 0])
                  : (op == 5'd7)  ? sra_r
                  : (op == 5'd8)  ? (a | b)
                  : (op == 5'd9)  ? (a & b)
                  : (op == 5'd10) ? product[31 : 0]
                  : (op == 5'd11) ? product[63 : 32]
                  : (op == 5'd12) ? product[63 : 32]
                  :                 product[63 : 32];
endmodule
