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
// 【★ 单端口 SRAM 的读写冲突】写 (填充安装 / store 命中就地更新) **绝对优先** (回包不可反压),
//   被偷走的读一律**重放** (写周期里 sram_fakeram 把 rdata 置 x ⇒ 该拍结果不可信): `rd_ok_r` 在
//   **发起读那一拍**采样 (`<= !(fill_wr_w || st_wr_w)`), 未偷才允许判定, 被偷则置 lk_replay_r
//   重发同一地址 (第 6 节)。★ 不能像"无写回"版本那样把偷读判成缺失自纠正: 写回下误判缺失 =
//   读到陈旧内存 **且** 覆盖脏行 = 静默算错 (不变量 3)。重放只多 1 拍, 且 store 写的优先权是绝对的
//   ⇒ 重放必收敛 (store 每笔至多让路一次填充收尾)。上层另用 `busy` 里的 fill_wr_w 项把"恰好撞上
//   安装写"的接受挡掉, 省掉这次重放 (store 写不进门是不行的: SQ 只等这一拍就得给答复)。
//
// 【★ 一致性: store **退休那拍就地更新**命中行 (写直达), 提交时只拦安装】见 mem_subsystem.v 第 4 节。
//   两根线分工明确, 不可合并:
//     · 提交 (`inv_valid`): 只用来**拦安装** (污染的填充本来就不装; 另外抑制 `fill_wr_w`/`vset_w`
//       同拍的写与置位)。**不清 valid、不写数据** —— 行留在缓存里继续供命中。
//     · 退休 (`st_valid` 口, 第 9 节): 此时 B 已握手 (数据已进内存)、且该 store 之后的 load 都已回
//       (ticket 已过) ⇒ 行里那几个字节从"旧值"变成"错值", 必须当拍修正。三条出路恰好一条:
//         整字命中 ⇒ `st_absorb` 就地写该字 (只覆盖 SRAM 那一个 lane); 部分字命中 ⇒ `st_drop`
//         下架该行 (写直达下内存是权威且已新鲜 ⇒ 重取必得新值); 未命中 ⇒ `st_bypass` 不动缓存。
//   提交→退休之间那一段靠上层 `mem_subsystem.sq_merge_byte_f` 的字节合并链兜住: 交付一条 load 时
//   逐字节用 SQ 里更老的 store 覆盖。**两条窗口在同一个 posedge 结束** —— `sq_ret_p <= sq_ret_p+1`
//   与"SRAM 写入该字"同拍, 于是下一拍"合并没了"与"行已是新值"同时发生, 两个方向都不会漏:
//     · 若更新早于退休 → 合并链还在, 覆盖的是同一个值, 无害;
//     · 若合并先没而更新还没到 → **读到旧值, 静默算错** (故必须同拍, 不能早也不能晚)。
//   ★ 与上一版 (idxinv: 退休清**整组**) 的区别: 清组会把同组其它行一起打掉 —— 一次 store 退休就
//   毁掉 2 KB/(4·L) = 8 行里的一整组 (64 B)。离线模型 (tools/dcache_sim.py) 实测这一项值 8.2%
//   (geo IPC 0.4997 → 0.5408), 全部落在 store 会打中驻留行的用例上。
//   ★ 命中的是"最高编号的命中路" (hitway_f 的覆盖序); 同组不允许出现两个同 tag 的路 —— 由不变量 1
//   在**安装**那拍禁掉 (第 8 节)。
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
    // 两根线分工明确, 不可合并 (理由见第七条不变量):
    //   inv_* = store **提交** (进 SQ) 那拍 —— 只用来拦安装, **不清 valid、不写数据**;
    //   st_*  = store **退休** (B 已落盘且其后的 load 都已回) 那拍 —— 把该行修正到新值。
    input                                inv_valid,    // 本拍有一条 store 提交
    input  [31 : 0]                      inv_addr,
    input  [DC_SETS - 1 : 0]             sq_blk,       // SQ 里"B 尚未落盘"的条目所占的组号位图

    // ---- store 退休口 (payload 由 mem_subsystem 的 SQ 队首直接给出; 语义与论证见第 9 节) ----
    // st_valid 保持到 st_absorb/st_drop/st_bypass **之一**抬起 (与 ms_valid/ms_ready 同款握手);
    // 三者互斥, 且可能全 0 (安装写占着 SRAM 口 ⇒ 多等一拍, 队首不动)。
    input                                st_valid,
    input  [31 : 0]                      st_addr,
    input  [31 : 0]                      st_data,
    input  [1 : 0]                       st_width,
    output                               st_absorb,    // 整字命中 ⇒ 本拍已就地更新该行
    output                               st_drop,      // 部分字命中 ⇒ 本拍已下架该行
    output                               st_bypass,    // 未命中 ⇒ 本缓存不动 (数据另走 AXI)

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
    wire [DC_IW - 1 : 0]     rd_set_w, q_set_w, inv_set_w, new_set_w;
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
    wire                     sram_we_w;                  // SRAM 写使能 = 安装 ∪ store 就地更新
    wire [DC_IW - 1 : 0]     st_set_w;                   // ---- 第 9 节: store 退休口 ----
    wire [TAG_W - 1 : 0]     st_tag_w;
    wire [OFF_W - 1 : 0]     st_word_w;
    wire [DC_WAYS - 1 : 0]   st_hit_g;
    wire [WY_W - 1 : 0]      st_way_w;
    wire                     any_st_hit_w, st_full_w, st_wr_w;

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
    reg                      rd_ok_r;                    // 上一拍的读没被写 (安装/store) 偷走
    reg  [DC_WAYS * DC_SETS - 1 : 0] valid_r;            // 行有效位图 (唯一须与 tag 同拍可读的状态)
    // tag 镜像 (与 valid_r 配对写: 安装那拍一起写, **无需复位** —— 一切读取都由 valid_r 门控, 而
    // valid 置 1 那拍 tag 必然同拍写入 ⇒ 不存在"valid=1 而 tag 未定义"的组合)。
    // 为什么不用 SRAM 里那份 tag: store 退休要在**那一拍**当拍给出答复 (SQ 只等这一拍), 而 SRAM 是
    // 同步读 —— 拿出来已是下一拍, 要么多走一次握手, 要么让 SQ 多存一份 payload, 两者都更贵。
    // 代价: DC_WAYS*DC_SETS*TAG_W = 2*32*22 = 1408 flop ≈ 534 µm² (0.379 µm²/flop)。
    reg  [DC_WAYS * DC_SETS * TAG_W - 1 : 0] tag_r;
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
    // 抢输的命中落进 miss_pending (靠 AXI 重取)。★ `rd_ok_r` 这一项把"读被写偷走"挡在外面 ——
    //   那不是缺失, 是**重放** (第 6 节)。若放它进来, 上面那层 mem_subsystem 会跟着 ms_valid
    //   把这一笔压进 miss 队列并发 AR (它的 dc_ms_fire_w 只认 ms_valid && ms_ready), 而本模块
    //   并不清 lk_v_r ⇒ 同一笔 load 会**发两次 AR、回两个完成脉冲** ⇒ LSQ 的 idx 彻底错位。
    assign miss_pending_w = lk_v_r && !lk_wait_r && !lk_replay_r && rd_ok_r && !hit_valid;
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
    wire [WMASK_W - 1 : 0] fill_wmask_w =
          ({{(WMASK_W - 1){1'b0}}, 1'b1} << (fill_way_r * (DC_LINE_WORDS + 1) + DC_LINE_WORDS))
        | ({{(WMASK_W - 1){1'b0}}, 1'b1} << (fill_way_r * (DC_LINE_WORDS + 1)
                                             + fill_wi_w[OFF_W - 1 : 0]));
    // store 就地更新: 只覆盖命中路里那一个字槽 (tag 槽不进掩码 ⇒ 行号不变)
    wire [WMASK_W - 1 : 0] st_wmask_w =
          {{(WMASK_W - 1){1'b0}}, 1'b1} << (st_way_w * (DC_LINE_WORDS + 1) + st_word_w);
    // SRAM 写口三选一: 安装 (最高 — 回包不可反压) > store 就地更新 > 无 (读口留给查表)
    assign sram_we_w = fill_wr_w || st_wr_w;
    assign wmask_w   = fill_wr_w ? fill_wmask_w : (st_wr_w ? st_wmask_w : {WMASK_W{1'b0}});
    assign wdata_w   = fill_wr_w
        ? {DC_WAYS{ {fill_base_r[31 : TAGHI], {(32 - TAG_W){1'b0}}, {DC_LINE_WORDS{fill_rsp_data}}} }}
        : {DC_WAYS{ {(DC_LINE_WORDS + 1){st_data}} }};      // 每 lane 都是同一个字, 由掩码选一个

    sram_fakeram #(
        .DEPTH             (DC_SETS),
        .WIDTH             (EW),
        .WRITE_GRANULARITY (32)
    ) u_arr (
        .clk   (clk),
        .en    (1'b1),
        .we    (sram_we_w),
        .wmask (wmask_w),
        .addr  (fill_wr_w ? fill_set_r : (st_wr_w ? st_set_w : rd_set_w)),
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
            end else if (!lk_miss_r && !rd_ok_r) begin
                // ★ 本拍的读被安装写/store 就地更新偷走 (sram_fakeram 在写周期把 rdata 置 x)
                //   ⇒ 重放同一地址, **不判缺失**: 写回下误判缺失 = 读陈旧内存 + 覆盖脏行 = 静默算错。
                //   只在"这一拍本是对这笔 load 的判定"时进 (`!lk_miss_r` 挡掉已 park 的那条: 它的
                //   rd_addr_q 早就不代表自己了, 重放只会白等两拍)。被偷的那笔 AR 绝不会发出去 ——
                //   miss_pending_w 里也带了 rd_ok_r。
                lk_replay_r <= 1'b1;
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
            rd_ok_r   <= !sram_we_w;                                // 写的那拍没有读 ⇒ 下一拍条目不可信
        end
    end

    // ==================== 8. 行有效位图 + tag 镜像 ====================
    assign inv_set_w = ONE_SET ? {DC_IW{1'b0}} : inv_addr[TAGHI - 1 : SPLIT];
    wire [TAG_W - 1 : 0] fill_tag_w = fill_base_r[31 : TAGHI];       // 本次填充行的 tag
    // 最后一字落地才置位; 污染 / 同拍 store 失效命中本组 ⇒ 不置
    assign vset_w = fill_last_w && !fill_poison_r && !fill_poison_now_w
                 && !(inv_valid && (inv_set_w == fill_set_r));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {(DC_WAYS * DC_SETS){1'b0}};
        end else begin
            // ★ 发起填充即清 valid —— 不清就是"旧数据冒充新 tag"的假命中
            if (fill_start_w) valid_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
            // 中途置位会把半行当整行交付
            if (vset_w) valid_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b1;
            // ★ 不变量 1: 同组任一时点最多一路持有某 tag —— 安装那拍把其它持有同一 tag 的路一并
            //   作废。重复 tag 在写回下是**静默算错** (脏副本被换出 / 陈旧副本被读出); 这里只是
            //   DC_WAYS 个比较器加几次 valid 位清除, 不占 SRAM 口。valid_r 这一项是必须的:
            //   没写过的路的 tag_r 从未定义 (见第 2 节), 不能参与比较。
            if (vset_w)
                for (gi = 0; gi < DC_WAYS; gi = gi + 1)
                    if ((gi != fill_way_r) && valid_r[gi * DC_SETS + fill_set_r]
                        && (tag_r[gi * (DC_SETS * TAG_W) + fill_set_r * TAG_W +: TAG_W] == fill_tag_w))
                        valid_r[gi * DC_SETS + fill_set_r] <= 1'b0;
            // ★ store 退休的部分字命中 ⇒ 下架该行 (整字命中走 SRAM 写, 这里不动 valid)。
            //   放最后 = 与安装同拍时"下架"赢 —— 下架永远安全 (重取必得新值), 留着旧字节不安全。
            if (st_drop) valid_r[st_way_w * DC_SETS + st_set_w] <= 1'b0;
        end
    end

    always @(posedge clk)                                            // 无复位: 见第 2 节 tag_r 的论证
        if (vset_w) tag_r[fill_way_r * (DC_SETS * TAG_W) + fill_set_r * TAG_W +: TAG_W] <= fill_tag_w;

    // ==================== 9. store 退休口 (写直达 + 命中就地更新) ====================
    // 语义: SQ 队首那条 store 已 "B 落盘 + ticket 已过", 要在**本拍**把缓存行修正到新值, 之后才
    // 允许退休出队 (mem_subsystem 拿这里的回答当退休许可)。三条出路互斥, 恰好一条:
    //   · 命中 & 整字 & 4 字节对齐 ⇒ st_absorb: 覆盖该行那一个字 (走 SRAM 写口, 第 5 节仲裁)
    //   · 命中 & 其它宽度/对齐   ⇒ st_drop: 下架该行 —— 写直达下内存是权威且新鲜的 (B 已落盘),
    //     故"下架重取"必得新值, 不必为部分字做读-改-写 (省掉一条 2 拍 RMW 通路与它的一堆边界)
    //   · 未命中 ⇒ st_bypass: 本缓存没有该行, 无事可做 (数据仍按原样走 SQ→AXI 写通道)
    // 让路: 安装写占着 SRAM 口的那拍 st_absorb 不抬 (填充回包不可反压), SQ 队首原地多等一拍 ——
    //   正确性不受影响 (条目还在 SQ 里 ⇒ 合并链仍在覆盖), 而填充写最多连续 DC_LINE_WORDS 拍。
    assign st_set_w  = ONE_SET ? {DC_IW{1'b0}} : st_addr[TAGHI - 1 : SPLIT];
    assign st_tag_w  = st_addr[TAGHI +: TAG_W];
    assign st_word_w = st_addr[SPLIT - 1 : 2];
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : stcmp
            assign st_hit_g[gj] = valid_r[gj * DC_SETS + st_set_w]
                && (tag_r[gj * (DC_SETS * TAG_W) + st_set_w * TAG_W +: TAG_W] == st_tag_w);
        end
    endgenerate
    assign st_way_w     = hitway_f(st_hit_g);
    assign any_st_hit_w = |st_hit_g;
    assign st_full_w    = (st_width == 2'b10) && (st_addr[1 : 0] == 2'b00);
    assign st_wr_w      = st_valid && any_st_hit_w && st_full_w && !fill_wr_w;
    assign st_absorb    = st_wr_w;
    assign st_drop      = st_valid && any_st_hit_w && !st_full_w;
    assign st_bypass    = st_valid && !any_st_hit_w;

endmodule
