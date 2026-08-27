// 主存: 字节寻址 RAM (初始 0 + 可选 INIT_FILE), 取指同步读, load 飞行槽 (MEM_LATENCY 倒计时),
// store 提交直写, init 口供 TB 逐字节加载
// 被 flush 的 load 完成脉冲由 lsq.v 按条目有效性丢弃 (飞行槽不取消)
// 注意: initial 清零/readmemh 仅仿真 (综合时忽略, 面积预算按小 MEM_SIZE 评估)
module memory #(
    parameter ISSUE_WIDTH  = 1,
    parameter MEM_SIZE     = 65536,
    parameter MEM_LATENCY  = 3,     // load 延迟 (消融扫 1/3/6; RAM 本身零延迟, 纯性能建模)
    parameter MEM_INFLIGHT = 4,     // 飞行 load 槽数
    parameter LSQ_SIZE     = 16,
    parameter INIT_FILE    = ""     // 非空: 仿真初始化 $readmemh (每行 8 位 hex, 支持 @地址)
) (
    input  clk,
    input  rst_n,
    // 取指: 同步读 (地址寄存一拍)
    output [ISSUE_WIDTH * 32 - 1 : 0] inst_data,
    input  [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    // load: 发起 ≤1/周期, 完成 ≤1/周期 (倒计时到期, 同步读打包)
    input               ld_start_valid,
    input  [31 : 0]       ld_start_addr,
    input  [1 : 0]        ld_start_width,     // 00=1 01=2 10=4 字节
    input  [$clog2(LSQ_SIZE) - 1 : 0]     ld_start_idx,       // lsq 条目号 (完成时回传)
    output              ld_done_valid,
    output [$clog2(LSQ_SIZE) - 1 : 0]     ld_done_idx,
    output [31 : 0]       ld_done_data,
    output              ld_busy,            // 飞行槽满
    // store: 提交直写 ≤1/周期
    input               sw_valid,
    input  [31 : 0]       sw_addr,
    input  [31 : 0]       sw_data,
    input  [1 : 0]        sw_width,           // 00=1 01=2 10=4 字节
    // init: TB 字节写 (仿真加载)
    input               init_valid,
    input  [31 : 0]       init_addr,
    input  [7 : 0]        init_data
);
    localparam LW   = $clog2(LSQ_SIZE);
    localparam CNTW = $clog2(MEM_LATENCY + 1);   // 倒计时宽度

    // ---- 存储阵列 (仿真初始 0 + INIT_FILE) ----
    reg [7 : 0] mem [0 : MEM_SIZE - 1];
    integer mi;
    initial begin
        for (mi = 0; mi < MEM_SIZE; mi = mi + 1) mem[mi] = 8'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    // ---- 取指同步读: imem_addr 寄存一拍 → 4 字节小端打包 ----
    reg [ISSUE_WIDTH * 32 - 1 : 0] imem_addr_r;
    always @(posedge clk) begin
        if (!rst_n) imem_addr_r <= {ISSUE_WIDTH * 32{1'b0}};
        else        imem_addr_r <= imem_addr;
    end
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : fi
            assign inst_data[g * 32 +: 8]     = mem[imem_addr_r[g * 32 +: 32]];    // LSB
            assign inst_data[g * 32 + 8 +: 8] = mem[imem_addr_r[g * 32 +: 32] + 1];
            assign inst_data[g * 32 + 16 +: 8] = mem[imem_addr_r[g * 32 +: 32] + 2];
            assign inst_data[g * 32 + 24 +: 8] = mem[imem_addr_r[g * 32 +: 32] + 3];  // MSB
        end
    endgenerate

    // ---- load 飞行槽 ----
    reg [MEM_INFLIGHT - 1 : 0]  slot_valid;
    reg [MEM_INFLIGHT * CNTW - 1 : 0] slot_cnt;      // 倒计时 (1 = 本拍到期)
    reg [MEM_INFLIGHT * 32 - 1 : 0]  slot_addr;
    reg [MEM_INFLIGHT * 2 - 1 : 0]   slot_width;
    reg [MEM_INFLIGHT * LW - 1 : 0]  slot_idx;
    reg ld_done_valid_r;
    reg [LW - 1 : 0] ld_done_idx_r;
    reg [31 : 0]     ld_done_data_r;

    // 槽空闲: 无效或本拍到期 (完成拍后可复用)
    wire [MEM_INFLIGHT - 1 : 0] slot_free;
    genvar gs;
    generate
        for (gs = 0; gs < MEM_INFLIGHT; gs = gs + 1) begin : sf
            assign slot_free[gs] = !slot_valid[gs]
                                || (slot_cnt[gs * CNTW +: CNTW] == 1);
        end
    endgenerate
    assign ld_busy = !(|slot_free);

    // 第一个空闲槽 (发起专用, ≤1/周期)
    function [$clog2(MEM_INFLIGHT) - 1 : 0] first_free;
        input [MEM_INFLIGHT - 1 : 0] c;
        integer k;
        begin
            first_free = {$clog2(MEM_INFLIGHT){1'b0}};
            for (k = MEM_INFLIGHT - 1; k >= 0; k = k - 1)
                if (c[k]) first_free = k[$clog2(MEM_INFLIGHT) - 1 : 0];
        end
    endfunction
    wire [$clog2(MEM_INFLIGHT) - 1 : 0] free_slot = first_free(slot_free);

    // 打包读: 按宽度取字节 (小端, 高位补 0)
    function [31 : 0] rd_pack;
        input [31 : 0] a;
        input [1 : 0]  w;
        begin
            rd_pack = (w == 2'b10) ? {mem[a + 3], mem[a + 2], mem[a + 1], mem[a]}
                    : (w == 2'b01) ? {16'd0, mem[a + 1], mem[a]}
                    : {24'd0, mem[a]};
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            slot_valid <= {MEM_INFLIGHT{1'b0}};
            ld_done_valid_r <= 1'b0;
        end else begin
            ld_done_valid_r <= 1'b0;
            // 倒计时 + 到期完成
            for (i = 0; i < MEM_INFLIGHT; i = i + 1) begin
                if (slot_valid[i]) begin
                    if (slot_cnt[i * CNTW +: CNTW] == 1) begin
                        slot_valid[i] <= 1'b0;
                        ld_done_valid_r <= 1'b1;
                        ld_done_idx_r  <= slot_idx[i * LW +: LW];
                        ld_done_data_r <= rd_pack(slot_addr[i * 32 +: 32],
                                                  slot_width[i * 2 +: 2]);
                    end else begin
                        slot_cnt[i * CNTW +: CNTW] <= slot_cnt[i * CNTW +: CNTW] - 1'b1;
                    end
                end
            end
            // 发起 (仅写第一个空闲槽, 可复用本拍到期槽)
            if (ld_start_valid) begin
                slot_valid[free_slot] <= 1'b1;
                slot_cnt[free_slot * CNTW +: CNTW] <= MEM_LATENCY[CNTW - 1 : 0];
                slot_addr[free_slot * 32 +: 32] <= ld_start_addr;
                slot_width[free_slot * 2 +: 2]  <= ld_start_width;
                slot_idx[free_slot * LW +: LW]  <= ld_start_idx;
            end
        end
    end

    // ---- store 提交直写 (≤1/周期) + init 字节写 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            // 无状态
        end else begin
            if (sw_valid) begin
                case (sw_width)
                    2'b00: mem[sw_addr] <= sw_data[7 : 0];
                    2'b01: begin
                        mem[sw_addr]     <= sw_data[7 : 0];
                        mem[sw_addr + 1] <= sw_data[15 : 8];
                    end
                    default: begin
                        mem[sw_addr]     <= sw_data[7 : 0];
                        mem[sw_addr + 1] <= sw_data[15 : 8];
                        mem[sw_addr + 2] <= sw_data[23 : 16];
                        mem[sw_addr + 3] <= sw_data[31 : 24];
                    end
                endcase
            end
            if (init_valid) mem[init_addr] <= init_data;
        end
    end

    assign ld_done_valid = ld_done_valid_r;
    assign ld_done_idx   = ld_done_idx_r;
    assign ld_done_data  = ld_done_data_r;
endmodule
