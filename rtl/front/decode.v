// 指令解码: 字段提取 + 6 种立即数符号扩展 + 类别单热译码 (纯组合)
// RV32IM: 去掉 csr*/fence/半字/字节 load (见 project.pptx); 非法指令 → 全部类别 0 (按 NOP 处理)
module decode #(
    parameter ISSUE_WIDTH = 1
) (
    input  [ISSUE_WIDTH * 32 - 1 : 0] raw,
    input  [ISSUE_WIDTH - 1 : 0]    d_valid,
    output [ISSUE_WIDTH * 7 - 1 : 0]  opcode,
    output [ISSUE_WIDTH * 3 - 1 : 0]  func3,
    output [ISSUE_WIDTH * 7 - 1 : 0]  func7,
    output [ISSUE_WIDTH * 5 - 1 : 0]  rd, rs1, rs2,
    output [ISSUE_WIDTH * 32 - 1 : 0] imm,             // 6 种类型符号扩展
    output [ISSUE_WIDTH - 1 : 0]    is_alu, is_mul, is_load, is_store,
    output [ISSUE_WIDTH - 1 : 0]    is_branch, is_jal, is_jalr, is_lui, is_auipc,
    output [ISSUE_WIDTH - 1 : 0]    writes_rd,       // rd!=0 且非 store/branch
    output [ISSUE_WIDTH * 2 - 1 : 0]  mem_width,       // 1/2/4 字节
    output [ISSUE_WIDTH - 1 : 0]    mem_unsigned     // load 无符号 (func3[2])
);
    // TODO(Phase B): 纯组合译码
    assign opcode = {ISSUE_WIDTH * 7{1'b0}};
    assign func3  = {ISSUE_WIDTH * 3{1'b0}};
    assign func7  = {ISSUE_WIDTH * 7{1'b0}};
    assign rd     = {ISSUE_WIDTH * 5{1'b0}};
    assign rs1    = {ISSUE_WIDTH * 5{1'b0}};
    assign rs2    = {ISSUE_WIDTH * 5{1'b0}};
    assign imm    = {ISSUE_WIDTH * 32{1'b0}};
    assign is_alu = {ISSUE_WIDTH{1'b0}};
    assign is_mul = {ISSUE_WIDTH{1'b0}};
    assign is_load = {ISSUE_WIDTH{1'b0}};
    assign is_store = {ISSUE_WIDTH{1'b0}};
    assign is_branch = {ISSUE_WIDTH{1'b0}};
    assign is_jal  = {ISSUE_WIDTH{1'b0}};
    assign is_jalr = {ISSUE_WIDTH{1'b0}};
    assign is_lui  = {ISSUE_WIDTH{1'b0}};
    assign is_auipc = {ISSUE_WIDTH{1'b0}};
    assign writes_rd = {ISSUE_WIDTH{1'b0}};
    assign mem_width = {ISSUE_WIDTH * 2{1'b0}};
    assign mem_unsigned = {ISSUE_WIDTH{1'b0}};
endmodule
