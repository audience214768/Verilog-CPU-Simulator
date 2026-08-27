// 分支判定: 纯组合, 无条件跳转 (mode=1/2) 或条件分支比较, 目标/链接计算
// 内部 4 个 adder32: 比较差分 (beq 全 0 / blt 符号位 / bltu 借位),
//                    pc+imm, rs1+imm (jalr), pc+4
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
    wire [31 : 0] diff;                     // rs1 - rs2
    wire          cdout;
    adder32 ucmp (.a(rs1),    .b(~rs2), .cin(1'b1), .sum(diff),  .cout(cdout));
    wire [31 : 0] t_sum;                    // pc + imm
    wire [31 : 0] j_sum;                    // rs1 + imm
    wire [31 : 0] l_sum;                    // pc + 4
    adder32 utgt (.a(pc),     .b(imm),  .cin(1'b0), .sum(t_sum), .cout());
    adder32 ujal (.a(rs1),    .b(imm),  .cin(1'b0), .sum(j_sum), .cout());
    adder32 ulnk (.a(pc),     .b(32'd4), .cin(1'b0), .sum(l_sum), .cout());

    // 有符号小于: 异号看 rs1 符号位, 同号看差符号位; 无符号小于 = 借位
    wire slt_s = (rs1[31] && !rs2[31]) || (rs1[31] == rs2[31] && diff[31]);
    wire cond_taken = (br_op == 3'd0) ? (diff == 32'd0)
                    : (br_op == 3'd1) ? (diff != 32'd0)
                    : (br_op == 3'd4) ? slt_s
                    : (br_op == 3'd5) ? !slt_s
                    : (br_op == 3'd6) ? !cdout
                    : (br_op == 3'd7) ? cdout
                    : 1'b0;                 // 非法 br_op → 不跳

    assign taken  = (mode == 2'd0) ? cond_taken : 1'b1;
    // branch: 实际去向 = taken ? pc+imm : pc+4 (误预测重定向用); jal: pc+imm; jalr: (rs1+imm)&~1
    assign target = (mode == 2'd0) ? (cond_taken ? t_sum : l_sum)
                   : (mode == 2'd1) ? t_sum
                   : (j_sum & 32'hFFFFFFFE);            // jalr: 位 0 清零
    assign link   = l_sum;
endmodule
