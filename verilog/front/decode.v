// 指令解码: 字段提取 + 6 种立即数符号扩展 + 类别单热译码 (纯组合)
// RV32IM: 去掉 csr*/fence; 非法指令 → 全部类别 0 (按 NOP 处理)
// 终止指令 (与参考模拟器 RISC-V-Tomasulo-CPU-Simulator 一致): addi a0, x0, 255 = 0x0FF00513
//   被当作"写 x0" → 不分配 prd/不改 a0 映射, 于是停机时 a0 保留 main 的返回值;
//   rob 中存的 raw 仍是原编码, cpu_top 的 halt 判定不受影响
// 访存宽度: lb/lbu/lh/lhu/sb/sh/sw 全部支持 (宽 = f3[1:0]: 00=1 01=2 10=4 字节), 测试程序需要 lbu/sb
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
    output [ISSUE_WIDTH - 1 : 0]    is_alu, is_mul, is_div, is_load, is_store,
    output [ISSUE_WIDTH - 1 : 0]    is_branch, is_jal, is_jalr, is_lui, is_auipc,
    output [ISSUE_WIDTH - 1 : 0]    writes_rd,       // rd!=0 且非 store/branch
    output [ISSUE_WIDTH * 2 - 1 : 0]  mem_width,       // 1/2/4 字节 (f3[1:0]: 00=1 01=2 10=4)
    output [ISSUE_WIDTH - 1 : 0]    mem_unsigned     // load 无符号 (lb/lh 由 f3[2] 选)
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
            // 终止指令: rd 视作 x0 (见头注释); 其余指令 rd 原样
            wire          is_term = (ins == 32'h0FF00513);
            wire [4 : 0]  rd_eff  = is_term ? 5'd0 : rdw;

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
            wire div_f3_ok = (f3 == 3'd4) || (f3 == 3'd5) || (f3 == 3'd6) || (f3 == 3'd7);
            wire ld_f3_ok  = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2)
                          || (f3 == 3'd4) || (f3 == 3'd5);   // lb / lh / lw / lbu / lhu
            wire st_f3_ok  = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2);   // sb / sh / sw
            wire br_f3_ok  = (f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd4) || (f3 == 3'd5)
                          || (f3 == 3'd6) || (f3 == 3'd7);
            wire jalr_ok   = (f3 == 3'd0);
            // I 型: 仅移位 (f3=001/101) 用 ins[31:25] 编码移位类型, 需 f7 ∈ {0000000, 0100000};
            //       其余 I 型 (addi/slti/xori/ori/andi) 的 ins[31:25] 属立即数 imm[11:5], 不可检查
            wire shift_ok  = ((f3 == 3'd1) || (f3 == 3'd5))
                           ? ((f7 == 7'b0000000) || (f7 == 7'b0100000)) : 1'b1;

            // 类别有效 (互斥单热); R 型: f7=0000000 或 0100000 (仅 f3=000 sub / 101 sra)
            wire r_ok    = (f7 == 7'b0000000)
                        || ((f7 == 7'b0100000) && ((f3 == 3'd0) || (f3 == 3'd5)));
            wire v_r     = cat_r   && r_ok;
            wire v_mul   = cat_r   && (f7 == 7'b0000001) && mul_f3_ok;
            wire v_div   = cat_r   && (f7 == 7'b0000001) && div_f3_ok;
            wire v_i     = cat_i   && shift_ok;
            wire v_ld    = cat_ld  && ld_f3_ok;
            wire v_st    = cat_st  && st_f3_ok;
            wire v_br    = cat_br  && br_f3_ok;
            wire v_jal   = cat_jal;
            wire v_jalr  = cat_jalr && jalr_ok;
            wire v_lui   = cat_lui;
            wire v_auipc = cat_auipc;
            wire valid   = d_valid[i] && (v_r || v_mul || v_div || v_i || v_ld || v_st || v_br
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
            assign rd[i * 5 +: 5]      = valid ? rd_eff : 5'd0;
            assign rs1[i * 5 +: 5]     = valid ? rs1w : 5'd0;
            assign rs2[i * 5 +: 5]     = valid ? rs2w : 5'd0;
            assign imm[i * 32 +: 32]   = valid ? immx : 32'd0;
            assign is_alu[i]    = valid && v_r;
            assign is_mul[i]    = valid && v_mul;
            assign is_div[i]    = valid && v_div;
            assign is_load[i]   = valid && v_ld;
            assign is_store[i]  = valid && v_st;
            assign is_branch[i] = valid && v_br;
            assign is_jal[i]    = valid && v_jal;
            assign is_jalr[i]   = valid && v_jalr;
            assign is_lui[i]    = valid && v_lui;
            assign is_auipc[i]  = valid && v_auipc;
            // writes_rd: rd!=0 且写目的 (store/branch/非法/终止指令不写)
            assign writes_rd[i] = valid && (rd_eff != 5'd0)
                               && (v_r || v_mul || v_div || v_i || v_ld
                                || v_jal || v_jalr || v_lui || v_auipc);
            assign mem_width[i * 2 +: 2] = (v_ld || v_st) ? f3[1 : 0] : 2'd0;   // 00=1 01=2 10=4 字节
            assign mem_unsigned[i] = v_ld && f3[2];                            // lbu/lhu (f3 = 100/101)
        end
    endgenerate
endmodule
