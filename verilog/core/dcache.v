// L1 数据缓存 (组相联; 每路的 tag 与数据同条目放进一块 sram_fakeram) —— 骨架照抄 core/icache.v
// 对外只做三件事: ①查表(接受一条 load) ②命中就当拍+1交付 ③缺失就发一笔 AR (并按行填充)
//
// 【为什么 tag 也放 SRAM】与 icache 同因 (那里是 imem_valid/imem_hit 要同拍); 这里的额外好处是
//   多路相联**不需要多个读口**: 一条目 = DC_WAYS 路 × (DC_LINE_WORDS 字 + 1 个 tag 槽), 一拍读出
//   所有路的 tag, T+1 并行比较即可。DFF tag 阵列太贵: 2 KiB/32 B 行/64 组 × 22 位 = 1408 flop
//   ≈ 534 µm² (0.37908 µm²/flop, 异步复位), 与数据阵列本身 (18432 bit ≈ 774 µm²) 同量级。
//
// 【★ 交付端口只有一个源 —— 全设计最关键的一条不变量】
//   命中在 T+1 交付, AXI 回包在任意拍交付, 二者可能撞车。LSQ 只有一个完成口 (lsq.v:221),
//   一拍丢一个脉冲 = 那条 `issued_r` 永远为 1 = head 卡死 ⇒ **每拍恰好一个 ld_done_valid**。
//   做法**不是**去反压回包 (`rd_resp_ready` 保持硬接 1), 而是让**命中抢不到就不交**:
//     hit_valid = 命中判定 && !rsp_busy       (rsp_busy = 本拍有 load 回包)
//     miss_go   = !hit_valid && ...           (抢输的命中**降级**成缺失, 走 AXI 重取)
//   于是交付源恒为 {回包} ∪ {命中, 且回包不在} ⇒ 天然互斥。代价是撞车那一笔白读一次 SRAM +
//   多一趟 AXI 往返; 收益是一条不需要额外仲裁器就成立的不变量 (纯命中流/纯缺失流永不撞车)。
//
// 【★ 缺失推送的 1 格 skid = 复用查表寄存器本身 (不另加存储)】
//   上游 `ms_ready` 可能为低 (读 FIFO 满 / AXI 通道被占)。此时**保持** lk_*_r 并在后续拍重试,
//   同时置 lk_miss_r (SRAM 数据已失效, 不得再拿它比 tag)。这要求 `busy` 输出在**当拍**就抬高:
//     busy = lk_v_r && !hit_valid && !ms_fire_w
//   否则下一拍来的 load 会在 posedge 覆盖掉还没推出去的那个地址。
//   归纳: 查表结果存在 ⟺ 上一拍接受了 load; 而接受 ⇒ busy=0 ⇒ 不会 park ⇒ skid 必空; 反之
//   lk_v_r 被占住那拍 busy=1 ⇒ 不会有第二个缺失同时要寄存。AR 发射序 = 接受序 = 缺失序。
//
// 【★ MSHR 合并 —— 不加会把顺序流打回基线】单 MSHR 下, 填充期间对该行的每条 load 都会判缺失、
//   各发一笔 AR (32 B 行 = 每行 8 笔重复 AR; vvadd 那种顺序流必中)。故: 缺失且**行号与在填行相同**
//   ⇒ 不推 AR, 置 lk_wait_r 停住; 填充最后一字落地那拍**重放** (把 lk_addr_r 重新摆上 SRAM 地址口,
//   1 拍后再判定 ⇒ 这次命中)。行号不同的缺失照常推 AR, 行号存进 1 条排队寄存器 pf_* 稍后起填。
//
// 【★ 单端口 SRAM 的读写冲突】写 (填充安装) **绝对优先** (回包不可反压), 被偷走的读判为**缺失**
//   (自纠正: 多一趟 AXI, 不会错)。`rd_ok_r` 在**发起读那一拍**采样 (`<= !fill_wr_w`), 与命中相与。
//   上层另用 `busy` 里的 wr_busy 项把"恰好撞上写"的接受挡掉, 避免无谓降级。
//
// 【★ 一致性: store **退休**才按索引失效 (idxinv), 提交时只拦安装】见 mem_subsystem.v 第 4 节。
//   失效清的是**该组全部路的 valid 位**, 不看 tag、不占 SRAM 口 —— 离线实测 (tools/dcache_sim.py)
//   该策略与"命中才失效"逐配置同值 (IPC 0.4960 vs 0.4961), 却省掉整条 tag 检查读+写回通路。
//
//   ★ 失效时点是**退休** (`clr_valid`), 不是提交 (`inv_valid`), 这两根线不可合并:
//     · 提交 (`inv_valid`): 只用来**拦安装** (填充污染期间本来就不装; 另外抑制 `fill_wr_w`/`vset_w`
//       同拍的写与置位)。**不清 valid** —— 行留在缓存里继续供命中。
//     · 退休 (`clr_valid`): 才清该组 valid。此时 B 已握手 (数据已进内存)、且该 store 之后的 load
//       都已回 (ticket 已过) ⇒ 行里那个字节从"旧值"变成"错值", 必须下架。
//   提交→退休之间那一段靠上层 `mem_subsystem.sq_merge_byte_f` 的字节合并链兜住: 交付一条 load 时
//   逐字节用 SQ 里更老的 store 覆盖。**两条窗口在同一个 posedge 结束** —— `sq_ret_p <= sq_ret_p+1`
//   与 `valid_r <= 0` 同拍, 于是下一拍"合并没了"与"行没了"同时发生, 两个方向都不会漏:
//     · 若 valid 先清而合并还在 → 白清一个字节, 无害;
//     · 若合并先没而 valid 还在 → **读到旧值, 静默算错** (故必须同拍, 不能早清也不能晚清)。
//   实测收益: geo IPC 0.4732 → 0.4829 (+2.05%), 全部落在 store 会打中驻留行的用例上
//   (qsort +8.5% / towers +3.2% / rsort +0.8%), 零驻留的 median/multiply/vvadd 逐比特不变。
//
// 【★ 填充污染 (poison): 起填前/填充中只要有"B 尚未落盘"的 store 落在同一组, 本次填充作废】
//   只查"安装那一拍 SQ 里有没有同组条目"**不够**: store 可能在最后一字落地前就退休出队, 而它之前
//   发出的那几笔 AR 读的是旧值 ⇒ 装进一行旧数据 (静默算错)。故用**粘滞**污染位: 填充期间任一拍
//   发现 sq_blk 命中本组 ⇒ 置位, 直到本次填充结束才清; 污染后不再写 SRAM、不置 valid。
//   安装那一拍若本拍有 store 提交到同组, 也要抑制 (valid 置位输给失效)。
//
// 复位异步低有效 (与 axi_lite_master / icache / mem_subsystem 一致; ASAP7 库只有异步复位触发器)
module dcache #(
    parameter DC_SIZE       = 2048,     // 总容量 (字节; 0 = 旁路, 见 DC_OFF)
    parameter DC_LINE_WORDS = 8,        // 每行字数 (2 的幂)
    parameter DC_WAYS       = 1,        // 相联度 (2 的幂; 1/2/4… 均可)
    parameter LSQ_SIZE      = 16,       // 仅为 idx 宽度
    // 组数由上面三个参数推出; 必须是 parameter (而非 localparam) 才能出现在端口声明里。
    // * 向上取到 2 的幂: SRAM 的地址线宽按组数取, 非 2 的幂会让高位地址越界 ($fatal)。
    // * DC_SIZE=0 时夹到 1 (sram_fakeram 对 DEPTH=0 会 $fatal, $clog2(0) 在 Verilog-2005 里未定义)
    parameter SETS_RAW      = DC_SIZE / (4 * DC_LINE_WORDS * DC_WAYS),
    parameter DC_SETS       = (SETS_RAW < 1) ? 1 : (1 << $clog2(SETS_RAW))
) (
    input  clk,
    input  rst_n,

    // ---- 查表口 (上层: lk_valid = ld_accept = ld_start_valid && !dc_busy) ----
    input                                lk_valid,
    input  [31 : 0]                      lk_addr,
    input  [1 : 0]                       lk_width,
    input  [$clog2(LSQ_SIZE) - 1 : 0]    lk_idx,
    input                                rsp_busy,     // 本拍有 load 的 AXI 回包 (交付端口被占)

    // ---- 命中交付 (T+1; 与回包天然互斥, 上层直接 `done_valid = rsp_valid || hit_valid`) ----
    output                               hit_valid,
    output [31 : 0]                      hit_word,     // 该地址所在**整字** (未抽取/未零扩展)
    output [31 : 0]                      hit_addr,
    output [1 : 0]                       hit_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]    hit_idx,

    // ---- 缺失推送 (ms_valid 保持到 ms_ready; 上层在 ms_ready 那拍把 payload 压进 miss 队列) ----
    output                               ms_valid,
    output [31 : 0]                      ms_addr,      // load 的**原始字节地址** (AR 地址由上层对齐)
    output [1 : 0]                       ms_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]    ms_idx,
    input                                ms_ready,

    // ---- 行填充 (由上层仲裁; 优先级 需求 load > 取指填充 > 本填充) ----
    output                               fill_req_valid,
    output [31 : 0]                      fill_req_addr,
    input                                fill_req_ready,
    input                                fill_rsp_valid,   // 与已发出的请求一一对应且同序; 不可反压
    input  [31 : 0]                      fill_rsp_data,

    // ---- store 一致性 ----
    // 两个信号分工明确, 不可合并 (理由见第七条不变量):
    //   inv_* = store **提交** (进 SQ) 那拍 —— 只用来拦安装, **不清 valid**;
    //   clr_* = store **退休** (B 已落盘且其后的 load 都已回) 那拍 —— 才清 valid。
    input                                inv_valid,    // 本拍有一条 store 提交
    input  [31 : 0]                      inv_addr,
    input                                clr_valid,    // 本拍有一条 store 退休 (= mem_subsystem 的 sq_retire)
    input  [31 : 0]                      clr_addr,
    input  [DC_SETS - 1 : 0]             sq_blk,       // SQ 里"B 尚未落盘"的条目所占的组号位图

    // ---- 观测量 ----
    output                               busy,         // 查表寄存器被占 || 本拍有安装写 (load 不可接受)
    output                               fill_busy
);
    // 地址切分: [31:TAGHI] 行 tag | [TAGHI-1:SPLIT] 组号 | [SPLIT-1:2] 行内字偏移 | [1:0] 字节
    localparam DC_OFF   = (DC_SIZE == 0) ? 1'b1 : 1'b0;  // 旁路: 永不命中、永不起填
    localparam ONE_SET  = (DC_SETS < 2) ? 1'b1 : 1'b0;   // 只有 1 组 ⇒ 组号恒 0 (DEPTH=1 越界保护)
    localparam DC_IW    = (DC_SETS < 2) ? 1 : $clog2(DC_SETS);
    localparam OFF_W    = $clog2(DC_LINE_WORDS);
    localparam SPLIT    = 2 + OFF_W;
    localparam TAGHI    = SPLIT + DC_IW;
    localparam TAG_W    = 32 - TAGHI;
    localparam WAY_W    = 32 * DC_LINE_WORDS + 32;       // 一路的条目宽: 数据 + tag (tag 占最高 32 位槽)
    localparam EW       = DC_WAYS * WAY_W;
    localparam TAGOFF   = 32 * DC_LINE_WORDS + TAGHI;    // 条目里 tag 字段起始位 (= WAY_W − TAG_W, 顶对齐)
    localparam WMASK_W  = DC_WAYS * (DC_LINE_WORDS + 1); // = EW / 写粒度 (32); 每路含 1 个 tag lane
    localparam FIW      = $clog2(DC_LINE_WORDS + 1);     // 填充字计数器位宽 (须能表示 DC_LINE_WORDS 本身)
    localparam WY_W     = (DC_WAYS > 1) ? $clog2(DC_WAYS) : 1;
    localparam LIW      = $clog2(LSQ_SIZE);

    integer gi;                                          // always 块里的位图循环
    genvar  gj;                                          // generate 循环

    // ==================== 1. 网表声明 ====================
    wire [EW - 1 : 0]        rdata_w;
    wire [31 : 0]            rd_addr_w;                  // 本拍摆上 SRAM 读口的地址
    wire [DC_IW - 1 : 0]     rd_set_w, q_set_w, inv_set_w, clr_set_w, new_set_w;
    wire [OFF_W - 1 : 0]     q_off_w;
    wire [TAG_W - 1 : 0]     rd_tag_w;
    wire [DC_WAYS - 1 : 0]   way_hit_g, set_valid_w;
    wire [WY_W - 1 : 0]      hit_way_w, victim_way_w;
    wire                     any_hit_w, hit_raw_w;
    wire [31 : 0]            hit_word_w, fill_base_new_w;
    wire                     miss_pending_w, coalesce_w, same_line_w;
    wire                     ms_fire_w, fill_go_w, fill_pend_w, fill_start_w;
    wire                     fill_wr_w, fill_hs_w, fill_last_w, fill_poison_now_w, vset_w;
    wire                     fill_abort_w;
    wire [FIW - 1 : 0]       fill_wi_w, fill_inflight_w;
    wire [WMASK_W - 1 : 0]   wmask_w;
    wire [EW - 1 : 0]        wdata_w;

    // ==================== 2. 顺序状态 ====================
    // 查表寄存器 (skid 就是它): 接受时写入, 结果被消化 (交付/推出) 才释放
    reg  [31 : 0]            lk_addr_r;
    reg  [1 : 0]             lk_width_r;
    reg  [LIW - 1 : 0]       lk_idx_r;
    reg                      lk_v_r;                     // 本拍有一个查表结果待解释
    reg                      lk_miss_r;                  // 该结果已判缺失并保持 (SRAM 数据已失效)
    reg                      lk_wait_r;                  // 该 load 已并入在填行, 等填充完成
    reg                      lk_replay_r;                // 本拍在读口上重放 lk_addr_r (下一拍才判定)
    reg  [31 : 0]            rd_addr_q;                  // 上一拍摆上读口的地址 (tag 比较的另一半)
    reg                      rd_ok_r;                    // 上一拍的读没被安装写偷走
    reg  [DC_WAYS * DC_SETS - 1 : 0] valid_r;            // 行有效位图 (唯一须与 tag 同拍可读的状态)
    reg  [DC_IW - 1 : 0]     fill_set_r;
    reg  [31 : 0]            fill_base_r;
    reg  [FIW - 1 : 0]       fill_word_r;                // 下一笔要发 AR 的行内字下标
    reg  [FIW - 1 : 0]       fill_cnt_r;                 // 已回包的字数 (同序 ⇒ 即本笔的字 lane)
    reg  [WY_W - 1 : 0]      fill_way_r;                 // 本次填充装进哪一路
    reg                      fill_busy_r;
    reg                      fill_poison_r;              // 粘滞: 途中出现过未落盘的同组 store
    reg  [31 : 0]            pf_base_r;                  // 待填行 (填充忙时排队的 1 条)
    reg                      pf_v_r;

    // ==================== 3. 查表地址与结果 ====================
    // 重放那一拍把 lk_addr_r 摆回去; 其余拍用上层给的候选地址 (本拍要接受的那条)
    assign rd_addr_w = lk_replay_r ? lk_addr_r : lk_addr;
    assign rd_set_w  = ONE_SET ? {DC_IW{1'b0}} : rd_addr_w[TAGHI - 1 : SPLIT];
    assign q_set_w   = ONE_SET ? {DC_IW{1'b0}} : rd_addr_q[TAGHI - 1 : SPLIT];
    assign q_off_w   = rd_addr_q[SPLIT - 1 : 2];
    assign rd_tag_w  = rd_addr_q[TAGHI +: TAG_W];

    // 每一路的 tag 与 valid 并行比较 (一拍读出所有路 —— 这就是 1 个读口能支持多路的原因)
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : waycmp
            wire [TAG_W - 1 : 0] wtag_w = rdata_w[gj * WAY_W + TAGOFF +: TAG_W];
            assign way_hit_g[gj] = (wtag_w == rd_tag_w) && valid_r[gj * DC_SETS + q_set_w];
        end
    endgenerate

    // 命中路编码: 任一相联度通用 (命中互斥 ⇒ 优先级无关, 只取"有命中"的那一路)
    function [WY_W - 1 : 0] hitway_f;
        input [DC_WAYS - 1 : 0] wh;
        integer hk;
        begin
            hitway_f = {WY_W{1'b0}};
            for (hk = 0; hk < DC_WAYS; hk = hk + 1)
                if (wh[hk]) hitway_f = hk[WY_W - 1 : 0];
        end
    endfunction
    assign hit_way_w = hitway_f(way_hit_g);

    assign any_hit_w  = !DC_OFF && (|way_hit_g);
    // 命中判定: rd_addr_q 就是 T−1 拍摆上读口的那个地址 ⇒ rdata_w 与 tag/valid 必然同源
    assign hit_raw_w  = lk_v_r && !lk_miss_r && !lk_wait_r && !lk_replay_r && rd_ok_r && any_hit_w;
    assign hit_word_w = rdata_w[hit_way_w * WAY_W + q_off_w * 32 +: 32];

    assign hit_valid = hit_raw_w && !rsp_busy;           // ★ 抢不到交付端口就不交 (降级成缺失)
    assign hit_word  = hit_word_w;
    assign hit_addr  = rd_addr_q;
    assign hit_width = lk_width_r;
    assign hit_idx   = lk_idx_r;

    // ==================== 4. 缺失推送 / 合并 / skid ====================
    // 抢输的命中与"读被写偷走"都落进 miss_pending: 它们都靠 AXI 重取, 走同一条路
    assign miss_pending_w = lk_v_r && !lk_wait_r && !lk_replay_r && !hit_valid;
    assign same_line_w    = (lk_addr_r[31 : SPLIT] == fill_base_r[31 : SPLIT]);
    // 该行正在填 ⇒ 不重复发 AR, 等填充完成再重放 (否则 32 B 行每行多 8 笔重复 AR, 顺序流必中)
    assign coalesce_w     = miss_pending_w && fill_busy_r && same_line_w && !DC_OFF;
    assign ms_fire_w      = miss_pending_w && !coalesce_w && ms_ready;

    assign ms_valid = miss_pending_w && !coalesce_w;
    assign ms_addr  = lk_addr_r;                         // 原始字节地址, 对齐由上层做
    assign ms_width = lk_width_r;
    assign ms_idx   = lk_idx_r;

    // ==================== 5. 填充器 (单 MSHR + 1 条排队) ====================
    assign fill_go_w       = miss_pending_w && !coalesce_w && !fill_busy_r && !pf_v_r && !DC_OFF;
    assign fill_pend_w     = miss_pending_w && !coalesce_w && !fill_go_w && !DC_OFF;
    assign fill_start_w    = (pf_v_r && !fill_busy_r) || fill_go_w;      // 排队的那条优先
    assign fill_base_new_w = (pf_v_r && !fill_busy_r) ? pf_base_r
                                                      : {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
    assign new_set_w       = ONE_SET ? {DC_IW{1'b0}} : fill_base_new_w[TAGHI - 1 : SPLIT];

    // ★ 被污染的填充不再发新 AR。污染后回包一定被丢弃 (见下面 fill_wr_w), 再发就是白占读通道
    //   —— A2 实测读通道占用已到 46~78%, 是三个读用户共享的瓶颈。实测污染率: towers 35% /
    //   qsort 48% / rsort 75% 的行首, 且 rsort 有 65% 是**填充途中**才污染 ⇒ 省下的是行尾那几笔。
    //   **已发出的**必须收完: 回包与 AR 一一对应, 漏收的会被下一次填充当成自己的响应 (字下标错位)。
    //   故收尾分两支: 正常 = 收满一行; 中止 = 已发数 == 已回数 (无在飞)。
    //   ★ 中止且无在飞时必须**当拍**收尾, 不能等回包 —— 否则 fill_last_w 永不置位、fill_busy_r
    //     恒 1, 该组再也起不了填充 (又是"脉冲当电平用", 与 Bug B 同形状)。
    assign fill_abort_w    = fill_busy_r && (fill_poison_r || fill_poison_now_w);
    assign fill_inflight_w = fill_word_r - fill_cnt_r;
    assign fill_req_valid = fill_busy_r && (fill_word_r != DC_LINE_WORDS) && !fill_abort_w;
    assign fill_req_addr  = fill_base_r + {{(30 - OFF_W){1'b0}}, fill_word_r[OFF_W - 1 : 0], 2'b00};
    assign fill_busy      = fill_busy_r;
    assign fill_hs_w      = fill_req_valid && fill_req_ready;
    assign fill_last_w    = fill_abort_w ? (fill_inflight_w == {FIW{1'b0}})
                                         : (fill_rsp_valid && (fill_cnt_r == DC_LINE_WORDS - 1));

    // ★ 污染: 填充期间任一拍发现"B 未落盘的 store"落在本组 ⇒ 本次填充作废 (粘滞到结束)
    assign fill_poison_now_w = fill_busy_r && sq_blk[fill_set_r];
    // 写绝对优先 (回包不可反压); 污染或同拍失效命中本组则连写都不写
    assign fill_wr_w = fill_rsp_valid && !fill_poison_r && !fill_poison_now_w
                    && !(inv_valid && (inv_set_w == fill_set_r));
    assign fill_wi_w = fill_cnt_r;
    // 掩码: 中选路里"tag 槽"或"回包那个字槽"各置一位; 其余 lane 被 sram_fakeram 按 wmask 丢弃
    assign wmask_w = fill_wr_w
        ? (({{(WMASK_W - 1){1'b0}}, 1'b1} << (fill_way_r * (DC_LINE_WORDS + 1) + DC_LINE_WORDS))
         | ({{(WMASK_W - 1){1'b0}}, 1'b1} << (fill_way_r * (DC_LINE_WORDS + 1)
                                               + fill_wi_w[OFF_W - 1 : 0])))
        : {WMASK_W{1'b0}};
    assign wdata_w = {DC_WAYS{ {fill_base_r[31 : TAGHI], {(32 - TAG_W){1'b0}},
                                {DC_LINE_WORDS{fill_rsp_data}}} }};

    sram_fakeram #(
        .DEPTH             (DC_SETS),
        .WIDTH             (EW),
        .WRITE_GRANULARITY (32)
    ) u_arr (
        .clk   (clk),
        .en    (1'b1),
        .we    (fill_wr_w),
        .wmask (wmask_w),
        .addr  (fill_wr_w ? fill_set_r : rd_set_w),
        .wdata (wdata_w),
        .rdata (rdata_w)
    );

    // 受害者: 最低空路优先, 全满则用该组的 round-robin 指针 (DC_WAYS=1 时恒 0, 无指针)
    function [WY_W - 1 : 0] victim_f;
        input [DC_WAYS - 1 : 0] sv;
        input [WY_W - 1 : 0]    rr;
        integer vk;
        begin
            victim_f = rr;
            for (vk = DC_WAYS - 1; vk >= 0; vk = vk - 1)   // 倒序 ⇒ 最低编号的空路最后写入, 即优先选它
                if (!sv[vk]) victim_f = vk[WY_W - 1 : 0];
        end
    endfunction
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : setv
            assign set_valid_w[gj] = valid_r[gj * DC_SETS + new_set_w];
        end
    endgenerate
    generate
        if (DC_WAYS == 1) begin : vic1
            assign victim_way_w = {WY_W{1'b0}};
        end else begin : vicN
            reg [DC_SETS * WY_W - 1 : 0] rr_r;           // 每组下一个被替换的路号 (仅多路才有)
            wire [WY_W - 1 : 0]          rr_w = rr_r[new_set_w * WY_W +: WY_W];
            assign victim_way_w = victim_f(set_valid_w, rr_w);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) rr_r <= {DC_SETS * WY_W{1'b0}};
                else if (vset_w) rr_r[fill_set_r * WY_W +: WY_W] <= fill_way_r + 1'b1;
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_busy_r   <= 1'b0;
            fill_set_r    <= {DC_IW{1'b0}};
            fill_base_r   <= 32'd0;
            fill_word_r   <= {FIW{1'b0}};
            fill_cnt_r    <= {FIW{1'b0}};
            fill_way_r    <= {WY_W{1'b0}};
            fill_poison_r <= 1'b0;
            pf_v_r        <= 1'b0;
            pf_base_r     <= 32'd0;
        end else begin
            if (fill_start_w) begin
                fill_busy_r   <= 1'b1;
                fill_set_r    <= new_set_w;
                fill_base_r   <= fill_base_new_w;
                fill_word_r   <= {FIW{1'b0}};
                fill_cnt_r    <= {FIW{1'b0}};
                fill_way_r    <= victim_way_w;
                // 起填那拍 fill_set_r 还没更新, 用 fill_base_new_w 的组号查污染
                fill_poison_r <= sq_blk[new_set_w];
            end else if (fill_busy_r) begin
                if (fill_hs_w)         fill_word_r <= fill_word_r + 1'b1;   // 被 load 抢走就原地重试
                if (fill_rsp_valid)    fill_cnt_r  <= fill_cnt_r + 1'b1;
                if (fill_poison_now_w) fill_poison_r <= 1'b1;
                if (fill_last_w)       fill_busy_r <= 1'b0;
            end
            if (fill_pend_w) begin                                      // 覆盖 (1 条队列)
                pf_v_r    <= 1'b1;
                pf_base_r <= {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
            end else if (fill_start_w) begin
                pf_v_r    <= 1'b0;                                      // 排队的那条已起填
            end
        end
    end

    // ==================== 6. 查表寄存器 (skid) ====================
    // busy = 寄存器被占住无法接受新 load || 本拍有安装写 (会偷走新读 ⇒ 无谓降级)
    assign busy = (lk_v_r && !hit_valid && !ms_fire_w) || fill_wr_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lk_addr_r   <= 32'd0;
            lk_width_r  <= 2'd0;
            lk_idx_r    <= {LIW{1'b0}};
            lk_v_r      <= 1'b0;
            lk_miss_r   <= 1'b0;
            lk_wait_r   <= 1'b0;
            lk_replay_r <= 1'b0;
        end else if (lk_valid && !busy) begin                       // 接受: 覆盖上一条已消化的结果
            lk_addr_r   <= lk_addr;
            lk_width_r  <= lk_width;
            lk_idx_r    <= lk_idx;
            lk_v_r      <= 1'b1;
            lk_miss_r   <= 1'b0;
            lk_wait_r   <= 1'b0;
            lk_replay_r <= 1'b0;
        end else if (lk_v_r) begin
            if (lk_replay_r) begin
                lk_replay_r <= 1'b0;                                // 重放读已发出, 下一拍用新 rd_addr_q 判定
            end else if (lk_wait_r) begin
                // ★ 退出条件必须是**电平** (!fill_busy_r), 只写 fill_last_w 会永久卡死:
                //   fill_last_w 是 1 拍脉冲, 而"并入"与"填充最后一拍"可以同拍发生
                //   (coalesce_w && fill_last_w)。那一拍只置了 lk_wait_r, posedge 后 fill_busy_r 已清、
                //   fill_last_w 再也不会为 1 ⇒ lk_wait_r 恒 1 ⇒ 这条 load 永不交付 ⇒ LSQ 的 issued_r
                //   位恒 1 ⇒ head 卡死, 全机冻结。实测 bulgarian: t=20765 同拍命中 [COAL-LAST],
                //   此后每拍 [WAITSTUCK] 直到 300000 拍上限。
                //   fill_last_w 这一项保留只为省 1 拍 (它那一拍 fill_busy_r 还是 1, 快路径抓得到;
                //   填充结束到重放读最早只能是下一拍 —— 那一拍安装写已过, 读口不再被偷)。
                if (fill_last_w || !fill_busy_r) begin lk_wait_r <= 1'b0; lk_replay_r <= 1'b1; end
            end else if (hit_valid) begin
                lk_v_r <= 1'b0;                                     // 命中已交付
            end else if (coalesce_w) begin
                lk_wait_r <= 1'b1;                                  // 并入在填行
            end else if (ms_fire_w) begin
                lk_v_r <= 1'b0;                                     // 缺失已推出
            end else begin
                lk_miss_r <= 1'b1;                                  // park: 保持, 下一拍重试
            end
        end
    end

    // ==================== 7. 读口时序 (rd_ok_r 必须在发起读那一拍采样) ====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_q <= 32'd0;
            rd_ok_r   <= 1'b0;
        end else begin
            rd_addr_q <= rd_addr_w;
            rd_ok_r   <= !fill_wr_w;                                // 写的那拍没有读 ⇒ 下一拍条目不可信
        end
    end

    // ==================== 8. 行有效位图 ====================
    assign inv_set_w = ONE_SET ? {DC_IW{1'b0}} : inv_addr[TAGHI - 1 : SPLIT];
    assign clr_set_w = ONE_SET ? {DC_IW{1'b0}} : clr_addr[TAGHI - 1 : SPLIT];
    // 最后一字落地才置位; 污染 / 同拍 store 失效命中本组 ⇒ 不置
    assign vset_w = fill_last_w && !fill_poison_r && !fill_poison_now_w
                 && !(inv_valid && (inv_set_w == fill_set_r));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {(DC_WAYS * DC_SETS){1'b0}};
        end else begin
            // ★ store **退休**才失效, 不是提交 (第七条不变量): 提交到退休之间该行的字节由
            //   第 4 节的合并链 (mem_subsystem.sq_merge_byte_f) 逐字节兜住 —— 而那条链的覆盖窗口
            //   与这里的有效窗口**在同一个 posedge 结束** (sq_ret_p++ 与 valid_r<=0 同拍),
            //   下一拍两者同时消失, 既不会"合并没了行还在"(读旧值) 也不会"行没了合并还在"(白清)。
            //   收益: store 打在驻留行上时不再立刻打掉它, 后续 load 仍能命中。
            if (clr_valid)
                for (gi = 0; gi < DC_WAYS; gi = gi + 1)
                    valid_r[gi * DC_SETS + clr_set_w] <= 1'b0;
            // ★ 发起填充即清 valid —— 不清就是"旧数据冒充新 tag"的假命中
            if (fill_start_w) valid_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
            // 中途置位会把半行当整行交付
            if (vset_w) valid_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b1;
        end
    end

endmodule
