// 重排序缓冲: 环形 (ROB_SIZE = 2^RW), 乱序完成按序提交
// 写优先级: set_last (flush 截断, 最高; head 若被截则收敛到 last+1) > set_head (提交) > set_ready (CDB) > push
// push 时清该条目 ready; set_ready_req 为 ready 唯一置位源
module rob #(
    parameter ISSUE_WIDTH = 1,
    parameter ROB_SIZE    = 32,
    parameter PRF_SIZE    = 64,
    parameter LSQ_SIZE    = 16
) (
    input  clk,
    input  rst_n,
    // A: 指针/状态
    output [$clog2(ROB_SIZE) - 1 : 0]     head, last,
    output              empty, full,
    output [$clog2(ROB_SIZE + 1) - 1 : 0]    free_count,     // 当前空闲 (本拍提交数由 cpu_top 另行相加)
    // A: 条目数组 (commit/walker 用)
    output [ROB_SIZE - 1 : 0]       ready,          // 完成位 (唯一写者: set_ready_req)
    output [ROB_SIZE * 7 - 1 : 0]     opcode,         // 原始 opcode[6:0] (commit 分派)
    output [ROB_SIZE * 5 - 1 : 0]     rd,
    output [ROB_SIZE * $clog2(PRF_SIZE) - 1 : 0]    new_pnum,       // 目的 preg; ==0 ⟺ 无 prd
    output [ROB_SIZE * $clog2(PRF_SIZE) - 1 : 0]    old_pnum,       // rename 前映射 (commit 回收/walker 回滚)
    output [ROB_SIZE * $clog2(LSQ_SIZE) - 1 : 0]    lsq_tag,        // store/load 的 LSQ 条目号
    output [ROB_SIZE * 32 - 1 : 0]    ins_raw,        // 终止标记检测
    // B: 写
    input  [ISSUE_WIDTH - 1 : 0]    push_valid,
    input  [ISSUE_WIDTH * 7 - 1 : 0]  push_opcode,
    input  [ISSUE_WIDTH * 5 - 1 : 0]  push_rd,
    input  [ISSUE_WIDTH * $clog2(PRF_SIZE) - 1 : 0] push_new, push_old,
    input  [ISSUE_WIDTH * $clog2(LSQ_SIZE) - 1 : 0] push_lsq_tag,
    input  [ISSUE_WIDTH * 32 - 1 : 0] push_ins_raw,
    input               set_head_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]     set_head_val,
    input               set_last_valid,
    input  [$clog2(ROB_SIZE) - 1 : 0]     set_last_val,
    input  [ROB_SIZE - 1 : 0] set_ready_req
);
    localparam RW  = $clog2(ROB_SIZE);
    localparam PW  = $clog2(PRF_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam RCW = $clog2(ROB_SIZE + 1);

    reg [RW - 1 : 0]  head_r, last_r;
    reg [RCW - 1 : 0] free_r;
    reg              ready_r [0 : ROB_SIZE - 1];
    reg [6 : 0]      opcode_r [0 : ROB_SIZE - 1];
    reg [4 : 0]      rd_r [0 : ROB_SIZE - 1];
    reg [PW - 1 : 0] new_r [0 : ROB_SIZE - 1];
    reg [PW - 1 : 0] old_r [0 : ROB_SIZE - 1];
    reg [LW - 1 : 0] lsq_r [0 : ROB_SIZE - 1];
    reg [31 : 0]     ins_r [0 : ROB_SIZE - 1];

    // ---- push 前缀计数 (槽 k 写 last_r + psum[k]; psum[k] = 前 k 条数, 不含自己) ----
    wire [(ISSUE_WIDTH + 1) * RCW - 1 : 0] psum;
    genvar c;
    generate
        for (c = 0; c < ISSUE_WIDTH + 1; c = c + 1) begin : psc
            if (c == 0) begin : b0
                assign psum[0 * RCW +: RCW] = {RCW{1'b0}};
            end else begin : bn
                assign psum[c * RCW +: RCW] = psum[(c - 1) * RCW +: RCW]
                                            + {{(RCW - 1){1'b0}}, push_valid[c - 1]};
            end
        end
    endgenerate
    wire [RCW - 1 : 0] push_cnt = psum[ISSUE_WIDTH * RCW +: RCW];

    // ---- 组合 next (优先级: set_last > set_head) ----
    // set_head 释放: head 前进 d_h 条 (与 push 同拍: 先减 push 再加释放)
    wire [RW - 1 : 0] d_h = set_head_val - head_r;
    wire [RCW - 1 : 0] free_after_head = free_r + d_h - push_cnt;
    // set_last 截断: 窗口 [head, last) 截到 [head, val); val 回绕落后于 head 则清空 (head=last=val+1)
    // d_old = 窗口大小 (empty→0, full→ROB_SIZE); keep 判据: d_new <= d_old
    // 注意 d_new 须先在 RW 位内回绕再零扩展 (6 位上下文会得到 62 而非 30)
    wire [RCW - 1 : 0] d_old = ROB_SIZE - free_r;
    wire [RW - 1 : 0]  d_new_rw = set_last_val - head_r;
    wire [RCW - 1 : 0] d_new = {1'b0, d_new_rw};
    wire              keep_head = (d_new <= d_old);
    wire [RW - 1 : 0] head_after_last = keep_head ? head_r : (set_last_val + 1);
    wire [RW - 1 : 0] last_after_last = keep_head ? set_last_val : (set_last_val + 1);
    wire [RW - 1 : 0] d_f = last_after_last - head_after_last; // 截断后窗口大小 (回绕; 清空时为 0)
    wire [RCW - 1 : 0] free_after_last = ROB_SIZE - d_f;
    wire [RCW - 1 : 0] free_next = set_last_valid ? free_after_last
                                 : set_head_valid ? free_after_head
                                 : free_r - push_cnt;
    wire [RW - 1 : 0] head_next = set_last_valid ? head_after_last
                                : set_head_valid ? set_head_val : head_r;
    wire [RW - 1 : 0] last_next = set_last_valid ? last_after_last : (last_r + push_cnt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_r  <= {RW{1'b0}};
            last_r  <= {RW{1'b0}};
            free_r  <= ROB_SIZE;
        end else begin
            head_r  <= head_next;
            last_r  <= last_next;
            free_r  <= free_next;
        end
    end

    // ---- 条目写: push (清 ready) 与 set_ready (置位); 优先级 set_ready > push 由顺序保证 ----
    integer k, i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < ROB_SIZE; i = i + 1) begin
                ready_r[i] <= 1'b0;
                opcode_r[i] <= 7'd0;
                rd_r[i] <= 5'd0;
                new_r[i] <= {PW{1'b0}};
                old_r[i] <= {PW{1'b0}};
                lsq_r[i] <= {LW{1'b0}};
                ins_r[i] <= 32'd0;
            end
        end else begin
            // push: 写入 last_r + psum[k] (回绕掩码) 并清 ready (后于 set_ready 执行 → 优先级高)
            for (k = 0; k < ISSUE_WIDTH; k = k + 1) begin
                if (push_valid[k]) begin
                    i = (last_r + psum[k * RCW +: RCW]) & (ROB_SIZE - 1);
                    opcode_r[i] <= push_opcode[k * 7 +: 7];
                    rd_r[i]     <= push_rd[k * 5 +: 5];
                    new_r[i]    <= push_new[k * PW +: PW];
                    old_r[i]    <= push_old[k * PW +: PW];
                    lsq_r[i]    <= push_lsq_tag[k * LW +: LW];
                    ins_r[i]    <= push_ins_raw[k * 32 +: 32];
                    ready_r[i]  <= 1'b0;
                end
            end
            // set_ready: CDB 完成置位
            for (i = 0; i < ROB_SIZE; i = i + 1)
                if (set_ready_req[i])
                    ready_r[i] <= 1'b1;
        end
    end

    // ---- 输出 ----
    assign head       = head_r;
    assign last       = last_r;
    assign empty      = (free_r == ROB_SIZE);
    assign full       = (free_r == 0);
    assign free_count = free_r;
    genvar a;
    generate
        for (a = 0; a < ROB_SIZE; a = a + 1) begin : out
            assign ready[a]        = ready_r[a];
            assign opcode[a * 7 +: 7]     = opcode_r[a];
            assign rd[a * 5 +: 5]         = rd_r[a];
            assign new_pnum[a * PW +: PW] = new_r[a];
            assign old_pnum[a * PW +: PW] = old_r[a];
            assign lsq_tag[a * LW +: LW]  = lsq_r[a];
            assign ins_raw[a * 32 +: 32]  = ins_r[a];
        end
    endgenerate
endmodule
