// 分支历史表: BHT_SIZE 个 2-bit 饱和计数器 (复位 2'b01 = 弱不取)
// 全阵列读出 (fetch 按 pc 索引), W 写口按槽序依次应用 (同索引重复取低槽结果)
module bht #(
    parameter ISSUE_WIDTH = 1,
    parameter BHT_SIZE    = 32
) (
    output [2 * BHT_SIZE - 1 : 0]         counters,     // counters[i] = 计数器 i 的 2-bit 值
    input  [ISSUE_WIDTH - 1 : 0]        upd_req,      // 槽 i: 条件分支执行 → 更新
    input  [ISSUE_WIDTH * $clog2(BHT_SIZE) - 1 : 0]     upd_idx,      // 槽 i: 索引 (pc>>2)%BHT_SIZE
    input  [ISSUE_WIDTH - 1 : 0]        upd_taken     // 槽 i: 实际方向
);
    localparam BW = $clog2(BHT_SIZE);
    // TODO(Phase B): reg [1:0] counters_r[BHT_SIZE] + 按槽序饱和更新
    assign counters = {2 * BHT_SIZE{1'b0}};
endmodule
