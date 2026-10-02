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
//   ★ pf_* 的清法有一条硬规矩: "本拍起填的正是排队那条" (`pf_start_w`) 时**不得**用本拍的新缺失覆盖
//   它 (那个缺失下一拍会自己重新排队)。留着它 ⇒ 填充结束后对**同一行**再起一次填充, 而那时该行已
//   驻留 ⇒ victim 落到另一路, 安装时的不变量 1 清理会静默作废另一路的**脏副本** (只清 valid/dirty,
//   不写回) ⇒ 该行吸收过的 store 永远到不了内存, 随后的重填读回旧值。
//
// 【★ 单端口 SRAM 的读写冲突】写 (填充安装 / store 命中就地更新) **绝对优先** (回包不可反压),
//   WB 捕获读次之 (它只有那一拍机会: 受害行下一拍就可能被填充覆盖), 被偷走的**查表读**一律
//   **重放** (写周期里 sram_fakeram 把 rdata 置 x ⇒ 该拍结果不可信): `rd_ok_r` 在**发起读那一拍**
//   采样 (`<= !sram_we_w && !wb_cap_w`), 未偷才允许判定, 被偷则置 lk_replay_r 重发同一地址
//   (第 6 节)。★ 不能像"无写回"版本那样把偷读判成缺失自纠正: 写回下误判缺失 = 读到陈旧内存
//   **且** 覆盖脏行 = 静默算错。重放只多 1 拍, 且写/捕获的优先权是绝对的 ⇒ 重放必收敛。上层另用
//   `busy` 里的 fill_wr_w 项把"恰好撞上安装写"的接受挡掉, 省掉这次重放 (store 写不进门是不行的:
//   SQ 只等这一拍就得给答复)。
//
// 【★ 一致性: **写回** —— 缓存行是数据的唯一权威, 内存只是被写回的备份】见 mem_subsystem.v 第 4 节。
//   (上一版是"写直达 + 命中就地更新": store 数据同时进缓存行与内存。写回把 AXI 写流量从"每条
//    store 一笔"降到"每行换出 8 笔", 并把 SQ 条目的可见性从"B 回包"改成"写进缓存行"。)
//   只有一根线 (旧版的"提交 `inv_valid` 拦安装"已删 —— 写回下 store 的数据在吸收前哪儿都不去,
//   不与在飞填充抢同一个字, 拦安装纯多余; 其副作用是"提交撞上填充最后一拍"变成静默丢一次安装):
//     · 退休 (`st_valid` 口, 第 9 节): 队首那条 store 在本拍定去向 —— 命中就地把字节写进行并置脏
//       (`st_absorb`), 未命中就旁路给 AXI (`st_bypass`, 数据本来就在 SQ→写通道的路上)。
//   提交→退休之间那一段靠上层 `mem_subsystem.sq_merge_byte_f` 的字节合并链兜住: 交付一条 load 时
//   逐字节用 SQ 里更老的 store 覆盖 (写回下这一条更吃重 —— 未退休 store 的数据既不在内存也不在
//   行里, 只在 SQ)。**更新与"条目出队"的关系是单向安全的**:
//     · 若更新早于退休 → 合并链还在, 覆盖的是同一个值, 无害 (写回下条目还要等 ticket, 所以
//       "吸收那拍"与"出队那拍"通常差好几拍, 全部落在这一侧);
//     · 若合并先没而更新还没到 → **读到旧值, 静默算错**。故 `sq_ret_ok` 必须等 `st_absorb` 抬过
//       才成立 (mem_subsystem 的 sq_vis_w 含 sq_ab_r)。
//   ★ 与更早那一版 (idxinv: 退休清**整组**) 的区别: 清组会把同组其它行一起打掉 —— 一次 store 退休
//   就毁掉一整组 (64 B)。离线模型 (tools/dcache_sim.py) 实测这一项值 8.2% (geo 0.4997 → 0.5408)。
//   ★ 命中的是"最高编号的命中路" (hitway_f 的覆盖序); 同组不允许出现两个同 tag 的路 —— 由不变量 1
//   在**安装**那拍禁掉 (第 8 节)。
//
// 【★ 脏位 + 写回 (WB): 驱逐脏行时先读进缓冲, 再排水到写通道】
//   起填那拍发现受害路 `valid && dirty` ⇒ ①记下 `wbc_*`, 该路 valid/dirty 同拍清零; ②下一拍用
//   **读口**把整行读进 `wb_data_r` (那拍读口被占, 撞上的查表读靠 rd_ok_r=0 重放); ③再下一拍起
//   背靠背推 DC_LINE_WORDS 笔 `wb_req_*`, 推完转 `wb_hold_r` 等 B; ④B 收齐才松手。
//   ★ 捕获读与填充**不冲突**: 填充分第一笔写最早在第 DC_LINE_WORDS+LATENCY 拍, 而捕获读只占第 2 拍。
//   ★ 在线冲突 (各一个比较器, 比 [31:SPLIT]): 同一行的**填充**不起 (内存此刻可能还是旧值);
//     同一行的**旁路 store** 不发 (否则它的新字节会被旧行的 8 笔写回反超)。
//   ★ WB 缓冲只有 1 项: 要驱逐脏行而缓冲被占 ⇒ 本次填充停住 (等排水完, 罕见), 但**不丢** ——
//     记进 pf_* 排队那条 (fill_blk_w/fill_pend_w)。
//
// 【★ 写回引入的第三处"误判缺失 = 静默算错"】写回下内存可能落后于缓存行, 于是**任何**把
//   "本该命中"变成"去读内存"的路径都致命。除了上面那条"偷读必须重放"之外, 还有一处:
//   命中但交付口被 rsp_busy 占住时, 写直达版可以降级成缺失 (走 AXI 重取, 反正内存新鲜),
//   写回下不行 ⇒ 改成**重放** (第 6 节, 只花 2 拍, 比一趟 AXI 还便宜), 同时用 `!hit_raw_w`
//   把这条挡在 `ms_valid` 之外 (第 4 节)。两处必须成对改。
//
// 【★ 填充污染 (poison): 起填前/填充中只要有"尚未可见"的 store 落在**同一行**, 本次填充作废】
//   只查"安装那一拍 SQ 里有没有同行条目"**不够**: store 可能在最后一字落地前就退休出队, 而它之前
//   发出的那几笔 AR 读的是旧值 ⇒ 装进一行旧数据 (静默算错)。故用**粘滞**污染位: 填充期间任一拍
//   发现 fill_blk 命中本行 ⇒ 置位, 直到本次填充结束才清; 污染后不再写 SRAM、不置 valid。
//   安装那一拍若本拍有 store 提交到同一行, 也要抑制 (valid 置位输给失效)。
//   ★ 粒度 = **行**, 不是组 (旧版是 DC_SETS 位的组位图)。组粒度下"SQ 里任一条待落盘 store"
//     会废掉整个组 (32 组里每 2 KB/128 B 一个) 的填充 —— rsort 实测填充只装进 3.21/8 个字
//     (qsort 6.80), 20.5% 的周期处在"这次填充已经废了"的状态, 命中率被拖到 54.4%。行粒度把
//     误伤面缩到 1/32, 且判据本身没变宽: 危险窗口是"该行的 AR 早于该 store 落盘", 同行的
//     待可见条目才是真危险。
//   ★ 为什么覆盖"全部待可见条目"而不是只覆盖会旁路的那些 (计划里曾这么写): 一条 store 究竟
//     被吸收还是旁路, 要等它**退休那拍**看行在不在才定得下来, 事前无法判 —— 而"先装行、后
//     吸收"这一路本来就安全 (同拍结束的两窗口 + 合并链), 所以安全上界就是"同行有未可见条目"。
//     这个上界在实践中很紧: 条目一旦可见 (吸收进行 / 或已落盘) 就不再污染。
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
    // 只有一根线: st_* = 队首那条 store 的**退休**判定 —— 命中把该 store 的字节写进行 (写回),
    // 未命中就旁路给 AXI。提交那拍不再通知本模块 (旧版 inv_valid 拦安装一条已删): 写回下 store 的
    // 数据在吸收前**哪儿都不去**, 不会与在飞填充读回的内存值抢同一个字 ⇒ 拦安装纯属多余, 而它
    // 的副作用是把"提交恰好撞上填充最后一拍"变成**静默丢一次安装** (行不 valid、填充照常收尾),
    // 于是下一条 load 又缺失 —— 与 §9 的自杀环同形状。
    // ---- 填充污染 (行粒度): fill_line = 本拍"有效填充行", fill_blk 由上层按 SQ 未可见条目算 ----
    // 起填那拍 fill_line 给**新行** (fill_base_r 还没更新), 其余拍给在填行; 见第五条不变量。
    output [31 : 0]                      fill_line,
    input                                fill_blk,

    // ---- store 退休口 (payload 由 mem_subsystem 的 SQ 队首直接给出; 语义与论证见第 9 节) ----
    // st_valid 保持到 st_absorb/st_bypass **之一**抬起 (与 ms_valid/ms_ready 同款握手);
    // 二者互斥, 且可能全 0 (安装写 / WB 捕获读占着 SRAM 口 ⇒ 多等一拍, 队首不动)。
    input                                st_valid,
    input  [31 : 0]                      st_addr,
    input  [31 : 0]                      st_data,
    input  [1 : 0]                       st_width,
    output                               st_absorb,    // 命中 ⇒ 本拍已就地把该 store 的字节写进行 (置脏)
    output                               st_bypass,    // 未命中 ⇒ 本缓存不动 (数据另走 AXI)

    // ---- 写回口 (脏行被驱逐: 整行 DC_LINE_WORDS 笔背靠背写回; 写通道由上层与 SQ 旁路 store 仲裁) ----
    output                               wb_req_valid,
    output [31 : 0]                      wb_req_addr,
    output [31 : 0]                      wb_req_data,
    input                                wb_req_ready,
    input                                wb_resp_valid, // 本行某一笔写回收到 B

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
    // ★ 写粒度 = 32 位 (lane 单位): 每路 (DC_LINE_WORDS+1) 个 32 位槽 ⇒ 掩码位数 = 路数 × (行字数 + 1)。
    //   用**整字**粒度而不是字节, 唯一的原因是**宏实例数**: sram_fakeram 把 WIDTH 拆成
    //   WIDTH/GRANULARITY 个宏 (scripts/fakeram.py), 而这些宏的 addr/we/wmask 输入脚由**同一根网**
    //   驱动 —— §二十三 在综合网表上实测: 8 位粒度下 72 个宏, 地址网一根线扇出 71 个宏脚 (≈355 pF),
    //   两级 (缓冲 + 反相器) 吃掉 4.21 ns = c2 周期 6.02 ns 的 71%, 是 300 MHz 前唯一的障碍。
    //   32 位粒度 ⇒ 宏数 72→18, 广播负载 ÷4; **面积不变** (lane_area = depth*granularity*area_per_bit,
    //   总位数不变), 只是 clock_to_q 略涨 0.03 ns (0.001243254 × (32−8))。
    //   代价: 部分字 (sb/sh) 命中不再能"1 拍就地写"(那正是字节掩码买到的东西) ⇒ 第 9 节改为
    //   **读-改-写**: 占读口 1 拍取老字, 再占写口 1 拍落盘。perf 六例里 `sh` 静态 0 次, `sb` 只在
    //   rsort 引用的那一个 memcpy 里出现 (动态 ≤0.5%) ⇒ geo IPC 代价 ≈ −0.2% (§二十三 反汇编统计)。
    localparam LWM      = (DC_LINE_WORDS + 1);           // 每路的掩码位数 (lane = 32 位, 含 1 个 tag 槽)
    localparam WMASK_W  = DC_WAYS * LWM;
    localparam FIW      = $clog2(DC_LINE_WORDS + 1);     // 填充字计数器位宽 (须能表示 DC_LINE_WORDS 本身)
    localparam BIW      = (DC_LINE_WORDS < 2) ? 1 : $clog2(DC_LINE_WORDS);  // WB 排水计数器位宽
    localparam WY_W     = (DC_WAYS > 1) ? $clog2(DC_WAYS) : 1;
    localparam LIW      = $clog2(LSQ_SIZE);

    integer gi;                                          // always 块里的位图循环
    genvar  gj;                                          // generate 循环

    // ==================== 1. 网表声明 ====================
    wire [EW - 1 : 0]        rdata_w;
    wire [31 : 0]            rd_addr_w;                  // 本拍摆上 SRAM 读口的地址
    wire [DC_IW - 1 : 0]     rd_set_w, q_set_w, new_set_w;
    wire [OFF_W - 1 : 0]     q_off_w;
    wire [TAG_W - 1 : 0]     rd_tag_w;
    wire [DC_WAYS - 1 : 0]   way_hit_g, set_valid_w;
    wire [WY_W - 1 : 0]      hit_way_w, victim_way_w;
    wire                     any_hit_w, hit_raw_w;
    wire [31 : 0]            hit_word_w, fill_base_new_w;
    wire                     miss_pending_w, coalesce_w, same_line_w;
    wire                     lk_same_fill_w, lk_wb_wait_w, lk_wait_src_w, lk_cacheable_w;
    wire                     ms_fire_w, fill_go_w, fill_pend_w, fill_start_w, fill_blk_w;
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
    wire                     any_st_hit_w, st_wr_w, st_cacheable_w;   // ---- 第 5 节: 写回 ----
    wire                     wb_cap_w;                   // 本拍用读口把受害行整行捕获进缓冲
    wire                     wb_buf_busy_w;              // WB 数据缓冲被占 (新捕获无处放)
    wire                     wb_line_busy_w;             // 本行在飞 (捕获/排水/等 B): 内存可能还是旧值
    wire                     vic_v_w, vic_dirty_w;       // 受害路此刻有效? 脏?
    wire [TAG_W - 1 : 0]     vic_tag_w;                  // 受害路的 tag 镜像 (= 受害行基址的高位)
    wire                     wb_last_push_w, wb_done_w;
    wire                     st_full_w;                  // ---- 第 9 节: 部分字 store 的读-改-写 ----
    wire                     rmw_rd_w, rmw_wr_w, rmw_hold_w;
    wire [WMASK_W - 1 : 0]   rmw_wmask_w;
    wire [31 : 0]            rmw_merge_w;

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
    // ---- 部分字 store 的读-改-写 (第 9 节): 读相 → 合成 → 写相 ----
    reg                      rmw_rd1_r;                  // 读相后一拍: rdata_w 上正是命中路的老字
    reg                      rmw_v_r;                    // 整字已合成, 等写口空
    reg  [DC_IW - 1 : 0]     rmw_set_r;
    reg  [WY_W - 1 : 0]      rmw_way_r;
    reg  [OFF_W - 1 : 0]     rmw_woff_r;
    reg  [31 : 0]            rmw_word_r;
    // ---- 写回: 脏位 + 一份行缓冲 (捕获 → 排水 → 等 B) ----
    reg  [DC_WAYS * DC_SETS - 1 : 0] dirty_r;            // 行脏位 (无复位: 一切读取都由 valid_r 门控)
    reg                      wbc_pend_r;                 // 起填那拍发现受害路脏 ⇒ 本拍把整行读进缓冲
    reg                      wbc_lat_r;                  // 捕获读的回包拍 (SRAM 同步读 ⇒ 比读口晚一拍)
    reg  [DC_IW - 1 : 0]     wbc_set_r;
    reg  [WY_W - 1 : 0]      wbc_way_r;
    reg  [31 : 0]            wb_base_r;                  // 在飞行 (或被捕获) 的行基址
    reg                      wb_v_r;                     // 缓冲有整行数据, 还没推完
    reg  [BIW - 1 : 0]       wb_beat_r;                  // 下一笔要推的行内字下标
    reg  [32 * DC_LINE_WORDS - 1 : 0] wb_data_r;         // 整行快照 (8×32 = 256 flop)
    reg                      wb_hold_r;                  // 8 笔已推完, 等 B 全回
    reg  [FIW - 1 : 0]       wb_bcnt_r;                  // 已回的 B 数

    // ==================== 3. 查表地址与结果 ====================
    // 重放那一拍把 lk_addr_r 摆回去; 其余拍用上层给的候选地址 (本拍要接受的那条)。
    // ★ WB 捕获读**抢占**读口 (它只有这一拍机会): 被它偷走的查表读由 rd_ok_r=0 变成重放, 不判缺失。
    // ★ 部分字 store 的读-改-写读**次之** (只取组号, 地址低位的组内偏移无意义); 被它偷走的查表读
    //   同样靠 rd_ok_r=0 重放。它**必须让** WB 捕获读 —— 那笔读只有一次机会, 错过就是丢一条脏行。
    assign rd_addr_w = wb_cap_w ? wb_base_r
                     : (rmw_rd_w ? st_addr : (lk_replay_r ? lk_addr_r : lk_addr));
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

    // 宽度编码 (00=1 01=2 10=4 字节) → 字内 4 个字节的选通掩码 (与 mem_subsystem 的 wd_mask 同口径)
    function [3 : 0] wd_mask4;
        input [1 : 0] w;
        begin
            wd_mask4 = (w == 2'b10) ? 4'hf : (w == 2'b01) ? 4'h3 : 4'h1;
        end
    endfunction

    assign any_hit_w  = !DC_OFF && (|way_hit_g);
    // 命中判定: rd_addr_q 就是 T−1 拍摆上读口的那个地址 ⇒ rdata_w 与 tag/valid 必然同源
    assign hit_raw_w  = lk_v_r && !lk_miss_r && !lk_wait_r && !lk_replay_r && rd_ok_r && any_hit_w;
    assign hit_word_w = rdata_w[hit_way_w * WAY_W + q_off_w * 32 +: 32];

    assign hit_valid = hit_raw_w && !rsp_busy;           // ★ 抢不到交付端口就不交 (下一拍重放, 见第 6 节)
    assign hit_word  = hit_word_w;
    assign hit_addr  = rd_addr_q;
    assign hit_width = lk_width_r;
    assign hit_idx   = lk_idx_r;

    // ==================== 4. 缺失推送 / 合并 / skid ====================
    // 抢输的命中落进 miss_pending (靠 AXI 重取)。★ `rd_ok_r` 这一项把"读被写偷走"挡在外面 ——
    //   那不是缺失, 是**重放** (第 6 节)。若放它进来, 上面那层 mem_subsystem 会跟着 ms_valid
    //   把这一笔压进 miss 队列并发 AR (它的 dc_ms_fire_w 只认 ms_valid && ms_ready), 而本模块
    //   并不清 lk_v_r ⇒ 同一笔 load 会**发两次 AR、回两个完成脉冲** ⇒ LSQ 的 idx 彻底错位。
    // ★ 只推**真缺失** (`!hit_raw_w`)。命中但交付口被占 (rsp_busy) **不是**缺失: 写回下让它走 AXI
    //   会读到"落后于脏行的内存值" (该行的新字节只存在于缓存里) ⇒ 静默算错。它必须重放 (第 6 节)。
    //   写直达下这条降级是安全的 (内存恒新鲜), 写回下必须改 —— 这是不变量 3 的第三处落点。
    assign miss_pending_w = lk_v_r && !lk_wait_r && !lk_replay_r && rd_ok_r && !hit_raw_w;
    assign same_line_w    = (lk_addr_r[31 : SPLIT] == fill_base_r[31 : SPLIT]);
    assign lk_same_fill_w = fill_busy_r && same_line_w;
    assign lk_wb_wait_w   = wb_line_busy_w && (lk_addr_r[31 : SPLIT] == wb_base_r[31 : SPLIT]);
    assign lk_cacheable_w = (lk_addr_r[31 : 28] == 4'h0);   // AXI 内存只到 0x0fffffff ⇒ 高位非 0 = MMIO
    // 该行正在填 / 正在写回 ⇒ 不重复发 AR, 等它结束再重放 (否则 32 B 行每行多 8 笔重复 AR, 顺序流必中)
    // ★ WB 那一项是写回特有的: 行刚被驱逐、脏数据还在缓冲里没落盘, 此刻发 AR 读回的是旧值。
    assign lk_wait_src_w  = lk_same_fill_w || lk_wb_wait_w;
    assign coalesce_w     = miss_pending_w && lk_wait_src_w && !DC_OFF;
    assign ms_fire_w      = miss_pending_w && !coalesce_w && ms_ready;

    assign ms_valid = miss_pending_w && !coalesce_w;
    assign ms_addr  = lk_addr_r;                         // 原始字节地址, 对齐由上层做
    assign ms_width = lk_width_r;
    assign ms_idx   = lk_idx_r;

    // ==================== 5. 填充器 (单 MSHR + 1 条排队) ====================
    assign fill_base_new_w = (pf_v_r && !fill_busy_r) ? pf_base_r
                                                      : {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
    assign new_set_w       = ONE_SET ? {DC_IW{1'b0}} : fill_base_new_w[TAGHI - 1 : SPLIT];

    // ---- 写回状态 (捕获 → 排水 → 等 B); 三者的定义与"谁给谁让路"见头注释第五条 ----
    assign wb_cap_w       = wbc_pend_r;                  // 本拍用读口把受害行整行读进缓冲
    // wb_buf_busy_w 必须含 wb_hold_r: 新捕获在 wbc_lat_r 那拍会清零 wb_beat_r/wb_bcnt_r, 而这两个
    // 计数器正被"等 B"段共用 —— 中途清零 ⇒ wb_done_w 提前 ⇒ wb_line_busy_w 提前撤, 上一行的写拍
    // 还在 AXI 写 FIFO 里, 同一行随后的填充就会读回旧值 (dbg1 实测 230 次 cap-while-hold)。
    assign wb_buf_busy_w  = wbc_pend_r || wbc_lat_r || wb_v_r || wb_hold_r;  // 数据缓冲被占 (新捕获无处放; 含等 B 段)
    assign wb_line_busy_w = wbc_pend_r || wbc_lat_r || wb_v_r || wb_hold_r;  // 本行在飞
    assign wb_req_valid   = wb_v_r;
    assign wb_req_addr    = wb_base_r + {wb_beat_r, 2'b00};
    assign wb_req_data    = wb_data_r[wb_beat_r * 32 +: 32];
    assign wb_last_push_w = wb_req_valid && wb_req_ready && (wb_beat_r == DC_LINE_WORDS - 1);
    assign wb_done_w      = wb_resp_valid && (wb_bcnt_r == DC_LINE_WORDS - 1);

    // ---- 起填门控 (写回新增) ----
    assign vic_v_w     = valid_r[victim_way_w * DC_SETS + new_set_w];
    assign vic_dirty_w = dirty_r[victim_way_w * DC_SETS + new_set_w];
    assign vic_tag_w   = tag_r[victim_way_w * (DC_SETS * TAG_W) + new_set_w * TAG_W +: TAG_W];
    // 起填被写回挡住的两种情况: ①同一行还在飞 (内存此刻可能还是旧值) ②要驱逐脏行但缓冲被占。
    // 被挡住时让"排队的那条"接住 (fill_pend_w), 不白丢一次填充机会 —— 当前这条 miss 的 AR 照发。
    // ③部分字 store 的读-改-写窗口 (rmw_hold_w): 此刻起填可能把**它正要改写的那一路**选作受害路,
    //   行一朝被清 valid, 那笔已经读出老字、还没来得及落盘的 store 就写进了一条无效行(静默丢数据)。
    //   被挡住的 miss 落进 fill_pend_w ⇒ 排队等窗口结束, 不丢。
    assign fill_blk_w  = (wb_line_busy_w && (wb_base_r[31 : SPLIT] == fill_base_new_w[31 : SPLIT]))
                      || (wb_buf_busy_w && vic_v_w && vic_dirty_w);
    assign fill_go_w   = miss_pending_w && !coalesce_w && !fill_busy_r && !pf_v_r && !DC_OFF
                      && lk_cacheable_w && !fill_blk_w && !rmw_hold_w;
    assign fill_pend_w = miss_pending_w && !coalesce_w && !fill_go_w && !DC_OFF && lk_cacheable_w;
    assign pf_start_w   = pf_v_r && !fill_busy_r && !fill_blk_w && !rmw_hold_w;   // 本拍起填的正是排队那条
    assign fill_start_w = pf_start_w || fill_go_w;                                // 排队的那条优先

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

    // ★ 污染: 填充期间任一拍发现"尚未可见 (未吸收且未落盘) 的 store"落在**本行** ⇒ 本次填充作废
    assign fill_poison_now_w = fill_busy_r && fill_blk;
    // 写绝对优先 (回包不可反压); 被污染的填充连写都不写 (回包照收, 见 fill_abort_w)
    assign fill_wr_w = fill_rsp_valid && !fill_poison_r && !fill_poison_now_w;
    assign fill_wi_w = fill_cnt_r;
    // 掩码单位 = 1 lane (32 位; 每路 LWM 位): "tag 槽那一 lane" 或 "回包那个字那一 lane"
    //   (写法与 icache 同款 —— 那边一直是 32 位粒度)
    wire [WMASK_W - 1 : 0] b1_w = {{(WMASK_W - 1){1'b0}}, 1'b1};
    wire [WMASK_W - 1 : 0] fill_wmask_w =
          (b1_w << (fill_way_r * LWM + DC_LINE_WORDS))
        | (b1_w << (fill_way_r * LWM + fill_wi_w[OFF_W - 1 : 0]));
    // store 就地更新: 只覆盖命中路里那一 **lane** (tag 槽不进掩码 ⇒ 行号不变)。
    //   字节口径与 SQ/AXI 一致: 数据与掩码同左移 addr[1:0] 个字节 (mem_subsystem 的 wd_mask 同款);
    //   整字 store 必然对齐 (RV32I 口径) ⇒ 那 4 个字节落在同一 lane 内。
    wire [3 : 0]           st_bmask_w   = wd_mask4(st_width) << st_addr[1 : 0];
    wire [31 : 0]          st_data_sh_w = st_data << {st_addr[1 : 0], 3'b000};
    wire [WMASK_W - 1 : 0] st_wmask_w =
          b1_w << (st_way_w * LWM + st_word_w);
    // 部分字 (sb/sh) 的读-改-写: 老字在 rdata 上 (读相后一拍), 与 store 字节在**同一 lane** 内按字节合并
    // ★ st_bmask_w 是**按字节**的 4 位选通 (与 SQ/AXI 同口径), 要展开成 32 位比特掩码才能与数据相与
    wire [31 : 0]          st_bmask_bits_w = {{8{st_bmask_w[3]}}, {8{st_bmask_w[2]}},
                                              {8{st_bmask_w[1]}}, {8{st_bmask_w[0]}}};
    wire [31 : 0]          rmw_old_w   = rdata_w[rmw_way_r * WAY_W + rmw_woff_r * 32 +: 32];
    assign rmw_merge_w = (rmw_old_w & ~st_bmask_bits_w) | (st_data_sh_w & st_bmask_bits_w);
    assign rmw_wmask_w = b1_w << (rmw_way_r * LWM + rmw_woff_r);
    // SRAM 写口三选一: 安装 (最高 — 回包不可反压) > store 就地更新 (整字 or 读-改-写) > 无
    assign sram_we_w = fill_wr_w || st_wr_w || rmw_wr_w;
    assign wmask_w   = fill_wr_w ? fill_wmask_w
                     : (st_wr_w ? st_wmask_w : (rmw_wr_w ? rmw_wmask_w : {WMASK_W{1'b0}}));
    assign wdata_w   = fill_wr_w
        ? {DC_WAYS{ {fill_base_r[31 : TAGHI], {(32 - TAG_W){1'b0}}, {DC_LINE_WORDS{fill_rsp_data}}} }}
        : {DC_WAYS{ {(DC_LINE_WORDS + 1){st_wr_w ? st_data_sh_w : rmw_word_r}} }};  // 每 lane 同一个字, 掩码选 lane

    sram_fakeram #(
        .DEPTH             (DC_SETS),
        .WIDTH             (EW),
        .WRITE_GRANULARITY (32)          // ★ 宏实例数 = EW/32; 8 位粒度下是 72 个宏 (见上面 LWM 的论证)
    ) u_arr (
        .clk   (clk),
        .en    (1'b1),
        .we    (sram_we_w),
        .wmask (wmask_w),
        .addr  (fill_wr_w ? fill_set_r
                          : (st_wr_w ? st_set_w : (rmw_wr_w ? rmw_set_r : rd_set_w))),
        .wdata (wdata_w),
        .rdata (rdata_w)
    );

    // 受害者: 最低空路优先, 全满则用该组的替换指针 (DC_WAYS=1 时恒 0, 无指针;
    // 多路下 2 路是 LRU、>2 路退化成"最近安装路 +1"的轮转)
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
            // 每组"下一个被替换的路号"。**命中也要翻转** (命中某路 ⇒ 受害者变成另一路):
            // 只认安装就等于**填充轮转 (FIFO)** —— 2 路下热点行每两次填充必被踢一次, 与它被
            // 命中多频繁无关。§十七 在 idxinv 下测不出差别 (组满占比 qsort 3.6% / rsort 2.9%,
            // 替换选择无从行使), 该节把"store 处理修好后必须重测"写成了欠账; 本节即那次重测。
            // 2 路下"命中路 +1"就是 LRU 路; rr_r 是早就存在的状态 ⇒ 零新增触发器、零新增口。
            // 同拍两次访问同组只认前一条 (两条都刚被用过, 谁当受害者都行) —— 罕见且无害。
            reg [DC_SETS * WY_W - 1 : 0] rr_r;           // 每组下一个被替换的路号 (仅多路才有)
            wire [WY_W - 1 : 0]          rr_w = rr_r[new_set_w * WY_W +: WY_W];
            assign victim_way_w = victim_f(set_valid_w, rr_w);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) rr_r <= {DC_SETS * WY_W{1'b0}};
                else if (vset_w)    rr_r[fill_set_r * WY_W +: WY_W] <= fill_way_r + 1'b1;
                else if (hit_raw_w) rr_r[q_set_w    * WY_W +: WY_W] <= hit_way_w  + 1'b1;
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
            wbc_pend_r    <= 1'b0;
            wbc_lat_r     <= 1'b0;
            wbc_set_r     <= {DC_IW{1'b0}};
            wbc_way_r     <= {WY_W{1'b0}};
            wb_base_r     <= 32'd0;
            wb_v_r        <= 1'b0;
            wb_beat_r     <= {BIW{1'b0}};
            wb_hold_r     <= 1'b0;
            wb_bcnt_r     <= {FIW{1'b0}};
        end else begin
            // ---- WB 捕获 (起填后一拍占读口; SRAM 同步读 ⇒ 再下一拍数据才到手) ----
            wbc_lat_r <= wbc_pend_r;
            if (wbc_pend_r) wbc_pend_r <= 1'b0;
            if (wbc_lat_r) begin
                wb_v_r    <= 1'b1;
                wb_beat_r <= {BIW{1'b0}};
                wb_bcnt_r <= {FIW{1'b0}};
                wb_data_r <= rdata_w[wbc_way_r * WAY_W +: 32 * DC_LINE_WORDS];
            end
            if (fill_start_w) begin
                fill_busy_r   <= 1'b1;
                fill_set_r    <= new_set_w;
                fill_base_r   <= fill_base_new_w;
                fill_word_r   <= {FIW{1'b0}};
                fill_cnt_r    <= {FIW{1'b0}};
                fill_way_r    <= victim_way_w;
                // 起填那拍 fill_base_r 还没更新 —— fill_line 输出此刻已指向**新行**, 污染按新行判
                fill_poison_r <= fill_blk;
                // 受害路脏 ⇒ 下一拍把整行读进 WB 缓冲 (该路 valid/dirty 同拍清零, 数据不丢)
                // ★ wb_base_r 必须是**受害行**的基址 (受害路的 tag 镜像 + 本组), 不是新填充行的:
                //   捕获读只按组寻址, 给错行照样读到对的整行; 但排水那 8 笔的地址与 wb_line_busy_w
                //   的同行比较都靠它 ⇒ 给成新行 = 把旧行的数据写到新行的地址上 (静默算错)。
                //   tag_r 在 vset_w 才更新, 此刻仍是被驱逐那条的 tag。
                if (vic_v_w && vic_dirty_w) begin
                    wbc_pend_r <= 1'b1;
                    wbc_set_r  <= new_set_w;
                    wbc_way_r  <= victim_way_w;
                    wb_base_r  <= {vic_tag_w, new_set_w, {SPLIT{1'b0}}};
                end
            end else if (fill_busy_r) begin
                if (fill_hs_w)         fill_word_r <= fill_word_r + 1'b1;   // 被 load 抢走就原地重试
                if (fill_rsp_valid)    fill_cnt_r  <= fill_cnt_r + 1'b1;
                if (fill_poison_now_w) fill_poison_r <= 1'b1;
                if (fill_last_w)       fill_busy_r <= 1'b0;
            end
            // ★ 同拍"起填"与"再排队"时不能盲目覆盖: 若起填的就是排队那条 (pf_start_w), 该排队项已被
            //   这次填充满足, 留着它 ⇒ 填充结束后会对**同一行**再起一次填充; 那时该行已驻留 ⇒ victim
            //   落到另一路, 安装时的不变量 1 清理会把另一路的**脏副本静默作废** (只清 valid/dirty, 不写回)
            //   ⇒ 该行吸收过的 store 永远到不了内存, 之后的重填读回旧值 (def_wr4 qsort 实测: 420 号元素
            //   变成 312 号的重复值)。丢掉的那个排队请求不亏: 它的 miss 仍在, 下一拍重新排队。
            if (fill_pend_w && !pf_start_w) begin                       // 覆盖 (1 条队列)
                pf_v_r    <= 1'b1;
                pf_base_r <= {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
            end else if (fill_start_w) begin
                pf_v_r    <= 1'b0;                                      // 排队的那条已起填
            end
            // ---- WB 排水: 背靠背推 DC_LINE_WORDS 笔 (写通道上 WB 优先); 推完转 hold 等 B ----
            if (wb_last_push_w) begin
                wb_v_r    <= 1'b0;
                wb_hold_r <= 1'b1;
            end else if (wb_req_valid && wb_req_ready) begin
                wb_beat_r <= wb_beat_r + 1'b1;
            end
            if (wb_done_w) wb_hold_r <= 1'b0;      // 写在置位之后 ⇒ 同拍"收齐"赢
            if (wb_resp_valid && (wb_v_r || wb_hold_r)) wb_bcnt_r <= wb_bcnt_r + 1'b1;
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
                // ★ 退出条件必须是**电平** (lk_wait_src_w 落下), 只写 fill_last_w 会永久卡死:
                //   fill_last_w 是 1 拍脉冲, 而"并入"与"填充最后一拍"可以同拍发生
                //   (coalesce_w && fill_last_w)。那一拍只置了 lk_wait_r, posedge 后 fill_busy_r 已清、
                //   fill_last_w 再也不会为 1 ⇒ lk_wait_r 恒 1 ⇒ 这条 load 永不交付 ⇒ LSQ 的 issued_r
                //   位恒 1 ⇒ head 卡死, 全机冻结。实测 bulgarian: t=20765 同拍命中 [COAL-LAST],
                //   此后每拍 [WAITSTUCK] 直到 300000 拍上限。
                //   fill_last_w 这一项保留只为省 1 拍 (它那一拍 fill_busy_r 还是 1, 快路径抓得到;
                //   填充结束到重放读最早只能是下一拍 —— 那一拍安装写已过, 读口不再被偷)。
                if (!lk_wait_src_w || (lk_same_fill_w && fill_last_w)) begin
                    lk_wait_r <= 1'b0; lk_replay_r <= 1'b1;
                end
            end else if (!lk_miss_r && !rd_ok_r) begin
                // ★ 本拍的读被安装写/store 就地更新/WB 捕获读偷走 (sram_fakeram 在写周期把 rdata 置 x)
                //   ⇒ 重放同一地址, **不判缺失**: 写回下误判缺失 = 读陈旧内存 + 覆盖脏行 = 静默算错。
                //   只在"这一拍本是对这笔 load 的判定"时进 (`!lk_miss_r` 挡掉已 park 的那条: 它的
                //   rd_addr_q 早就不代表自己了, 重放只会白等两拍)。被偷的那笔 AR 绝不会发出去 ——
                //   miss_pending_w 里也带了 rd_ok_r。
                lk_replay_r <= 1'b1;
            end else if (hit_raw_w && !hit_valid) begin
                // ★ 命中但交付口被占 (rsp_busy): **重放**, 不许像写直达版那样降级成缺失 ——
                //   写回下按缺失走 AXI 读到的是落后于脏行的内存值 (该行的新字节只在缓存里),
                //   而此刻合并链可能已经不含那条 store ⇒ 静默算错。重放只花 2 拍, 还比一趟 AXI 便宜。
                //   (第 4 节 miss_pending_w 用 !hit_raw_w 把这条同时挡在 AR 之外, 两处必须成对改。)
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
            // 写的那拍 / WB 捕获读占口的那拍 / 读-改-写取老字的那拍, 都没有"本次查表"的读
            // ⇒ 下一拍条目不可信 (被偷的查表读一律走重放, 不判缺失)
            rd_ok_r   <= !sram_we_w && !wb_cap_w && !rmw_rd_w;
        end
    end

    // ==================== 8. 行有效位图 + 脏位图 + tag 镜像 ====================
    // fill_line = 本拍"有效填充行": 起填那拍 fill_base_r 还是上一条, 必须给**新行** —— 上层
    // sq_line_blk_f 拿它去比 SQ 条目, 给错行就会漏判污染 (或误判)。
    assign fill_line = fill_start_w ? fill_base_new_w : fill_base_r;
    wire [TAG_W - 1 : 0] fill_tag_w = fill_base_r[31 : TAGHI];       // 本次填充行的 tag
    // 最后一字落地才置位; 被污染的填充不置 (行没装全, 装了就是"半行冒充整行")
    assign vset_w = fill_last_w && !fill_poison_r && !fill_poison_now_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {(DC_WAYS * DC_SETS){1'b0}};
        end else begin
            // ★ 发起填充即清 valid —— 不清就是"旧数据冒充新 tag"的假命中。
            //   同拍清 dirty: 受害路的脏数据此刻已被记进 WB 捕获 (存不下就不起填, 见 fill_blk_w),
            //   没被捕获的必然是干净行 ⇒ 清掉不丢数据。
            if (fill_start_w) begin
                valid_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
                dirty_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
            end
            // 中途置位会把半行当整行交付; 刚取回的行与内存一致 ⇒ 干净
            if (vset_w) begin
                valid_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b1;
                dirty_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b0;
            end
            // ★ 不变量 1: 同组任一时点最多一路持有某 tag —— 安装那拍把其它持有同一 tag 的路一并
            //   作废。重复 tag 在写回下是**静默算错** (脏副本被换出 / 陈旧副本被读出); 这里只是
            //   DC_WAYS 个比较器加几次 valid 位清除, 不占 SRAM 口。valid_r 这一项是必须的:
            //   没写过的路的 tag_r 从未定义 (见第 2 节), 不能参与比较。
            //   ★ 归纳法保证它永不命中 (valid+tag 只在 vset_w 一处置位, 而 vset_w 同拍就清干净了
            //     其它同 tag 的路) ⇒ 也就不会有一条**脏**副本被这里清掉; 写回下这条很要紧。
            if (vset_w)
                for (gi = 0; gi < DC_WAYS; gi = gi + 1)
                    if ((gi != fill_way_r) && valid_r[gi * DC_SETS + fill_set_r]
                        && (tag_r[gi * (DC_SETS * TAG_W) + fill_set_r * TAG_W +: TAG_W] == fill_tag_w)) begin
                        valid_r[gi * DC_SETS + fill_set_r] <= 1'b0;
                        dirty_r[gi * DC_SETS + fill_set_r] <= 1'b0;
                    end
            // ★ store 就地写 ⇒ 该行与内存不一致, 换出时必须写回。放最后: 与上面几项撞同一槽时
            //   以"置脏"为准 —— 吸收进去的字节是真实的, 丢掉它就是静默算错。
            if (st_absorb) dirty_r[st_way_w * DC_SETS + st_set_w] <= 1'b1;
        end
    end

    always @(posedge clk)                                            // 无复位: 见第 2 节 tag_r 的论证
        if (vset_w) tag_r[fill_way_r * (DC_SETS * TAG_W) + fill_set_r * TAG_W +: TAG_W] <= fill_tag_w;

    // ==================== 9. store 退休口 (写回: 命中就地把字节写进行, 未命中旁路) ====================
    // 语义: SQ 队首那条 store 要在**本拍**定下去向 (mem_subsystem 拿这里的回答当退休许可)。
    // 两条出路互斥, 恰好一条 (都不抬 = 让路一拍, 队首原地重试):
    //   · 命中 ⇒ st_absorb: 把该 store 的 1/2/4 个字节按 addr[1:0] 写进命中路, 并置脏。
    //     **整字 (sw) 1 拍**: 一个 lane 掩码就够 (第 3 节)。
    //     **部分字 (sb/sh) 读-改-写**: 32 位粒度下掩码只能整 lane 写, 必须先占读口把老字读回来,
    //     在 lane 内按字节合并 (rmw_merge_w) 再占写口落盘 —— 见下面"读-改-写"小节。
    //   · 未命中 ⇒ st_bypass: 本缓存没有该行, 数据照原样走 SQ→AXI 写通道 (DC_WA=0 不分配)。
    // 让路 (都不抬 ⇒ 队首多等一拍; 条目还在 SQ 里 ⇒ 合并链仍覆盖, 正确性不受影响):
    //   · 安装写占着 SRAM 口 (fill_wr_w); · WB 捕获读占着读口 (wb_cap_w);
    //   · 本拍该路正被驱逐 (st_vic_now_w): 行马上就要没了, 写进去也是白写 ⇒ 下拍自然走旁路;
    //   · 同一行的写回还没推完 (st_wb_same_w): 写通道按序, 必须排在旧行那 8 笔之后, 否则被反超。
    assign st_set_w  = ONE_SET ? {DC_IW{1'b0}} : st_addr[TAGHI - 1 : SPLIT];
    assign st_tag_w  = st_addr[TAGHI +: TAG_W];
    assign st_word_w = st_addr[SPLIT - 1 : 2];
    assign st_cacheable_w = (st_addr[31 : 28] == 4'h0);   // MMIO (>=0x10000000) 永不吸收, 必上总线
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : stcmp
            assign st_hit_g[gj] = valid_r[gj * DC_SETS + st_set_w]
                && (tag_r[gj * (DC_SETS * TAG_W) + st_set_w * TAG_W +: TAG_W] == st_tag_w);
        end
    endgenerate
    assign st_way_w     = hitway_f(st_hit_g);
    assign any_st_hit_w = |st_hit_g;
    wire   st_vic_now_w = fill_start_w && (st_set_w == new_set_w) && (st_way_w == victim_way_w);
    wire   st_wb_same_w = wb_buf_busy_w && (wb_base_r[31 : SPLIT] == st_addr[31 : SPLIT]);
    // ★ 同一行**正有填充在飞**。只认 register 出来的 fill_busy_r, 不认本拍起填 —— 起填与否本身
    //   取决于 fill_blk, 而 fill_blk (mem_subsystem 的毒化判定) 又取决于本判定, 认了就成组合环。
    //   在飞的填充必然已经过了起填那一拍, 靠它就够。
    wire   st_fill_same_w = fill_busy_r && (fill_base_r[31 : SPLIT] == st_addr[31 : SPLIT]);
    assign st_full_w    = (st_width == 2'b10);           // 整字 store (RV32I 口径下必然对齐)
    assign st_wr_w      = st_valid && any_st_hit_w && st_cacheable_w && st_full_w
                       && !fill_wr_w && !wb_cap_w && !st_vic_now_w;
    // ---- 部分字 store 的读-改-写: 读相(占读口取老字) → 合成 → 写相(占写口落盘, 与 st_absorb 同拍) ----
    // 读相进入条件与整字那条同款, 另加 `!st_fill_same_w`: 本行有填充在飞时, 它安装那拍的不变量 1
    //   清理会把**另一路**的同 tag 行作废 (只清 valid/dirty, 不写回) —— 整字那条只暴露 1 拍,
    //   读-改-写要 3 拍, 干脆等填充收尾 (miss 仍在 ⇒ 队列里的条目下拍重试; 也会自然走旁路)。
    // 窗口内禁起填 (rmw_hold_w, 第 5 节): 起填把受害路清 valid —— 万一正是本路, 已合成的整字就
    //   落进一条无效行了。★ rmw_hold_w **不含** rmw_rd_w, 否则 fill_go → fill_start → st_vic_now →
    //   rmw_rd 成组合环; 读相那一拍由 `!st_vic_now_w` 自己挡 (同拍起填驱逐本路 ⇒ 本次不发起)。
    assign rmw_rd_w     = st_valid && any_st_hit_w && st_cacheable_w && !st_full_w
                       && !rmw_rd1_r && !rmw_v_r && !fill_wr_w && !wb_cap_w
                       && !st_vic_now_w && !st_fill_same_w;
    assign rmw_wr_w     = rmw_v_r && !fill_wr_w;          // 写相: 整字已在寄存器里, 等写口空
    assign rmw_hold_w   = rmw_rd1_r || rmw_v_r;
    assign st_absorb    = st_wr_w || rmw_wr_w;
    // ★ 非缓存 / 未命中都走这一条。`!st_cacheable_w` 显式进门: 万一 MMIO 行被吸收, 终止 store
    //   就永远上不了总线 (从机等不到它) ⇒ 死机。让路项与吸收那边同款, 两条合起来恒有解。
    // ★ **同行填充在飞时例外** (判"都不发" = 停一拍重试): 那一拍判旁路 = 该行永远装不上 —— 条目
    //   留在 SQ 里 (sq_pend_w) 毒死这次填充 ⇒ 行不安装 ⇒ 下一轮再缺失 ⇒ 再旁路, **自我否定环**。
    //   rsort 实测: 起填 16474 次只装上 2568 次 (15.6%), 中止拍 99.97% 是同行未落地 store。
    //   等它落地不额外花 AR (填充本来就在飞), 落地后本行 valid ⇒ 自然命中吸收。
    assign st_bypass    = st_valid && (!st_cacheable_w || (!any_st_hit_w && !st_fill_same_w))
                       && !st_wb_same_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rmw_rd1_r  <= 1'b0;
            rmw_v_r    <= 1'b0;
            rmw_set_r  <= {DC_IW{1'b0}};
            rmw_way_r  <= {WY_W{1'b0}};
            rmw_woff_r <= {OFF_W{1'b0}};
            rmw_word_r <= 32'd0;
        end else begin
            if (rmw_rd_w) begin                       // 读相已发出: 记下位置 (老字下一拍到 rdata 上)
                rmw_rd1_r  <= 1'b1;
                rmw_set_r  <= st_set_w;
                rmw_way_r  <= st_way_w;
                rmw_woff_r <= st_word_w;
            end else if (rmw_rd1_r) begin              // 老字在 rdata_w 上 ⇒ 本拍按字节合并
                rmw_rd1_r  <= 1'b0;
                rmw_v_r    <= 1'b1;
                rmw_word_r <= rmw_merge_w;
            end
            if (rmw_wr_w) rmw_v_r <= 1'b0;             // 已落盘 (同拍 st_absorb), 窗口结束
        end
    end

endmodule
