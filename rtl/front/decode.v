// 指令解码: 字段提取 + 6 种立即数符号扩展 + 类别单热译码 (纯组合)
// RV32IM: 去掉 csr*/fence/半字/字节 load (见 project.pptx); 非法指令 → 全部类别 0 (按 NOP 处理)
// 合法性门: 每槽独立; 输出在 d_valid 与类别合规下才非 0
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
    output [ISSUE_WIDTH * 2 - 1 : 0]  mem_width,       // 1/2/4 字节 (仅 lw → 4)
    output [ISSUE_WIDTH - 1 : 0]    mem_unsigned     // load 无符号 (仅 lw → 0)
);
    genvar i;
    generate
        for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin : dec
            wire [31 : 0] ins  = raw[i * 32 +: 32];
            wire [6 : 0]  op   = ins[6 : 0];
            wire [4 : 0]  rdw  = ins[11 : 7];
            wire [4 : 0]  rs1w = ins[19 : 15];
            wire [4 : 0]  rs2w = ins[24 : 20];
            wire [2 : 0]  f3   = ins[14 : 12];
            wire [6 : 0]  f7   = ins[31 : 25];

            // ---- 类别 (opcode 译码) ----
            wire cat_r     = (op == 7'b0110011);
            wire cat_i     = (op == 7'b0010011);
            wire cat_ld    = (op == 7'b0000011);
            wire cat_st    = (op == 7'b0100011);
            wire cat_br    = (op == 7'b1100011);
            wire cat_jal   = (op == 7'b1101111);
            wire cat_jalr  = (op == 7'b1100111);
            wire cat_lui   = (op == 7'b0110111);
            wire cat_auipc = (op == 7'b0010111);

            // ---- 合法性门: func3/func7 合规 (子集外的组合 → NOP) ----
            wire mul_f3_ok = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2) || (f3 == 3'd3);
            wire ld_st_ok  = (f3 == 3'd2);       // 仅 lw / sw
            wire br_f3_ok  = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd4) || (f3 == 3'd5)
                          || (f3 == 3'd6) || (f3 == 3'd7);
            wire jalr_ok   = (f3 == 3'd0);
            // I 型: 移位 (f3=001/101) 需 f7 ∈ {0000000, 0100000}, 其余 f7 必须为 0
            wire shift_ok  = ((f3 == 3'd1) || (f3 == 3'd5))
                           ? ((f7 == 7'b0000000) || (f7 == 7'b0100000)) : (f7 == 7'b0000000);

            // 类别有效 (互斥单热)
            wire v_r     = cat_r   && (f7 == 7'b0000000);
            wire v_mul   = cat_r   && (f7 == 7'b0000001) && mul_f3_ok;
            wire v_i     = cat_i   && shift_ok;
            wire v_ld    = cat_ld  && ld_st_ok;
            wire v_st    = cat_st  && ld_st_ok;
            wire v_br    = cat_br  && br_f3_ok;
            wire v_jal   = cat_jal;
            wire v_jalr  = cat_jalr && jalr_ok;
            wire v_lui   = cat_lui;
            wire v_auipc = cat_auipc;
            wire valid   = d_valid[i] && (v_r || v_mul || v_i || v_ld || v_st || v_br
                                       || v_jal || v_jalr || v_lui || v_auipc);

            // ---- imm 符号扩展 (6 种; 仅按类别选一) ----
            wire [31 : 0] imm_i = {{21{ins[31]}}, ins[30 : 20]};
            wire [31 : 0] imm_s = {{21{ins[31]}}, ins[30 : 25], ins[11 : 7]};
            wire [31 : 0] imm_b = {{20{ins[31]}}, ins[7], ins[30 : 25], ins[11 : 8], 1'b0};
            wire [31 : 0] imm_u = {ins[31 : 12], 12'b0};
            wire [31 : 0] imm_j = {{12{ins[31]}}, ins[19 : 12], ins[20], ins[30 : 21], 1'b0};
            wire [31 : 0] immx  = (v_ld || v_i || v_jalr) ? imm_i
                                : v_st ? imm_s : v_br ? imm_b
                                : (v_lui || v_auipc) ? imm_u : v_jal ? imm_j : 32'd0;

            // ---- 输出 (valid 门控) ----
            assign opcode[i * 7 +: 7]  = valid ? op : 7'd0;
            assign func3[i * 3 +: 3]   = valid ? f3 : 3'd0;
            assign func7[i * 7 +: 7]   = valid ? f7 : 7'd0;
            assign rd[i * 5 +: 5]      = valid ? rdw : 5'd0;
            assign rs1[i * 5 +: 5]     = valid ? rs1w : 5'd0;
            assign rs2[i * 5 +: 5]     = valid ? rs2w : 5'd0;
            assign imm[i * 32 +: 32]   = valid ? immx : 32'd0;
            assign is_alu[i]    = valid && v_r;
            assign is_mul[i]    = valid && v_mul;
            assign is_load[i]   = valid && v_ld;
            assign is_store[i]  = valid && v_st;
            assign is_branch[i] = valid && v_br;
            assign is_jal[i]    = valid && v_jal;
            assign is_jalr[i]   = valid && v_jalr;
            assign is_lui[i]    = valid && v_lui;
            assign is_auipc[i]  = valid && v_auipc;
            // writes_rd: rd!=0 且写目的 (store/branch/非法不写)
            assign writes_rd[i] = valid && (rdw != 5'd0)
                               && (v_r || v_mul || v_i || v_ld || v_jal || v_jalr || v_lui || v_auipc);
            assign mem_width[i * 2 +: 2] = v_ld ? 2'd2 : 2'd0;   // 仅 lw (4 字节)
            assign mem_unsigned[i] = 1'b0;
        end
    endgenerate
endmodule
