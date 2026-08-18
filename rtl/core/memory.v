// 主存: 字节寻址 RAM (初始 0 + 可选 INIT_FILE), 取指同步读, load 飞行槽 (MEM_LATENCY 倒计时),
// store 提交直写, init 口供 TB 逐字节加载
// 被 flush 的 load 完成脉冲由 lsq.v 按条目有效性丢弃 (飞行槽不取消)
module memory #(
    parameter ISSUE_WIDTH  = 1,
    parameter MEM_SIZE     = 65536,
    parameter MEM_LATENCY  = 3,     // load 延迟 (消融扫 1/3/6; RAM 本身零延迟, 纯性能建模)
    parameter MEM_INFLIGHT = 4,     // 飞行 load 槽数
    parameter LSQ_SIZE     = 16,
    parameter INIT_FILE    = ""     // 非空: 仿真初始化 $readmemh (每行 8 位 hex, 支持 @地址)
) (
    // 取指: 同步读 (地址寄存一拍)
    output [ISSUE_WIDTH * 32 - 1 : 0] inst_data,
    input  [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    // load: 发起 ≤1/周期, 完成 ≤1/周期 (倒计时到期, 同步读打包)
    input               ld_start_valid,
    input  [31 : 0]       ld_start_addr,
    input  [1 : 0]        ld_start_width,     // 1/2/4 字节
    input  [$clog2(LSQ_SIZE) - 1 : 0]     ld_start_idx,       // lsq 条目号 (完成时回传)
    output              ld_done_valid,
    output [$clog2(LSQ_SIZE) - 1 : 0]     ld_done_idx,
    output [31 : 0]       ld_done_data,
    output              ld_busy,            // 飞行槽满
    // store: 提交直写 ≤1/周期
    input               sw_valid,
    input  [31 : 0]       sw_addr,
    input  [31 : 0]       sw_data,
    input  [1 : 0]        sw_width,
    // init: TB 字节写 (仿真加载)
    input               init_valid,
    input  [31 : 0]       init_addr,
    input  [7 : 0]        init_data
);
    localparam LW = $clog2(LSQ_SIZE);
    // TODO(Phase B): reg [7:0] mem[0:MEM_SIZE-1] + 飞行槽数组 + 同步读
    assign inst_data = {ISSUE_WIDTH * 32{1'b0}};
    assign ld_done_valid = 1'b0;
    assign ld_done_idx   = {$clog2(LSQ_SIZE){1'b0}};
    assign ld_done_data  = 32'd0;
    assign ld_busy       = 1'b0;
endmodule
