// 装载/存储队列: 发射建条目, 执行写 addr/data, load 发起需所有更老 store 已执行,
// 完成时字节合并前向 (未提交更老 store 的 data 覆盖重叠字节), 提交时 store 直写主存 / 条目失效
// 窗口 [head,last): 环形容量保留 1 槽 (占用 ≤ LSQ_SIZE-1) → head==last 唯一表示"空",
// 否则 (last-head) 同时表示 0 与 LSQ_SIZE, 窗口被判成空 → 无 load 可发起且 head 不再前进 = 死锁
// head 每拍无条件推进跳过 head 处的连续"死条目"(洞 + 当拍 flush + 当拍提交失效),
// free_count 由 head/last 组合导出 (= 本拍可 push 数, 已含本拍失效腾出的槽; cpu_top 不再另加)
// 写优先级 flush > invalidate > push > set_*; 发起置位 issued 先于完成清 issued (同拍时完成胜)
//
// in-flight 协议 (issued_r): 条目号 mem_done_idx 是完成与请求之间唯一的身份标识,
// 因此"条目号 → 请求"必须一一对应, 否则完成会落到复用后的新条目上写坏目的寄存器:
//   ① 发起后 issued_r=1, 该条目不再参与 cand → 同一 load 只进一个飞行槽 (不会重复发起,
//      否则一个 load 产生多个完成脉冲, 首个完成置 done 后条目被提交/复用, 余下的陈旧完成
//      就把旧数据写进新条目的 prs2_or_prd);
//   ② issued_r=1 的条目即使 valid_r 被 flush/invalidate 清掉也不算死条目 → head 不会跳过它,
//      槽位不会被 push 复用, 直到完成脉冲回来才清 issued_r (之后才可回收)。
//      代价: flush 时若恰有在飞 load, head 最多阻塞 MEM_LATENCY 拍 (memory 槽必定倒计时到期)。
// 组合发起: 最老未完成 load (cand 距离链) + 更老 store 全执行 + !ld_busy + !issued
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
    output [$clog2(LSQ_SIZE + 1) - 1 : 0]    free_count,     // 本拍可 push 数 (已含本拍失效腾出的槽)
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
    input  [$clog2(LSQ_SIZE) - 1 : 0]     mem_done_idx,
    input  [LSQ_SIZE - 1 : 0]  mem_done_oh,    // ★ 刀 Q: 同一个索引的 one-hot (含 valid), 边界寄存器直接给
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
    reg [LSQ_SIZE - 1 : 0]  issued_r;       // 该条目已有 load 请求在飞 (完成脉冲未回)
    reg [LSQ_SIZE * 32 - 1 : 0] addr_r, data_r;
    reg [LSQ_SIZE * RW - 1 : 0] rob_tag_r;
    reg [LSQ_SIZE * PW - 1 : 0] prs2_or_prd_r;
    reg [LSQ_SIZE * 2 - 1 : 0]  width_r;
    reg [LSQ_SIZE - 1 : 0]  is_unsigned_r;
    reg [LW - 1 : 0]    head_r, last_r;

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

    // ---- 窗口长度 / head 处连续死条目数 (限窗口内) ----
    // winlen 是当前占用的槽数 (含洞); 因容量保留 1 槽, winlen ∈ [0, LSQ_SIZE-1], 0 只表示空
    wire [LW - 1 : 0] winlen = (last_r - head_r) & (LSQ_SIZE - 1);
    // 本拍被 flush/提交失效的条目 (posedge 才清 valid_r, 组合逻辑须提前当作已失效)
    wire [LSQ_SIZE - 1 : 0] kill = flush_mask | invalidate;
    // 死条目 = 洞 + 本拍被杀 + 在飞例外
    // 在飞条目 (issued_r) 即便 valid_r 被清也不算死: 完成脉冲按条目号回传, 槽位在完成前不可复用
    wire [LSQ_SIZE - 1 : 0] dead = (~valid_r | kill) & ~issued_r;
    function [LCW - 1 : 0] dead_skip_f;
        input [LSQ_SIZE - 1 : 0] dead;
        input [LW - 1 : 0]       h;
        input [LW - 1 : 0]       wl;
        integer k;
        reg     go;
        begin
            // 仅跳过 head 处连续的死条目; 遇到第一个活条目即停
            // 循环上界必须为常量 (Yosys 不支持变量上界), 首次不满足即置 go=0 提前停止
            dead_skip_f = {LCW{1'b0}};
            go = 1'b1;
            for (k = 0; k < LSQ_SIZE; k = k + 1) begin
                if (go && (k < wl) && dead[(h + k) & (LSQ_SIZE - 1)])
                    dead_skip_f = dead_skip_f + 1'b1;
                else
                    go = 1'b0;
            end
        end
    endfunction
    wire [LCW - 1 : 0] skip = dead_skip_f(dead, head_r, winlen);
    // 本拍可 push 数 = 保留 1 槽 - 当前占用 + 本拍被跳过的槽 (跳过的槽本拍即可复用)
    wire [LCW - 1 : 0] free_count_w = LSQ_SIZE[LCW - 1 : 0] - 1'b1 - {1'b0, winlen} + skip;

    // ---- 组合发起: 距离链 store_ok[d] = 前 d 个条目无未执行 store ----
    // (放在 posedge 块之前: 块的发起置位要用 pidx, iverilog 要求先声明后使用)
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
            // !kill: 本拍就被 flush/失效的条目不可发起 —— 否则 issued 与 valid 同拍更新,
            //        head 仍会照常跳过它 (skip 用的是边沿前的 issued=0), 槽位照样被复用 → 又失去身份
            assign cand[gd] = in_win && valid_r[idx] && is_load_r[idx]
                           && addr_ready_r[idx] && !issued_r[idx] && !done_r[idx]
                           && !kill[idx] && store_ok[gd];
        end
    endgenerate
    // 最老候选 = 最小距离 (cand 按距离索引: 位 k ↔ 条目 (head + k))
    function [LW - 1 : 0] first_one_f;
        input [LSQ_SIZE - 1 : 0] c;
        integer k;
        begin
            first_one_f = {LW{1'b0}};
            for (k = LSQ_SIZE - 1; k >= 0; k = k - 1)
                if (c[k]) first_one_f = k[LW - 1 : 0];
        end
    endfunction
    wire [LW - 1 : 0] pdist = first_one_f(cand);              // 距 head 的距离
    wire [LW - 1 : 0] pidx  = (head_r + pdist) & (LSQ_SIZE - 1);   // 实际条目号
    assign ld_start_valid = |cand && !ld_busy;
    assign ld_start_addr  = addr_r[pidx * 32 +: 32];
    assign ld_start_width = width_r[pidx * 2 +: 2];
    assign ld_start_idx   = pidx;

    // ★ 刀 Q (2026-10-11): 完成口的**索引读全改 one-hot AND-OR** (与 `cpu_top.v` 提交口 `lsq_oh`
    //   同一个写法)。原来 7 处 `arr[mem_done_idx * W +: W]` 综合成 16 选 1 宽译码 —— 索引 bit0
    //   单脚驱动 120 脚、级 1 INV 82 脚、级 2 NAND2 64 脚 (级 0~2 共 1.01 ns = 头名家族 (c) 的 21%)。
    //   one-hot 由**边界寄存器**(刀 D 的 `ld_done_*_q`)在 D 端译好 ⇒ 每个 oh 位只驱动"它自己条目"
    //   的位宽个门 (≈46), 索引位只剩 16 个 2 输入比较器且**越过寄存器后 abc 无法反推**。
    //   逐位等价: `arr[idx]` ≡ `|(arr[g] & oh[g])`; oh 已含 `mem_done_valid` ⇒ "无完成"时全 0,
    //   OR 天然为 0 (与 `lsq_oh` 注释同理), 不需要末级 `? : 0`。
    //   ★ `ddi` 仍用二进制索引 (年龄减法), 故 `mem_done_idx` 端口保留 —— 两者在边界寄存器同拍更新。
    //   选通口径: **五个字段的读**只认完成脉冲 `mem_done_oh` (被 flush 后回来的 load 也照读, 值无意义
    //   但确定); `valid`/`rob_wr`/`done` 另用 `ld_ok_oh` 再限定"命中有效 load" —— 与旧索引读同义。
    wire [LSQ_SIZE - 1 : 0] ld_ok_oh = mem_done_oh & valid_r & is_load_r;   // 完成脉冲命中一个**有效 load**
    wire ld_ok = |ld_ok_oh;
    wire [31 : 0]             md_addr_w;
    wire [PW - 1 : 0]         md_prd_w;
    wire [RW - 1 : 0]         md_tag_w;
    wire [1 : 0]              md_wid_w;
    wire                      md_uns_w;
    genvar gq, gr;
    generate
        for (gr = 0; gr < 32; gr = gr + 1) begin : mda
            wire [LSQ_SIZE - 1 : 0] t;
            for (gq = 0; gq < LSQ_SIZE; gq = gq + 1) begin : e
                assign t[gq] = addr_r[gq * 32 + gr] & mem_done_oh[gq];
            end
            assign md_addr_w[gr] = |t;
        end
        for (gr = 0; gr < PW; gr = gr + 1) begin : mdp
            wire [LSQ_SIZE - 1 : 0] t;
            for (gq = 0; gq < LSQ_SIZE; gq = gq + 1) begin : e
                assign t[gq] = prs2_or_prd_r[gq * PW + gr] & mem_done_oh[gq];
            end
            assign md_prd_w[gr] = |t;
        end
        for (gr = 0; gr < RW; gr = gr + 1) begin : mdt
            wire [LSQ_SIZE - 1 : 0] t;
            for (gq = 0; gq < LSQ_SIZE; gq = gq + 1) begin : e
                assign t[gq] = rob_tag_r[gq * RW + gr] & mem_done_oh[gq];
            end
            assign md_tag_w[gr] = |t;
        end
        for (gr = 0; gr < 2; gr = gr + 1) begin : mdw
            wire [LSQ_SIZE - 1 : 0] t;
            for (gq = 0; gq < LSQ_SIZE; gq = gq + 1) begin : e
                assign t[gq] = width_r[gq * 2 + gr] & mem_done_oh[gq];
            end
            assign md_wid_w[gr] = |t;
        end
        assign md_uns_w = |(is_unsigned_r & mem_done_oh);
    endgenerate

    // ---- posedge 写 (优先级: flush > invalidate > push > set_*; 指针更新) ----
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_r <= {LSQ_SIZE{1'b0}};
            is_load_r <= {LSQ_SIZE{1'b0}};
            addr_ready_r <= {LSQ_SIZE{1'b0}};
            data_ready_r <= {LSQ_SIZE{1'b0}};
            done_r <= {LSQ_SIZE{1'b0}};
            issued_r <= {LSQ_SIZE{1'b0}};
            addr_r <= {LSQ_SIZE * 32{1'b0}};
            data_r <= {LSQ_SIZE * 32{1'b0}};
            rob_tag_r <= {LSQ_SIZE * RW{1'b0}};
            prs2_or_prd_r <= {LSQ_SIZE * PW{1'b0}};
            width_r <= {LSQ_SIZE * 2{1'b0}};
            is_unsigned_r <= {LSQ_SIZE{1'b0}};
            head_r <= {LW{1'b0}};
            last_r <= {LW{1'b0}};
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
                    issued_r[(last_r + psum[i * LCW +: LCW]) & (LSQ_SIZE - 1)] <= 1'b0;
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
            // 4) 发起置位 (ld_start_valid 当拍被 memory 接收 → 该条目转为 in-flight, 不再进 cand)
            if (ld_start_valid) issued_r[pidx] <= 1'b1;
            // 5) 完成: 清 in-flight (无条件清 —— 已被 flush 的条目也靠它放开 head 跳过),
            //    有效条目再置 done 抑制重复发起。同拍 4)/5) 命中同一条目时 5) 胜 (完成后不再在飞)
            // ★ 刀 Q: 逐位写 (one-hot 已在边界寄存器译好)。优先级语义逐位不变 —— `ld_ok_oh` 已含
            //   `valid_r`/`is_load_r`/`mem_done_valid`, 且这两支写在 4) 之后 ⇒ 同拍命中同一条目时 5) 胜。
            for (i = 0; i < LSQ_SIZE; i = i + 1) begin
                if (mem_done_oh[i]) issued_r[i] <= 1'b0;
                if (ld_ok_oh[i])    done_r[i]   <= 1'b1;
            end
            // 6) 指针更新 (free_count 由 head/last 组合导出, 无独立状态)
            head_r <= head_r + skip;
            last_r <= last_r + push_cnt;
        end
    end

    // ---- load 完成: 字节合并前向 + 符号扩展 (组合, 丢弃失效条目) ----
    // (`ld_ok`/`ld_ok_oh` 与五个字段的 one-hot 读在 always 块**之前**声明 —— iverilog 要求先声明)
    wire [LW : 0] ddi = (mem_done_idx - head_r) & (LSQ_SIZE - 1);   // 年龄减法仍用索引 (刀 Q 保留)

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
    wire [7 : 0] mb0 = merge_byte_f(8'd0, md_addr_w, ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb1 = merge_byte_f(8'd1, md_addr_w, ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb2 = merge_byte_f(8'd2, md_addr_w, ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);
    wire [7 : 0] mb3 = merge_byte_f(8'd3, md_addr_w, ddi, mem_done_data,
                                    valid_r, is_load_r, addr_ready_r, data_ready_r, width_r,
                                    addr_r, data_r, head_r);

    assign load_cdb_valid    = ld_ok;
    assign load_cdb_prd      = md_prd_w;
    assign load_cdb_rob_tag  = md_tag_w;
    assign load_cdb_rob_wr   = ld_ok;
    assign load_cdb_result   = (md_wid_w == 2'b10)
                             ? {mb3, mb2, mb1, mb0}
                             : (md_wid_w == 2'b01)
                               ? (md_uns_w ? {16'd0, mb1, mb0}
                                           : {{16{mb1[7]}}, mb1, mb0})
                               : (md_uns_w ? {24'd0, mb0}
                                           : {{24{mb0[7]}}, mb0});

    // ---- 输出 ----
    assign head       = head_r;
    assign last       = last_r;
    assign full       = (free_count_w == 0);
    assign free_count = free_count_w;
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
