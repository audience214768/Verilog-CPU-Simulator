// L1 指令缓存 (直接映射; tag 与数据同条目放进一块 sram_fakeram)
// 对外接口与 mem_subsystem.v 原"取指预取窗口"逐一对位 (契约见该文件头注释):
//   imem_addr (本拍要请求的批地址) / inst_data + imem_valid (下一拍交付) / imem_hit (本拍地址已可取)
//
// 【为什么 tag 也放 SRAM】fetch 要 imem_valid 与 imem_hit 都是**同拍**判据, 而 sram_fakeram 是同步读
//   (1 拍延迟) ⇒ 纯 SRAM tag 阵列会让两个判据都晚一拍。但纯 DFF tag 阵列太贵: 1 KiB/8 字行 = 32 行 ×
//   22 位 = 704 flop ≈ 670 µm², 比数据阵列本身 (9216 bit ≈ 387 µm²) 还贵。故:
//     · tag 与数据同放一个 SRAM 条目 ⇒ imem_valid 走"晚一拍但精确"的口径, 这恰好就是 fetch 契约要的
//       语义 (本拍 inst_data 属于**上一拍**的 imem_addr); 由不变量②保证条目与地址同源。
//     · imem_hit 退化成只查 DFF valid 位图 (IC_LINES 位, 32 行 = 32 flop) 的**保守**判据。
//
// 【三条不变量 —— 改动本文件必须逐条维持, 破任意一条都会静默交付错指令】
//   ① SRAM 读地址 ≡ line(本拍正在取的那个地址) —— 常态 rd_addr_w = imem_addr[0]; 仅在跨行装配那一拍
//      被改写成 L1 的行基址。
//   ② imem_valid(T) = !rd_div_r(T) && rd_ok_r(T) && valid[q_line(T)] && (条目 tag == rd_addr_q 的 tag)
//      —— rd_addr_q(T) 就是①在 T−1 拍的取值, 故 tag 与数据必然同源。**不是**拿 imem_addr 去比。
//   ③ imem_hit(T) = !straddle(imem_addr[0](T)) && &_g valid[line(imem_addr[g](T))]
//      —— 保守 (不查 tag), 同拍、整批口径。
//   ④ imem_direct(T) = 本拍到达是"直通行"交付 (= !st_wait_r && ②)。**不得依赖 imem_addr**:
//      fetch 拿它做"把一个新请求组合地提前到本拍"的选通 (取指同拍推进, fetch.v 的 exp_next_w)。
//      ② 的装配支 (asm_ok_w) 里 base_same_w 要用 cur_a_w = imem_addr[0] ⇒ 若直接拿 imem_valid
//      当选通就成环 (imem_addr → cur_a_w → asm_ok_w → imem_valid → 选通 → imem_addr)。
//      装配交付因此**不做**同拍重定向 (照旧推迟一拍), 换掉一个组合环; W=1 下 straddle 恒 0,
//      ②与④逐位相等, 无任何损失。
//
// 【③ 保守为什么安全, 以及为什么 miss 必须挂在"交付失败"上】fetch.v 的 pc_next 末支是 exp_pc_r:
//   pc_lead_w 最多让 pc 超前**一个批**, 下一拍到达的不是期望批时 pc_next 自动把 pc 拉回 exp_pc_r。
//   但"假命中只多花一个周期"成立的前提是**那一行会被修好**: 条目 tag 对不上 ⇒ 交付失败 ⇒ 当场对
//   rd_addr_q 那一行发起填充 (清 valid ⇒ imem_hit 立刻落 0 ⇒ pc 被钉在 exp_pc_r 上等填充)。
//   反之若把 miss 判据挂在"请求地址已稳定 (rd_addr_q == imem_addr[0])"上, 就会死锁: 假命中让 pc 每拍
//   在 N / N+4W 之间翻转, 而翻转恰恰让"已稳定"永不成立 ⇒ 一次填充也发不出去 (这就是 mem_subsystem.v
//   与 fetch.v 里反复留档的那个坑)。⇒ miss 判据必须挂在 rd_ok_r && !ent_ok_w 上。
//
// 【单端口 SRAM 的读写冲突】rd_resp_ready 在上层硬连 1 ⇒ 回包不可反压, 到达那拍必须写得进去。故
//   填充写**绝对优先**: 写的那拍读口被占用 ⇒ rd_ok_r=0, 不变量②显式与它相与, 被偷走的读绝不冒充
//   有效数据 (也是防 sram_fakeram 写周期把 rdata 置 x 后传播出去的护栏)。被偷走的读有两种后果, 都在
//   本文件里显式兜住: (a) 直通拍的交付失败 ⇒ miss 兜底重发; (b) 装配中间那拍偷走 L1 的读 ⇒ 下一拍
//   ent_ok 落 0 ⇒ 放弃装配回直通, 由 (a) 兜底。
//
// 【发起填充时必须立刻清 valid】否则旧数据会被新 tag 冒充 ⇒ 假命中 (与 mem_subsystem.v 头注释记的
//   同一处陷阱)。填充的最后一字落地时才置 valid。
//
// 【跨行批 (仅 ISSUE_WIDTH ≥ 2 可达; W=1 时一个字必落在唯一一行内, 整条通路恒定不激活)】
//   批可跨 L0/L1 两行, 走两拍: 第 c 拍 rd_addr_q 指向批基址 A0 且 rdata_w 正是 L0 的条目, 校验通过
//   且 A0 未被重定向改掉 (base_ok_w) ⇒ 把 L0 的尾部窗口锁进 tail_r, 并令 rd_addr_w 改指 L1 行基址;
//   第 c+1 拍 rdata_w 即 L1 条目, 拼 {L1 头部, tail_r} 交付。交付还要求 imem_addr[0] 仍 == st_base_r,
//   不等则本拍不交付、下一拍回直通重来 (重定向/pc 超前会改它)。
//   ★ 装配期间 pc 必须**钉住不动**, 否则第二拍 imem_addr_d 已越过 A0, 交付的批与 fetch 认为的地址
//     错位。故 ③ 里带 !straddle 项: 批跨行时 imem_hit 恒 0 ⇒ pc_lead_w 恒 0 ⇒ pc 停在 A0 等装配。
//     (交付靠 cap_w 那条支路推进 pc, 它不经过 imem_hit。)
//   ★ 装配那一拍读地址被改写成 L1 ⇒ rd_addr_q 不再等于 imem_addr_d, 此时若 imem_valid 仍为 1,
//     fetch.v:80 的 cap_w 会把 L1 的字当成 A0 的批收下 (静默交付错指令)。故用 rd_div_r 把改写过的那
//     一拍显式标记出来, 不变量②与它相与。W=1 时该位恒 0, 整条通路不激活。
//   ★ IC_LINE_WORDS ≥ ISSUE_WIDTH 是硬要求, 否则一个批可能跨三行, 两拍装配不够。
//
// 【I 侧不做 store_queue 合并 / 一致性】§C.7 的 #3/#4 是 D 侧的坑; I 侧对应的是自修改代码。依据
//   architecture.md §C.8 假设 #1: 官方 correctness_* 的可静态解析 store 目标无一落在代码段。
//   **待验证假设** —— 若将来有程序在代码段写指令, 本模块不会看到, 会交付陈旧指令。
//
// 复位异步低有效 (与 axi_lite_master / mem_subsystem 一致; ASAP7 标准单元库只有异步复位触发器)
module icache #(
    parameter ISSUE_WIDTH   = 1,        // 取指批宽 (须 ≤ IC_LINE_WORDS)
    parameter IC_SIZE       = 1024,     // 总容量 (字节; 须为 4*IC_LINE_WORDS 的整数倍, 且行数 ≥ 2)
    parameter IC_LINE_WORDS = 8,        // 每行字数 (2 的幂)
    parameter IC_BYPASS     = 0,        // 1 = 交付一次即失效 ⇒ 每次访问都 miss (缺陷归因对照)
    parameter IC_PREFETCH   = 1         // 1 = 顺需求行预取下一行 (见第 6 节)
) (
    input  clk,
    input  rst_n,

    // ---- CPU 侧 (口径与 mem_subsystem.v 对应端口完全一致) ----
    input  [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    output [ISSUE_WIDTH * 32 - 1 : 0] inst_data,      // 对应**上一拍** imem_addr 的批
    output                            imem_valid,     // 本拍 inst_data 确实是对应地址上的指令
    output                            imem_hit,       // 本拍 imem_addr 整批 W 字都已在缓存里 (保守)
    output                            imem_direct,    // 本拍到达是"直通行"交付 (非跨行装配) —— 供 fetch
                                                     //   把一个新请求组合地提前到本拍 (见头注释④)

    // ---- 到 AXI 读通道 (由上层仲裁; load 优先, 故 ready 可能被抢走) ----
    output                    fill_req_valid,         // 请求读 4 字节 (须保持到 ready)
    output [31 : 0]           fill_req_addr,
    input                     fill_req_ready,
    input                     fill_rsp_valid,         // 与请求一一对应且同序; 不可反压
    input  [31 : 0]           fill_rsp_data,

    output                    fill_busy               // 填充中 (供调试/上层观测量)
);
    // 地址切分: [31:TAGHI] 行 tag | [TAGHI-1:SPLIT] 行号 | [SPLIT-1:2] 行内字偏移 | [1:0] 字节
    localparam IC_LINES = IC_SIZE / (4 * IC_LINE_WORDS);
    localparam IC_IW    = $clog2(IC_LINES);
    localparam OFF_W    = $clog2(IC_LINE_WORDS);
    localparam SPLIT    = 2 + OFF_W;
    localparam TAGHI    = SPLIT + IC_IW;
    localparam TAG_W    = 32 - TAGHI;
    localparam EW       = 32 * IC_LINE_WORDS + 32;    // 条目宽: 数据 + tag (tag 独占最高 32 位 lane)
    localparam TAGOFF   = 32 * IC_LINE_WORDS + TAGHI; // 条目里 tag 字段的起始位 (= EW - TAG_W, 顶对齐)
    localparam WMASK_W  = IC_LINE_WORDS + 1;          // = EW / 写粒度 (32)
    localparam FIW      = $clog2(IC_LINE_WORDS + 1);  // 填充字计数器位宽 (须能表示 IC_LINE_WORDS 本身)

    integer gi;

    // ==================== 1. 网表声明 ====================
    wire [EW - 1 : 0]       rdata_w;                  // 由 u_arr 驱动 (声明在用例之前); 整条目 = tag + LW 字
    wire [31 : 0]           cur_a_w;                  // 本拍批基址 (≡ fetch 的 pc_r)
    wire [OFF_W : 0]        span_c_w, span_q_w;
    wire                    straddle_c_w, straddle_q;
    wire [OFF_W - 1 : 0]    off_q_w, off_w;
    wire                    base_ok_w;
    wire [31 : 0]           asm_l1_w, rd_addr_w;
    wire [IC_IW - 1 : 0]    rd_line_w, q_line_w;
    wire [TAG_W - 1 : 0]    ent_tag_w, rd_tag_w;
    wire                    ent_ok_w, asm_go_w, asm_ok_w, base_same_w;
    wire                    fill_wr_w, fill_hs_w, fill_last_w;
    wire [FIW - 1 : 0]      fill_wi_w;
    wire [WMASK_W - 1 : 0]  wmask_w;
    wire [EW - 1 : 0]       wdata_w;
    wire [31 : 0]           fill_new_base_w, pf_base_w;
    wire [IC_IW - 1 : 0]    pf_line_w;
    wire                    miss_w, pf_go_w, fill_start_w;
    wire [ISSUE_WIDTH - 1 : 0] hit_g;
    wire [OFF_W : 0]        iw_w;

    // ==================== 2. 顺序状态 ====================
    reg  [31 : 0]                   rd_addr_q;        // 上一拍发起读的地址 (在飞条目对应的地址)
    reg                             rd_ok_r;          // 上一拍发起的是"读"而非填充写
    reg                             rd_div_r;         // 上一拍的读地址被跨行装配改写过
    reg                             st_wait_r;        // 跨行装配: L1 的读已发出, 本拍等 rdata_w 到达
    reg  [31 : 0]                   st_base_r;        // 进入装配时的批基址 A0
    reg  [ISSUE_WIDTH * 32 - 1 : 0] tail_r;           // 装配用: L0 的尾部窗口 (按槽对齐存放)
    reg  [IC_LINES - 1 : 0]         valid_r;          // 行有效位图 (唯一须同拍可读的状态, 不变量③)
    reg  [IC_IW - 1 : 0]            fill_line_r;      // 正在填充的行
    reg  [31 : 0]                   fill_base_r;      // 正在填充的行的行基址
    reg  [FIW - 1 : 0]              fill_word_r;      // 下一笔要发 AR 的行内字下标
    reg  [FIW - 1 : 0]              fill_cnt_r;       // 已回包的字数 (回包与请求同序 ⇒ 即字 lane)
    reg                             fill_busy_r;

    // ==================== 3. 读地址与在飞条目 (不变量①) ====================
    assign iw_w     = ISSUE_WIDTH;                    // 截断到 OFF_W+1 位
    assign cur_a_w  = imem_addr[0 * 32 +: 32];
    assign off_q_w  = rd_addr_q[2 +: OFF_W];
    // span = **批内最后一字的行内下标** = off + ISSUE_WIDTH - 1; 跨行 ⟺ span ≥ IC_LINE_WORDS。
    //   off + W - 1 至多 2*IC_LINE_WORDS-2, 恰能放进 OFF_W+1 位 ⇒ 最高位就是"跨行"判据。
    //   (写成 off+W 会多判一个: W=1 且 off=LW-1 时批发=LW 却根本不跨行, 会让每行末字永远交付不出去)
    assign span_c_w = { 1'b0, cur_a_w[2 +: OFF_W] } + iw_w - 1'b1;
    assign span_q_w = { 1'b0, off_q_w } + iw_w - 1'b1;
    assign straddle_c_w = span_c_w[OFF_W];
    assign straddle_q   = span_q_w[OFF_W];
    assign base_ok_w    = (cur_a_w == rd_addr_q);     // 请求没动过 (读的就是本拍要交付的那个地址)
    // 装配第二拍要用的是 L0 的偏移 (此时 rd_addr_q 已被改写成 L1 行基址, 其偏移恒 0)
    assign off_w = st_wait_r ? st_base_r[2 +: OFF_W] : off_q_w;

    assign fill_wr_w  = fill_rsp_valid;               // 写绝对优先 (回包不可反压)
    assign fill_wi_w  = fill_cnt_r;
    // 装配发起: 在飞条目就是本拍的批基址 A0、整批装不下、校验通过 ⇒ 锁尾部窗口并改指 L1
    assign asm_go_w   = !st_wait_r && straddle_q && ent_ok_w && base_ok_w;
    assign asm_l1_w   = { rd_addr_q[31 : SPLIT], {SPLIT{1'b0}} } + 32'd4 * IC_LINE_WORDS;
    assign rd_addr_w  = st_wait_r ? (st_base_r + 32'd4 * IC_LINE_WORDS)
                      : asm_go_w  ? asm_l1_w
                      :             cur_a_w;
    assign rd_line_w  = rd_addr_w[SPLIT +: IC_IW];
    assign q_line_w   = rd_addr_q[SPLIT +: IC_IW];

    // ==================== 4. sram_fakeram 阵列 ====================
    // wmask: 最高 lane 是 tag, 低 IC_LINE_WORDS 个 lane 是数据字; 每次只写 tag lane 与回包那个字 lane。
    // 未选中的 lane 被 sram_fakeram 按 wmask 丢弃 ⇒ 所有数据 lane 填回包值即可, 无需组装寄存器。
    assign wmask_w = fill_wr_w
        ? (({{(WMASK_W - 1){1'b0}}, 1'b1} << IC_LINE_WORDS)
         | ({{(WMASK_W - 1){1'b0}}, 1'b1} << fill_wi_w[OFF_W - 1 : 0]))
        : {WMASK_W{1'b0}};
    assign wdata_w = { fill_base_r[31 : TAGHI], {(32 - TAG_W){1'b0}},
                       {IC_LINE_WORDS{fill_rsp_data}} };

    sram_fakeram #(
        .DEPTH             (IC_LINES),
        .WIDTH             (EW),
        .WRITE_GRANULARITY (32)
    ) u_arr (
        .clk   (clk),
        .en    (1'b1),
        .we    (fill_wr_w),
        .wmask (wmask_w),
        .addr  (fill_wr_w ? fill_line_r : rd_line_w),
        .wdata (wdata_w),
        .rdata (rdata_w)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_q <= 32'd0;
            rd_ok_r   <= 1'b0;
            rd_div_r  <= 1'b0;
        end else begin
            rd_addr_q <= rd_addr_w;
            rd_ok_r   <= !fill_wr_w;                  // 写的那拍没读 ⇒ 下一拍的条目不可信
            rd_div_r  <= st_wait_r || asm_go_w;       // 本拍读地址被改写 ⇒ 下一拍 q 与 imem_addr_d 错位
        end
    end

    // ==================== 5. 校验 / 交付 / 命中 (不变量②③) ====================
    // tag 在条目**最高** TAG_W 位 (wdata_w 的拼接顺序决定); 与 rd_tag_w 同切法 ⇒ 同源可比
    assign ent_tag_w = rdata_w[TAGOFF +: TAG_W];
    assign rd_tag_w  = rd_addr_q[TAGHI +: TAG_W];
    assign ent_ok_w  = rd_ok_r && valid_r[q_line_w] && (ent_tag_w == rd_tag_w);
    assign base_same_w = (cur_a_w == st_base_r);      // 装配第二拍: 批基址未被重定向/pc 超前改掉
    assign asm_ok_w  = ent_ok_w && base_same_w;

    assign imem_valid = st_wait_r ? asm_ok_w : imem_direct;
    // ④ 直通行交付: 不含跨行装配那一支。**本信号不得依赖 imem_addr** —— 它是 fetch 用来把一个新
    //    请求组合地提前到本拍的选通 (见 fetch.v 的 exp_next_w)。asm_ok_w 里的
    //    base_same_w 却要用 cur_a_w (= imem_addr[0]) 判断"批基址有没有被重定向改掉" ⇒ 若拿
    //    imem_valid 当那个选通, 就会成环: imem_addr → cur_a_w → asm_ok_w → imem_valid → 选通 →
    //    imem_addr。装配拍只占极少数 (且 ISSUE_WIDTH=1 下 straddle 恒 0, 整条路是死代码),
    //    故装配交付照旧走"请求推迟一拍", 不做同拍重定向 —— 换掉一个组合环。
    assign imem_direct = !st_wait_r && ent_ok_w && !straddle_q && !rd_div_r;

    genvar gw;
    generate
        for (gw = 0; gw < ISSUE_WIDTH; gw = gw + 1) begin : win
            wire [OFF_W : 0]     ix_w = { 1'b0, off_w } + gw;   // off+g (g<W≤LW ⇒ 至多 2LW-2, 不绕回)
            wire [OFF_W - 1 : 0] lo_w = ix_w[OFF_W - 1 : 0];    // off+g 落在本行的下标 (mod LW)
            wire                 l1_w = ix_w[OFF_W];            // off+g ≥ LW ⇒ 该槽取自 L1 的头部
            // 直通拍 (含装配发起那拍): 整批都在 rdata_w 里; 装配交付拍: 低槽取 tail_r, 高槽取 L1 头部
            assign inst_data[gw * 32 +: 32] = (!st_wait_r || l1_w) ? rdata_w[lo_w * 32 +: 32]
                                                                   : tail_r[gw * 32 +: 32];
        end
    endgenerate

    genvar gh;
    generate
        for (gh = 0; gh < ISSUE_WIDTH; gh = gh + 1) begin : hit
            assign hit_g[gh] = valid_r[imem_addr[gh * 32 + SPLIT +: IC_IW]];
        end
    endgenerate
    // ③ 保守 (不查 tag), 同拍、整批口径。跨行批恒 0 ⇒ 装配期间 pc 被钉住 (见文件头)。
    assign imem_hit = (IC_BYPASS == 0) && !straddle_c_w && (&hit_g);

    // ==================== 6. 跨行装配状态 ====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_wait_r <= 1'b0;
            st_base_r <= 32'd0;
            tail_r    <= {ISSUE_WIDTH * 32{1'b0}};
        end else begin
            st_wait_r <= asm_go_w;
            if (asm_go_w) begin
                st_base_r <= rd_addr_q;
                // L0 的尾部窗口 (off_q+g < LW 的槽); 其余槽存的是绕回值, 交付时由 l1_w 挡掉
                for (gi = 0; gi < ISSUE_WIDTH; gi = gi + 1)
                    tail_r[gi * 32 +: 32]
                        <= rdata_w[(({ 1'b0, off_q_w } + gi[OFF_W : 0]) & (IC_LINE_WORDS - 1)) * 32 +: 32];
            end
        end
    end

    // ==================== 7. 填充器 (单 MSHR) + 下一行预取 ====================
    // ★ miss 判据挂在**交付失败**上, 不挂在"请求地址已稳定"上 (理由见文件头)。
    //   装配拍 (st_wait_r) 不算: 那一拍的 ent_ok 说的是 L1, 交付失败由下一拍的直通拍兜底。
    assign miss_w = rd_ok_r && !ent_ok_w && !fill_busy_r && !st_wait_r;
    // 填的就是"刚刚读失败的那一行" ⇒ 顺手把让 imem_hit 说假话的那个 valid 位清掉, 自纠正
    assign fill_new_base_w = miss_w ? { rd_addr_q[31 : SPLIT], {SPLIT{1'b0}} } : pf_base_w;

    // 顺需求预取下一行: 需求行已 valid 而下一行未 valid ⇒ 填它。自限一行 (填完 valid 置起, 条件自然
    // 不再成立); 需求行一失效/装配一起步, 这里立刻让位, 不占总线。
    assign pf_line_w = cur_a_w[SPLIT +: IC_IW] + 1'b1;                 // 模 IC_LINES
    assign pf_base_w = { cur_a_w[31 : SPLIT], {SPLIT{1'b0}} } + 32'd4 * IC_LINE_WORDS;
    assign pf_go_w   = (IC_PREFETCH != 0) && (IC_BYPASS == 0) && !fill_busy_r && !st_wait_r && !asm_go_w
                     && valid_r[cur_a_w[SPLIT +: IC_IW]] && !valid_r[pf_line_w];
    assign fill_start_w = miss_w || pf_go_w;                           // miss 优先于预取

    assign fill_req_valid = fill_busy_r && (fill_word_r != IC_LINE_WORDS);
    assign fill_req_addr  = fill_base_r + {{(30 - OFF_W){1'b0}}, fill_word_r[OFF_W - 1 : 0], 2'b00};
    assign fill_busy      = fill_busy_r;
    assign fill_hs_w      = fill_req_valid && fill_req_ready;
    assign fill_last_w    = fill_rsp_valid && (fill_cnt_r == IC_LINE_WORDS - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_busy_r <= 1'b0;
            fill_line_r <= {IC_IW{1'b0}};
            fill_base_r <= 32'd0;
            fill_word_r <= {FIW{1'b0}};
            fill_cnt_r  <= {FIW{1'b0}};
        end else if (fill_start_w) begin
            fill_busy_r <= 1'b1;
            fill_line_r <= fill_new_base_w[SPLIT +: IC_IW];
            fill_base_r <= fill_new_base_w;
            fill_word_r <= {FIW{1'b0}};
            fill_cnt_r  <= {FIW{1'b0}};
        end else if (fill_busy_r) begin
            if (fill_hs_w)      fill_word_r <= fill_word_r + 1'b1;     // 被 load 抢走就原地重试
            if (fill_rsp_valid) fill_cnt_r  <= fill_cnt_r + 1'b1;
            if (fill_last_w)    fill_busy_r <= 1'b0;
        end
    end

    // ==================== 8. 行有效位图 ====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {IC_LINES{1'b0}};
        end else begin
            // 旁路模式最低优先级: 交付一次即失效 ⇒ 下次访问必 miss
            if ((IC_BYPASS != 0) && imem_valid) valid_r[q_line_w] <= 1'b0;
            // ★ 发起填充即清 valid —— 不清就是"旧数据冒充新 tag"的假命中
            if (fill_start_w) valid_r[fill_new_base_w[SPLIT +: IC_IW]] <= 1'b0;
            // 最后一字落地才置位 —— 中途置位会把半行当整行交付
            if (fill_last_w)  valid_r[fill_line_r] <= 1'b1;
        end
    end
endmodule
