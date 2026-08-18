// ALU: 纯组合, 支持 RV32IM 的 14 种运算
// op 编码: 0=add 1=sub 2=sll 3=slt 4=sltu 5=xor 6=srl 7=sra 8=or 9=and
//          10=mul 11=mulh 12=mulhsu 13=mulhu
// 内部实例化 adder32 (add/sub/slt 差分校准) + mul (2位Booth+华莱士树, 符号模式按 op)
module alu (
    input  [31 : 0] a,
    input  [31 : 0] b,
    input  [4 : 0]  op,
    output [31 : 0] result
);
    // TODO(Phase B): 实例化 adder32/mul, 按 op 组合选择
    assign result = 32'd0;
endmodule
