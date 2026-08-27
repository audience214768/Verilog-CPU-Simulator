// 装载/存储队列: 发射建条目, 执行写 addr/data, load 发起需所有更老 store 已执行,
// 完成时字节合并前向 (未提交更老 store 的 data 覆盖重叠字节), 提交时 store 直写主存 / 条目失效
// 窗口 [head,last); head 推进跳过被 flush 的洞; 写优先级 flush > invalidate > push > set_*
// 组合发起: 最老未完成 load (cand 距离链) + 更老 store 全执行 + !ld_busy
module lsq #(
    parameter ISSUE_WIDTH = 1,
    parameter LSQ_SIZE    = 16,
    parameter PRF_SIZE    = 64,
    parameter ROB_SIZE    = 32
) (
    input  clk,
    input  rst_n,
    // A: 指针/状态
    output [$clog2(LSQ_SIZE) - 1 : 0]     head, last,
    output              full,
    output [$clog2(LSQ_SIZE + 1) - 1 : 0]    free_count,     // 当前空闲 (本拍失效数由 cpu_top 相加)
    output [LSQ_SIZE - 1 : 0] valid, is_load, addr_ready, data_ready,
    // A: 内容 (commit 读 store 数据)
    output [LSQ_SIZE * 32 - 1 : 0] addr, data,
    output [LSQ_SIZE * $clog2(ROB_SIZE) - 1 : 0] rob_tag,
    output [LSQ_SIZE * $clog2(PRF_SIZE) - 1 : 0] prs2_or_prd,   // store: rs2 的 preg; load: 目的 preg
    output [LSQ_SIZE * 2 - 1 : 0]  width,         // 00=1 01=2 10=4 字节
    output [LSQ_SIZE - 1 : 0]    is_unsigned,
    // C: 年龄比较
    input  [$clog2(ROB_SIZE) - 1 : 0]     rob_head,
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * $clog2(ROB_SIZE) - 1 : 0] push_rob_tag,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_prs2_or_prd,
    input  [ISSUE_WIDTH * 2 - 1 : 0]  push_width,
    input  [ISSUE_WIDTH - 1 : 0]    push_is_unsigned, push_is_load,
    input  [ISSUE_WIDTH - 1 : 0]    set_addr_req,   // 执行槽 i (地址 = alu 结果)
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] set_addr_idx,   // 槽 i 的 lsq_tag
    input  [ISSUE_WIDTH * 32 - 1 : 0] set_addr_val,
    input  [ISSUE_WIDTH - 1 : 0]    set_data_req,   // 仅 store
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] set_data_idx,
    input  [ISSUE_WIDTH * 32 - 1 : 0] set_data_val,
    input  [LSQ_SIZE - 1 : 0]       flush_mask,     // 窗口内条目失效
    input  [LSQ_SIZE - 1 : 0]       invalidate,     // store/load 提交后失效
    // 内存接口
    input               mem_done_valid,
    input  [$clog2(LSQ_SIZE) - 1 : 0]     mem_done_idx,
    input  [31 : 0]       mem_done_data,
    output              ld_start_valid,     // 组合发起: 最老未完成 load + 更老 store 全执行 + 有空槽
    output [31 : 0]       ld_start_addr,
    output [1 : 0]        ld_start_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]     ld_start_idx,
    input               ld_busy,            // memory 飞行槽满
    // 汇出: load 完成 → CDB 槽 W
    output              load_cdb_valid,
    output [$clog2(PRF_SIZE) - 1 : 0]     load_cdb_prd,
    output [31 : 0]       load_cdb_result,
    output [$clog2(ROB_SIZE) - 1 : 0]     load_cdb_rob_tag,
    output              load_cdb_rob_wr
);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam LCW = $clog2(LSQ_SIZE + 1);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);

    // ---- 状态 ----
    reg [LSQ_SIZE - 1 : 0]  valid_r, is_load_r, addr_ready_r, data_ready_r, done_r;
    reg [LSQ_SIZE * 32 - 1 : 0] addr_r, data_r;
    reg [LSQ_SIZE * RW - 1 : 0] rob_tag_r;
    reg [LSQ_SIZE * PW - 1 : 0] prs2_or_prd_r;
    reg [LSQ_SIZE * 2 - 1 : 0]  width_r;
    reg [LSQ_SIZE - 1 : 0]  is_unsigned_r;
    reg [LW - 1 : 0]    head_r, last_r;
    reg [LCW - 1 : 0]   free_count_r;

    // ---- push 槽偏移 (同 rob: psum[k] = 前 k 个 push 数) ----
    wire [(ISSUE_WIDTH + 1) * LCW - 1 : 0] psum;
    genvar gp;
    generate
        assign psum[0 * LCW +: LCW] = {LCW{1'b0}};
        for (gp = 0; gp < ISSUE_WIDTH; gp = gp + 1) begin : ps
            assign psum[(gp + 1) * LCW +: LCW] = psum[gp * LCW +: LCW] + push_valid[gp];
        end
    endgenerate
    wire [LCW - 1 : 0] push_cnt = psum[ISSUE_WIDTH * LCW +: LCW];

    // ---- flush 连续跳过数 (head 处连续被 flush 的条目数, 限窗口内) ----
    wire [LW - 1 : 0] winlen = (last_r - head_r) & (LSQ_SIZE - 1);
    function [LCW - 1 : 0] flush_skip_f;
        input [LSQ_SIZE - 1 : 0] mask;
        input [LW - 1 : 0]       h;
        input [LW - 1 : 0]       wl;
        integer k;
        begin
            // 仅跳过 head 处连续被 flush 的条目; 遇到第一个未 flush 条目即停
            flush_skip_f = {LCW{1'b0}};
            for (k = 0; (k < LSQ_SIZE) && (k < wl)
                     && mask[(h + k) & (LSQ_SIZE - 1)]; k = k + 1)
                flush_skip_f = flush_skip_f + 1'b1;
        end
    endfunction
    wire [LCW - 1 : 0] flush_skip = flush_skip_f(flush_mask, head_r, winlen);

    // ---- posedge 写 (优先级: flush > invalidate > push > set_*; 指针更新) ----
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_r <= {LSQ_SIZE{1'b0}};
            is_load_r <= {LSQ_SIZE{1'b0}};
            addr_ready_r <= {LSQ_SIZE{1'b0}};
            data_ready_r <= {LSQ_SIZE{1'b0}};
            done_r <= {LSQ_SIZE{1'b0}};
            addr_r <= {LSQ_SIZE * 32{1'b0}};
            data_r <= {LSQ_SIZE * 32{1'b0}};
            rob_tag_r <= {LSQ_SIZE * RW{1'b0}};
            prs2_or_prd_r <= {LSQ_SIZE * PW{1'b0}};
            width_r <= {LSQ_SIZE * 2{1'b0}};
            is_unsigned_r <= {LSQ_SIZE{1'b0}};
            head_r <= {LW{1'b0}};
            last_r <= {LW{1'b0}};
            free_count_r <= LSQ_SIZE[LCW - 1 : 0];
        end else begin
            // 1) flush / invalidate: 失效 (洞保留, head 推进跳过)
            for (i = 0; i < LSQ_SIZE; i = i + 1) begin
                if (flush_mask[i])  valid_r[i] <= 1'b0;
                if (invalidate[i])  valid_r[i] <= 1'b0;
            end
            // 2) push: 在 last + psum 处建条目
            for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin
                if (push_valid[i]) begin
                    valid_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= 1'b1;
                    is_load_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= push_is_load[i];
                    addr_ready_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= 1'b0;
                    data_ready_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= 1'b0;
                    done_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= 1'b0;
                    rob_tag_r[((last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)) * RW +: RW]
                        <= push_rob_tag[i * RW +: RW];
                    prs2_or_prd_r[((last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)) * PW +: PW]
                        <= push_prs2_or_prd[i * PW +: PW];
                    width_r[((last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)) * 2 +: 2]
                        <= push_width[i * 2 +: 2];
                    is_unsigned_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)]
                        <= push_is_unsigned[i];
                end
            end
            // 3) set_addr / set_data (执行结果)
            for (i = 0; i < ISSUE_WIDTH; i = i + 1) begin
                if (set_addr_req[i]) begin
                    addr_r[set_addr_idx[i * LW +: LW] * 32 +: 32] <= set_addr_val[i * 32 +: 32];
                    addr_ready_r[set_addr_idx[i * LW +: LW]] <= 1'b1;
                end
                if (set_data_req[i]) begin
                    data_r[set_data_idx[i * LW +: LW] * 32 +: 32] <= set_data_val[i * 32 +: 32];
                    data_ready_r[set_data_idx[i * LW +: LW]] <= 1'b1;
                end
            end
            // 4) load 完成标记 (仅有效 load 条目)
            if (mem_done_valid && valid_r[mem_done_idx] && is_load_r[mem_done_idx])
                done_r[mem_done_idx] <= 1'b1;
            // 5) 指针更新
            head_r <= head_r + flush_skip + (|invalidate);
            last_r <= last_r + push_cnt;
            free_count_r <= free_count_r - push_cnt + flush_skip + (|invalidate);
        end
    end

    // ---- 组合发起: 距离链 store_ok[d] = 前 d 个条目无未执行 store ----
    wire [LSQ_SIZE : 0] store_ok;
    wire [LSQ_SIZE - 1 : 0] cand;
    genvar gd;
    generate
        assign store_ok[0] = 1'b1;
        for (gd = 0; gd < LSQ_SIZE; gd = gd + 1) begin : iss
            wire [LW - 1 : 0] idx = (head_r + gd) & (LSQ_SIZE - 1);
            wire              in_win = (gd < winlen);
            wire              is_bad_store = valid_r[idx] && !is_load_r[idx]
                                          && !(addr_ready_r[idx] && data_ready_r[idx]);
            assign store_ok[gd + 1] = store_ok[gd] && (in_win ? !is_bad_store : 1'b1);
            assign cand[gd] = in_win && valid_r[idx] && is_load_r[idx]
                           && addr_ready_r[idx] && !done_r[idx] && store_ok[gd];
        end
    endgenerate
    // 最老候选 = 最小距离
    function [LW - 1 : 0] first_one_f;
        input [LSQ_SIZE - 1 : 0] c;
        integer k;
        begin
            first_one_f = {LW{1'b0}};
            for (k = LSQ_SIZE - 1; k >= 0; k = k - 1)
                if (c[k]) first_one_f = k[LW - 1 : 0];
        end
    endfunction
    wire [LW - 1 : 0] pidx = first_one_f(cand);
    assign ld_start_valid = |cand && !ld_busy;
    assign ld_start_addr  = addr_r[pidx * 32 +: 32];
    assign ld_start_width = width_r[pidx * 2 +: 2];
    assign ld_start_idx   = pidx;

    // ---- load 完成: 字节合并前向 + 符号扩展 (组合, 丢弃失效条目) ----
    wire ld_ok = mem_done_valid && valid_r[mem_done_idx] && is_load_r[mem_done_idx];
    wire [LW : 0] ddi = (mem_done_idx - head_r) & (LSQ_SIZE - 1);

    // 字节 b 的最终值: 最年轻重叠未提交 store 的 data, 否则内存字节
    // 注意: 状态全部作为参数传入 (iverilog 连续赋值中的函数只对参数变化重算,
    // 对函数体引用的模块级信号不建立事件依赖 → 同拍状态变化会得到陈旧输出)
    function [7 : 0] merge_byte_f;
        input [7 : 0]     b;
        input [31 : 0]    la;
        input [LW : 0]    dd;
        input [31 : 0]    md;
        input [LSQ_SIZE - 1 : 0]      v, il, ar, drd;     // 条目状态
        input [LSQ_SIZE * 2 - 1 : 0]  wr;                 // 宽度
        input [LSQ_SIZE * 32 - 1 : 0] ad, dt;             // 地址/数据
        input [LW - 1 : 0]            hd;                 // head
        integer j;
        reg [LW - 1 : 0] bj;
        reg [LW : 0]     dj;
        reg [7 : 0]      bo;
        reg              found;      // found 标志: dj==0 (head 处 store) 也是合法匹配
        begin
            found = 1'b0;
            bj = {LW{1'b0}};
            dj = {LW + 1{1'b0}};
            for (j = 0; j < LSQ_SIZE; j = j + 1) begin
                if (v[j] && !il[j] && ar[j] && drd[j]
                 && (((j - hd) & (LSQ_SIZE - 1)) < dd)
                 && ((la + b) >= ad[j * 32 +: 32])
                 && ((la + b) < (ad[j * 32 +: 32] + ((wr[j * 2 +: 2] == 2'b10) ? 32'd4
                                                    : (wr[j * 2 +: 2] == 2'b01) ? 32'd2
                                                                                : 32'd1)))) begin
                    if (!found || (((j - hd) & (LSQ_SIZE - 1)) >= dj)) begin
                        found = 1'b1;
                        dj = (j - hd) & (LSQ_SIZE - 1);
                        bj = j;
                    end
                end
            end
            bo = (la + b - ad[bj * 32 +: 32]) * 8;
            merge_byte_f = found ? dt[bj * 32 + bo +: 8]
                                 : md[b * 8 +: 8];
        end
    endfunction
    wire [7 : 0] mb0 = merge_byte_f(8'd0, addr_r[mem_done_idx * 32 +: 32], ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb1 = merge_byte_f(8'd1, addr_r[mem_done_idx * 32 +: 32], ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb2 = merge_byte_f(8'd2, addr_r[mem_done_idx * 32 +: 32], ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb3 = merge_byte_f(8'd3, addr_r[mem_done_idx * 32 +: 32], ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);

    assign load_cdb_valid    = ld_ok;
    assign load_cdb_prd      = prs2_or_prd_r[mem_done_idx * PW +: PW];
    assign load_cdb_rob_tag  = rob_tag_r[mem_done_idx * RW +: RW];
    assign load_cdb_rob_wr   = ld_ok;
    assign load_cdb_result   = (width_r[mem_done_idx * 2 +: 2] == 2'b10)
                             ? {mb3, mb2, mb1, mb0}
                             : (width_r[mem_done_idx * 2 +: 2] == 2'b01)
                               ? (is_unsigned_r[mem_done_idx] ? {16'd0, mb1, mb0}
                                                              : {{16{mb1[7]}}, mb1, mb0})
                               : (is_unsigned_r[mem_done_idx] ? {24'd0, mb0}
                                                              : {{24{mb0[7]}}, mb0});

    // ---- 输出 ----
    assign head       = head_r;
    assign last       = last_r;
    assign full       = (free_count_r == 0);
    assign free_count = free_count_r;
    assign valid      = valid_r;
    assign is_load    = is_load_r;
    assign addr_ready = addr_ready_r;
    assign data_ready = data_ready_r;
    assign addr       = addr_r;
    assign data       = data_r;
    assign rob_tag    = rob_tag_r;
    assign prs2_or_prd = prs2_or_prd_r;
    assign width      = width_r;
    assign is_unsigned = is_unsigned_r;
endmodule
