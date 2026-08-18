// 分支判定: 纯组合, 无条件跳转 (mode=1/2) 或条件分支比较, 目标/链接计算
// 内部 3 个 adder32: 比较差分 (beq=全0/blt=符号位/bltu=借位), pc+imm, pc+4
module branch (
    input  [31 : 0] rs1,
    input  [31 : 0] rs2,
    input  [31 : 0] pc,
    input  [31 : 0] imm,       // 已符号扩展 (B 型/J 型/I 型)
    input  [1 : 0]  mode,      // 0=branch 1=jal 2=jalr
    input  [2 : 0]  br_op,     // beq=0 bne=1 blt=4 bge=5 bltu=6 bgeu=7 (仅 mode=0 有意义)
    output        taken,
    output [31 : 0] target,    // branch/jal: pc+imm; jalr: (rs1+imm)&~1
    output [31 : 0] link       // pc+4 (jal/jalr 的写回值)
);
    // TODO(Phase B): 3 个 adder32 + 比较/选择组合
    assign taken  = 1'b0;
    assign target = 32'd0;
    assign link   = 32'd0;
endmodule
