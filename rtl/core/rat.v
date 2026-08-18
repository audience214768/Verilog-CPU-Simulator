// 寄存器别名表: 32×$clog2(PRF_SIZE) 映射, 复位恒等 map[i]=i
// 组合读口含批内转发: slot i 的读看到 rename[j] (j<i) 的映射 (最后匹配者赢)
// flush (walker 回滚) 写优先级 > rename
module rat #(
    parameter ISSUE_WIDTH = 1,
    parameter PRF_SIZE    = 64
) (
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
    // TODO(Phase B): reg [$clog2(PRF_SIZE)-1:0] map_r[0:31] + 批内转发读口 + rename/flush 写
    assign map_out1 = {ISSUE_WIDTH * $clog2(PRF_SIZE){1'b0}};
    assign map_out2 = {ISSUE_WIDTH * $clog2(PRF_SIZE){1'b0}};
    assign map_arch = {32 * $clog2(PRF_SIZE){1'b0}};
endmodule
