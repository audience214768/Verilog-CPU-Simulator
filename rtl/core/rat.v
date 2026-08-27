// 寄存器别名表: 32×$clog2(PRF_SIZE) 映射, 复位恒等 map[i]=i
// 组合读口含批内转发: 读口 i 看到 rename[j] (j<i) 的映射, 最后匹配者 (j 最大) 赢
// 写优先级: flush (walker 回滚) > rename; 同槽多写同一 rd: 后写覆盖
//   (rename: 批内 j 最大赢; flush: 槽序更老者赢, 回滚收敛于最老 old)
module rat #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
    input  clk,
    input  rst_n,
    // A: 组合读口 (读地址 = issue 批的 rs1/rs2)
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] map_out1,
    output [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] map_out2,
    output [32 * $clog2(PRF_SIZE) - 1 : 0]          map_arch,   // 全阵列 (调试 / ret_val: map_arch[10])
    input  [ISSUE_WIDTH * 5 - 1 : 0]  read_rs1,   // slot i 的 rs1 体系寄存器号
    input  [ISSUE_WIDTH * 5 - 1 : 0]  read_rs2,
    // B: rename (发射; prefix: valid[i] 蕴含 valid[i-1])
    input  [ISSUE_WIDTH - 1 : 0]    rename_valid,
    input  [ISSUE_WIDTH * 5 - 1 : 0]  rename_rd,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] rename_new,
    // B: flush (walker 回滚, 写优先级 > rename)
    input  [ISSUE_WIDTH - 1 : 0]    flush_valid,
    input  [ISSUE_WIDTH * 5 - 1 : 0]  flush_rd,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] flush_old
);
    localparam PW = $clog2(PRF_SIZE);

    reg [PW - 1 : 0] map_r [0 : 31];

    // ---- 时序写: 先 rename (批内 j 递增, 后写覆盖), 再 flush (最高优先级) ----
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 32; k = k + 1)
                map_r[k] <= k[PW - 1 : 0];      // 恒等映射
        end else begin
            for (k = 0; k < ISSUE_WIDTH; k = k + 1)
                if (rename_valid[k] && (rename_rd[k * 5 +: 5] != 5'd0))
                    map_r[rename_rd[k * 5 +: 5]] <= rename_new[k * PW +: PW];
            for (k = 0; k < ISSUE_WIDTH; k = k + 1)
                if (flush_valid[k] && (flush_rd[k * 5 +: 5] != 5'd0))
                    map_r[flush_rd[k * 5 +: 5]] <= flush_old[k * PW +: PW];
        end
    end

    // ---- 全阵列输出 ----
    genvar a;
    generate
        for (a = 0; a < 32; a = a + 1) begin : arch
            assign map_arch[a * PW +: PW] = map_r[a];
        end
    endgenerate

    // ---- 批内转发链 (纯组合): 级 (i, j) = 读口 i 检查 rename j; 展平打包线 f1c/f2c ----
    // 链基 = 阵列读; 每级 :? 覆盖 → 最后匹配者 (j 最大) 赢
    wire [ISSUE_WIDTH * ISSUE_WIDTH * PW - 1 : 0] f1c, f2c;
    genvar i, j;
    generate
        for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin : rdo
            assign f1c[(i * ISSUE_WIDTH + 0) * PW +: PW]
                 = (rename_valid[0] && (rename_rd[0 * 5 +: 5] != 5'd0) && (rename_rd[0 * 5 +: 5] == read_rs1[i * 5 +: 5]))
                 ? rename_new[0 * PW +: PW] : map_r[read_rs1[i * 5 +: 5]];
            assign f2c[(i * ISSUE_WIDTH + 0) * PW +: PW]
                 = (rename_valid[0] && (rename_rd[0 * 5 +: 5] != 5'd0) && (rename_rd[0 * 5 +: 5] == read_rs2[i * 5 +: 5]))
                 ? rename_new[0 * PW +: PW] : map_r[read_rs2[i * 5 +: 5]];
            for (j = 1; j < i; j = j + 1) begin : fwd
                assign f1c[(i * ISSUE_WIDTH + j) * PW +: PW]
                     = (rename_valid[j] && (rename_rd[j * 5 +: 5] != 5'd0) && (rename_rd[j * 5 +: 5] == read_rs1[i * 5 +: 5]))
                     ? rename_new[j * PW +: PW] : f1c[(i * ISSUE_WIDTH + j - 1) * PW +: PW];
                assign f2c[(i * ISSUE_WIDTH + j) * PW +: PW]
                     = (rename_valid[j] && (rename_rd[j * 5 +: 5] != 5'd0) && (rename_rd[j * 5 +: 5] == read_rs2[i * 5 +: 5]))
                     ? rename_new[j * PW +: PW] : f2c[(i * ISSUE_WIDTH + j - 1) * PW +: PW];
            end
            // 输出: slot 0 无转发 (直连阵列), 其余取链末级
            if (i == 0) begin : s0
                assign map_out1[0 * PW +: PW] = map_r[read_rs1[0 * 5 +: 5]];
                assign map_out2[0 * PW +: PW] = map_r[read_rs2[0 * 5 +: 5]];
            end else begin : sn
                assign map_out1[i * PW +: PW] = f1c[(i * ISSUE_WIDTH + i - 1) * PW +: PW];
                assign map_out2[i * PW +: PW] = f2c[(i * ISSUE_WIDTH + i - 1) * PW +: PW];
            end
        end
    endgenerate
endmodule
