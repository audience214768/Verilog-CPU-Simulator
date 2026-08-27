// 分支历史表: BHT_SIZE 个 2-bit 饱和计数器 (复位 2'b01 = 弱不取)
// 全阵列读出 (fetch 按 pc 索引), W 写口按槽序倒序应用 (同索引低槽赢)
module bht #(
    parameter ISSUE_WIDTH = 1,
    parameter BHT_SIZE    = 32
) (
    input  clk,
    input  rst_n,
    output [2 * BHT_SIZE - 1 : 0]         counters,     // counters[i] = 计数器 i 的 2-bit 值
    input  [ISSUE_WIDTH - 1 : 0]        upd_req,      // 槽 i: 条件分支执行 → 更新
    input  [ISSUE_WIDTH * $clog2(BHT_SIZE) - 1 : 0]     upd_idx,      // 槽 i: 索引 (pc>>2)%BHT_SIZE
    input  [ISSUE_WIDTH - 1 : 0]        upd_taken     // 槽 i: 实际方向
);
    localparam BW = $clog2(BHT_SIZE);

    reg [1 : 0] counters_r [0 : BHT_SIZE - 1];

    // 每槽饱和更新值 (taken: <3 则 +1; 否则 >0 则 -1)
    wire [2 * ISSUE_WIDTH - 1 : 0] nv;
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : up
            wire [1 : 0] cur = counters_r[upd_idx[g * BW +: BW]];
            assign nv[g * 2 +: 2] = upd_taken[g]
                                  ? ((cur < 2'b11) ? (cur + 2'd1) : cur)
                                  : ((cur > 2'b00) ? (cur - 2'd1) : cur);
        end
    endgenerate

    // 倒序应用: 同索引低槽最后 NBA 写 → 低槽赢
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < BHT_SIZE; i = i + 1)
                counters_r[i] <= 2'b01;
        end else begin
            for (i = ISSUE_WIDTH - 1; i >= 0; i = i - 1)
                if (upd_req[i])
                    counters_r[upd_idx[i * BW +: BW]] <= nv[i * 2 +: 2];
        end
    end

    genvar go;
    generate
        for (go = 0; go < BHT_SIZE; go = go + 1) begin : out
            assign counters[go * 2 +: 2] = counters_r[go];
        end
    endgenerate
endmodule
