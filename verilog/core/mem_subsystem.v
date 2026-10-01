// 存储子系统: 把 cpu_top 的存储接口 (与 core/memory.v:10-38 逐一对位) 接到 axi_lite_master
// 内部四块: load 适配 (含 L1 数据缓存 core/dcache.v) / L1 指令缓存 (core/icache.v) /
//           已提交 store 队列 (store_queue) / 读口仲裁
//
// 【为什么不能简单直连】fetch.v 的隐含契约是"地址 A 上总线, 下一拍 inst_data 就是 A 处指令"
// (memory.v 的同步读), 而 AXI 读要 ~12 拍。故中间必须有缓存: 未命中那拍不交付 (imem_valid=0),
// fetch 自会把请求停在期望批上等填充 (见 fetch.v 的 pc_next 末支与 imem_hit)。
//
// 【取指通路 = L1 指令缓存】交付语义与本模块原"取指预取窗口"逐一对位 (同拍 imem_addr 请求 /
//   下一拍 inst_data + imem_valid / 本拍 imem_hit 整批口径), 故 fetch.v 一行不改。实现与三条
//   不变量、单端口读写冲突、跨行批两拍装配、miss 为何必须挂在"交付失败"上, 全部见 icache.v 头注释。
//   本模块只负责把填充请求接进 AXI 读通道 (load 优先) 并把回包按序送回。两条硬要求:
//   - ★ IC_LINE_WORDS ≥ ISSUE_WIDTH: 否则一个批可能跨三行, 两拍装配不够。
//   - ★ 响应与请求一一对应且**同序** (AXI 按 AR 序回) ⇒ 填充侧只需 1 位 tag 区分 load/填充;
//     icache 内部用 fill_cnt_r 数回包, 不在 tag 里编码行号/字号。
//   相对窗口的收益 (实测数字见 docs/timing/results.csv): 窗口是 16 格 × 66 bit = 1088 flop 却只装
//   64 字节, 且 4 个读口都是 one-hot + AND-OR 归约网 (idat[0].oh_g 实测扇出恒定 1040);
//   缓存把数据与 tag 一起放进 sram_fakeram (每比特便宜约 7 倍), DFF 只剩 IC_LINES 位 valid 位图。
//
// 【load 通路】ld_busy==0 是**必须当场兑现**的硬承诺 (lsq.v:158 组合自 !ld_busy, 且收到即置 issued;
//   反悔 ⇒ 该条目永久在飞 ⇒ head 卡死): 故 ld_busy 只由"在飞数 + D-cache 当拍能否收下"组合决定, 且
//   load 在发请求时**优先于**两条填充。每个被接受的 load **恰好**回一个 ld_done_valid (交付源与请求
//   一一对应, 且 rresp 不参与门控 —— LSQ 没有错误口, 少一个脉冲就是死锁)。
//   子字抽取: araddr 强制 4 字节对齐, 数据右移 8*addr[1:0] 后**零扩展** (符号扩展由 lsq.v:291-297 做)。
//   ⚠ 由此不支持跨 4 字节边界的非对齐访问 (memory.v 的平铺字节数组支持); 编译产出的 C 代码不会产生。
//
// 【L1 数据缓存 (core/dcache.v)】未命中 ⇒ 发一笔 AR (走第 6 节仲裁) 并按行填充; 命中 ⇒ T+1 当拍交付。
//   全部不变量 (单交付源/命中降级/skid/MSHR 合并/写偷读/填充污染) 见 dcache.v 头注释, 改这一节前先读它。
//   本模块只多担两件事:
//     a) **完成序 ≠ 接受序** ⇒ 地址/宽度/idx 记在**按缺失推送序**的 miss 队列里 (推送时写、回包时读),
//        命中则直接取 dcache 当拍给的 hit_*; 交付数据的字节合并链因此只需**一条**, 输入由 dl_* 选。
//     b) **store 一致性**: 提交即按索引失效 (`inv_valid`), 并把"B 尚未落盘"的 SQ 条目所占组号位图
//        (`sq_blk`) 交给 dcache 判填充污染 —— 两者缺一都会把旧数据装进行 (静默算错)。
//
// 【store 可见性空洞 —— 本次唯一不可简化处】已提交 store 立即离开 LSQ (cpu_top 的 cmt_invalidate),
//   而 lsq.v 的字节合并只看仍在 LSQ 里的更老条目; 加上从机对读/写**随机**决定先后 ⇒ 一个在旧 store
//   落到从机内存之前被服务的读会读到旧值, 而该 store 已离开 LSQ 无人兜底 ⇒ 静默算错。故:
//     1) 合并层次 memory < store_queue < LSQ (LSQ 那层在 lsq.v 内, 作用于本模块输出的 ld_done_data)
//     2) 队列里任一条恒比"当前正在完成的 load"更老: 它已退休 ⇒ 程序序在前; 而该 load 尚未完成 ⇒
//        尚未退休; 退休是程序序 ⇒ 不可能有更年轻的指令先退休。故可无条件并入该 load 的结果。
//     3) "提交与完成同拍"那一拍由**上层 LSQ** 兜: 该 store 此刻仍在 LSQ 里 (失效在 posedge), 且必然
//        比完成的 load 老 ⇒ 命中 lsq.v 的 `(j - hd) < dd` 合并。本模块**不**重复并入 (并入即组合环)
//     4) 退休条件比 B 握手更严: B 已握手 **且** 该 B 到达时已发出的 load 都已完成 —— 那些 load 的读
//        可能在该 store 落到从机之前就被服务了; 之后发出的 load 必在落盘之后才被服务, 无需再兜
//     5) ★ 有 D-cache 后 (2)(4) 还要加一条: 命中是**从缓存**交付的, 它同样可能读到旧值, 而缓存里的
//        旧值不会自己消失 ⇒ 上面两条对命中路径同样必需 (故 (2) 的合并链必须同时覆盖命中与回包)。
//
// 复位异步低有效 (与 axi_lite_master 一致; ASAP7 标准单元库只有异步复位触发器)
module mem_subsystem #(
    parameter ISSUE_WIDTH   = 1,
    parameter LSQ_SIZE      = 16,
    parameter IC_SIZE       = 1024,   // I-cache 总容量 (字节)
    parameter IC_LINE_WORDS = 8,      // I-cache 行字数 (2 的幂; 须 ≥ ISSUE_WIDTH)
    parameter IC_BYPASS     = 0,      // 1 = 交付一次即失效 ⇒ 每次访问都 miss (缺陷归因对照)
    parameter IC_PREFETCH   = 1,      // 1 = 顺需求行预取下一行
    // L1 数据缓存 (core/dcache.v)。DC_SIZE=0 ⇒ 全缺失, 每次 load 都走 AXI (消融对照)。
    // ★ 这三个必须原样透传给 u_dc; 本模块只**重算**一遍组号切分 (见 DC_SPLIT/DC_TAGHI), 两处
    //   的公式必须逐字一致 —— 不一致会让 sq_blk 的位图与 dcache 的 fill_set_r 对不上号。
    parameter DC_SIZE       = 2048,   // D-cache 总容量 (字节)
    parameter DC_LINE_WORDS = 8,      // D-cache 行字数 (2 的幂)
    parameter DC_WAYS       = 1,      // D-cache 相联度
    parameter LD_INFLIGHT   = 8,      // 在飞 load 上限
    parameter SQ_DEPTH      = 8,      // 已提交未可见 store 队列深度
    // ★ RD_DEPTH ≥ 2 * IC_LINE_WORDS, 且必须是 2 的幂 (axi_lite_master 的指针按 2^PW 取模)。
    //   一次行填充要背靠背连发 IC_LINE_WORDS 笔 AR; 而读 FIFO 实际容量是 RD_DEPTH-1
    //   (axi_lite_master.v:87 的 rd_full_w 留一格区分空满), 容量不足时填充被自己节流:
    //   仍能完成 (每收到一个回包放行一笔请求), 但整行填充从 LATENCY+LW 拉长到约 2*LATENCY+L
    //   —— 实测 tb_mem_axi 的 T1 由 54 拍劣化到 70 拍。故留一倍余量。
    parameter RD_DEPTH      = 16,     // AXI 读事务 FIFO 深度
    parameter WR_DEPTH      = 8       // AXI 写事务 FIFO 深度
) (
    input  clk,
    input  rst_n,

    // ---- CPU 侧: 取指 (同步读语义: inst_data 对应上一拍的 imem_addr) ----
    output [ISSUE_WIDTH * 32 - 1 : 0] inst_data,
    input  [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    output                            imem_valid,   // 本拍 inst_data 确实是对应地址上的指令
    output                            imem_hit,     // 本拍 imem_addr **整批 W 个字**都已在窗口里
                                                   //  (供 fetch 判能否预先发下一批请求; 必须与 imem_valid 同口径,
                                                   //   只比批首会让 W≥2 的 pc 每拍翻转, 见文件内该 assign 的注释)

    // ---- CPU 侧: load (发起 ≤1/周期, 完成 ≤1/周期) ----
    input                             ld_start_valid,
    input  [31 : 0]                   ld_start_addr,
    input  [1 : 0]                    ld_start_width,
    input  [$clog2(LSQ_SIZE) - 1 : 0] ld_start_idx,
    output                            ld_done_valid,
    output [$clog2(LSQ_SIZE) - 1 : 0] ld_done_idx,
    output [31 : 0]                   ld_done_data,
    output                            ld_busy,

    // ---- CPU 侧: store (提交级 1 拍脉冲; 队列满则 sw_ready=0, cpu_top 须压住该拍提交) ----
    input                             sw_valid,
    input  [31 : 0]                   sw_addr,
    input  [31 : 0]                   sw_data,
    input  [1 : 0]                    sw_width,
    output                            sw_ready,

    // ---- AXI4-Lite 从机接口 (直通顶层引脚) ----
    output [31 : 0] araddr,
    output          arvalid,
    input           arready,
    input  [31 : 0] rdata,
    input  [1 : 0]  rresp,
    input           rvalid,
    output          rready,
    output [31 : 0] awaddr,
    output          awvalid,
    input           awready,
    output [31 : 0] wdata,
    output [3 : 0]  wstrb,
    output          wvalid,
    input           wready,
    input  [1 : 0]  bresp,
    input           bvalid,
    output          bready
);
    localparam LD_IW = $clog2(LD_INFLIGHT);
    localparam LIW   = $clog2(LSQ_SIZE);
    localparam SQ_IW = $clog2(SQ_DEPTH);
    // AXI 读 tag: 2 位, **按值精确比较** (不是拿最高位当"是不是 load"的开关)。
    //   回包与请求同序 (AXI 按 AR 序回), 故同 tag 内不需要序号; 但读通道现在有三个用户, 而取指
    //   填充与 D-cache 填充是两条**独立**的计数器链 —— 用 1 位区分时 D 填充的回包会被 icache 数进
    //   自己的格子 (装错行/装错字)。同一个 tag 内部的顺序由各自的 fill_cnt 保证。
    localparam TW       = 2;
    localparam [1:0] TAG_IFILL = 2'b00;    // 取指填充
    localparam [1:0] TAG_LOAD  = 2'b01;    // load 需求读
    localparam [1:0] TAG_DFILL = 2'b10;    // D-cache 行填充
    // dcache.v 的组号切分 —— 必须与那里第 100~105 行逐字一致 (sq_blk 的位序靠它对齐)
    localparam DC_SETSR = DC_SIZE / (4 * DC_LINE_WORDS * DC_WAYS);
    localparam DC_SETS  = (DC_SETSR < 1) ? 1 : (1 << $clog2(DC_SETSR));
    localparam DC_IW    = (DC_SETS < 2) ? 1 : $clog2(DC_SETS);
    localparam DC_SPLIT = 2 + $clog2(DC_LINE_WORDS);   // 组号的低位 (= 行内字偏移 + 字节偏移)

    // 宽度编码 (00=1 01=2 10=4 字节) → 字节数 / 选通掩码
    function [2 : 0] wd_bytes;
        input [1 : 0] w;
        begin
            wd_bytes = (w == 2'b10) ? 3'd4 : (w == 2'b01) ? 3'd2 : 3'd1;
        end
    endfunction
    function [3 : 0] wd_mask;
        input [1 : 0] w;
        begin
            wd_mask = (w == 2'b10) ? 4'hF : (w == 2'b01) ? 4'h3 : 4'h1;
        end
    endfunction
    // ==================== 1. AXI4-Lite 主机 ====================
    wire                 rd_req_valid, rd_req_ready, rd_resp_valid, rd_resp_ready;
    wire [31 : 0]        rd_req_addr, rd_resp_data;
    wire [1 : 0]         rd_resp_resp;
    wire [TW - 1 : 0]    rd_req_tag, rd_resp_tag;
    wire                 wr_req_valid, wr_req_ready, wr_resp_valid, wr_resp_ready;
    wire [31 : 0]        wr_req_addr, wr_req_data;
    wire [3 : 0]         wr_req_strb;
    wire [SQ_IW - 1 : 0] wr_req_tag, wr_resp_tag;
    wire [1 : 0]         wr_resp_resp;

    // 跨节连线 —— 驱动器分别在第 2/3/4/5 节, 这里只声明 (iverilog 要求"先声明后引用",
    // 把声明跟着驱动器走会让引用点报 Unable to bind)。
    wire                  dc_hit_valid, dc_ms_valid, dc_busy, dc_fill_valid, dc_fill_ready;
    wire                  dc_unused_fill_busy, dc_ms_ready, dc_ms_fire_w, dfill_rsp_valid_w;
    wire [31 : 0]         dc_hit_word, dc_hit_addr, dc_ms_addr, dc_fill_addr;
    wire [1 : 0]          dc_hit_width, dc_ms_width;
    wire [LIW - 1 : 0]    dc_hit_idx, dc_ms_idx;
    wire [DC_SETS - 1 : 0] sq_blk_w;

    axi_lite_master #(
        .RD_DEPTH(RD_DEPTH), .WR_DEPTH(WR_DEPTH), .RD_TW(TW), .WR_TW(SQ_IW)
    ) u_axi (
        .clk(clk), .rst_n(rst_n),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_req_addr(rd_req_addr), .rd_req_tag(rd_req_tag),
        .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready),
        .rd_resp_data(rd_resp_data), .rd_resp_resp(rd_resp_resp), .rd_resp_tag(rd_resp_tag),
        .wr_req_valid(wr_req_valid), .wr_req_ready(wr_req_ready),
        .wr_req_addr(wr_req_addr), .wr_req_data(wr_req_data),
        .wr_req_strb(wr_req_strb), .wr_req_tag(wr_req_tag),
        .wr_resp_valid(wr_resp_valid), .wr_resp_ready(wr_resp_ready),
        .wr_resp_resp(wr_resp_resp), .wr_resp_tag(wr_resp_tag),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );
    assign rd_resp_ready = 1'b1;      // 回包当场消化: 取指写窗口, load 当拍出 ld_done_valid
    assign wr_resp_ready = 1'b1;      // B 只用于置 sq_b_ack

    // ==================== 2. load 通路 (D-cache + miss 队列) ====================
    // ★ 完成序 ≠ 接受序 ⇒ 地址/宽度/idx 必须记在**按缺失推送序**的队列里, 不能再像"无缓存版"
    //   那样回包时按接受序的读指针取 —— 命中在 T+1 交付、缺失在 LATENCY 后交付, 两者交错时按
    //   接受序配数据会把 A 的 idx 连上 B 的数据 (静默写错目的寄存器)。故:
    //     · 推送 (ms_valid && ms_ready) 时把 dcache 给的 payload 压进 ld_*_r
    //     · 回包 (ld_resp_hs) 时按 ld_rd_p 取用 —— AXI 按 AR 序回, 而缺失推送序就是 AR 发射序
    reg [LD_INFLIGHT * 32 - 1 : 0]  ld_addr_r;   // miss 队列: 推送时写, 回包时读
    reg [LD_INFLIGHT * 2 - 1 : 0]   ld_width_r;
    reg [LD_INFLIGHT * LIW - 1 : 0] ld_idx_r;
    // 指针位宽 = LD_IW+1 (不是 LD_IW): 在飞数要能表示到 LD_INFLIGHT **本身**, 而 LD_IW 位的差
    // 是 mod LD_INFLIGHT 的 (N 与 0 同码) ⇒ "在飞 == N" 永不成立, 满判据失效, 第 N+1 条会覆盖
    // 第 1 条的槽位 (地址/idx 错位 ⇒ 完成脉冲带错 idx, LSQ 等一个永远不来的 ld_done ⇒ 挂死)。
    // 默认 8 时被 AXI 读深度 RD_DEPTH=8 掩盖, LD_INFLIGHT=2 时暴露。数组下标取低位 LD_IW 位。
    reg [LD_IW : 0]                 ld_wr_p, ld_rd_p;

    wire [LD_IW : 0] ld_inflight_w = ld_wr_p - ld_rd_p;
    wire ld_accept  = ld_start_valid && !ld_busy;
    wire ld_resp_hs = rd_resp_valid && (rd_resp_tag == TAG_LOAD);
    // ★ 占用 = 已推送未回包 + **本拍正在推送的那条**。后一项是"推送比接受晚"的补账:
    //   接受发生在 T, 写指针要到 T+1(或更晚, park 时)才动, 而接受那一刻数组槽还没被占。
    //   不补这一项时: 数组满 8 条 (满槽) 那拍若在飞数=8 且本拍有推送, 上一拍放行的接受
    //   会在下一拍推到第 9 条 ⇒ `ld_wr_p[LD_IW-1:0]` 回绕, **覆盖最老那条的 addr/width/idx**
    //   ⇒ 它的回包带着新 load 的 idx ⇒ LSQ 清错 issued_r 位、正确那位恒 1 ⇒ head 卡死 (全机冻结)。
    //   实测 hanoi: t=1193 打印 inflight=8 wr=3 rd=11 slot=3 (live = 槽 3..2 全 8 格) —— 铁证。
    //   ★ 归纳: 接受 ⇒ busy=0 ⇒ 查表寄存器空闲或本拍被消化 ⇒ **在飞未推送的 load 至多 1 条**,
    //     且它的推送最早在下一拍 ⇒ 只要接受那拍 `在飞 + 本拍推送 + 1 <= LD_INFLIGHT` 就永不越界。
    //   (dcache 的 busy 管的是"查表寄存器能否收下", 管不到槽位计数, 两项缺一不可。)
    wire [LD_IW : 0] ld_occ_w = ld_inflight_w + {{LD_IW{1'b0}}, dc_ms_fire_w};
    // ★ 硬承诺: 有槽位余量**且** D-cache 当拍收得下才说不忙。`!rd_req_ready` 已**不**进门:
    //   命中不占 AXI 槽位, 拿通道可用性闸接受会把纯命中流一起掐死; 缺失推不出去时 dcache 用
    //   查表寄存器本身当 skid 并当拍抬高 busy, 由 busy 这一项独立兜住 (见 dcache.v 第二条不变量)。
    assign ld_busy = (ld_occ_w >= LD_INFLIGHT) || dc_busy;

    wire [31 : 0]      ld_a_w = ld_addr_r[ld_rd_p[LD_IW - 1 : 0] * 32 +: 32];
    wire [1 : 0]       ld_w_w = ld_width_r[ld_rd_p[LD_IW - 1 : 0] * 2 +: 2];
    wire [LIW - 1 : 0] ld_i_w = ld_idx_r[ld_rd_p[LD_IW - 1 : 0] * LIW +: LIW];

    // ---- D-cache (端口连线已在第 1 节声明) ----
    dcache #(
        .DC_SIZE(DC_SIZE), .DC_LINE_WORDS(DC_LINE_WORDS), .DC_WAYS(DC_WAYS), .LSQ_SIZE(LSQ_SIZE)
    ) u_dc (
        .clk(clk), .rst_n(rst_n),
        .lk_valid(ld_accept), .lk_addr(ld_start_addr), .lk_width(ld_start_width), .lk_idx(ld_start_idx),
        .rsp_busy(ld_resp_hs),
        .hit_valid(dc_hit_valid), .hit_word(dc_hit_word), .hit_addr(dc_hit_addr),
        .hit_width(dc_hit_width), .hit_idx(dc_hit_idx),
        .ms_valid(dc_ms_valid), .ms_addr(dc_ms_addr), .ms_width(dc_ms_width), .ms_idx(dc_ms_idx),
        .ms_ready(dc_ms_ready),
        .fill_req_valid(dc_fill_valid), .fill_req_addr(dc_fill_addr), .fill_req_ready(dc_fill_ready),
        .fill_rsp_valid(dfill_rsp_valid_w), .fill_rsp_data(rd_resp_data),
        .inv_valid(sw_valid), .inv_addr(sw_addr), .sq_blk(sq_blk_w),
        .busy(dc_busy), .fill_busy(dc_unused_fill_busy)
    );

    assign ld_done_valid = dc_hit_valid || ld_resp_hs;       // dcache 保证二者互斥 ⇒ 每拍恰一个
    assign ld_done_idx   = dc_hit_valid ? dc_hit_idx : ld_i_w;

    // 交付数据的统一 mux: 命中与回包互斥 ⇒ 第 4 节的字节合并链只需**一条**, 输入由 dl_* 选。
    // (复制两条合并链不仅白费面积, 还会让"合并只看 SQ 快照"这条论证出现两个副本。)
    wire [31 : 0] dl_addr_w  = dc_hit_valid ? dc_hit_addr  : ld_a_w;
    wire [1 : 0]  dl_width_w = dc_hit_valid ? dc_hit_width : ld_w_w;
    wire [31 : 0] dl_word_w  = dc_hit_valid ? dc_hit_word  : rd_resp_data;
    wire [31 : 0] dl_raw_w   = dl_word_w >> {dl_addr_w[1 : 0], 3'b000};   // 对齐字 → 该地址起的字节

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_wr_p <= {(LD_IW + 1){1'b0}};
            ld_rd_p <= {(LD_IW + 1){1'b0}};
        end else begin
            if (dc_ms_fire_w) ld_wr_p <= ld_wr_p + 1'b1;
            if (ld_resp_hs)   ld_rd_p <= ld_rd_p + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (dc_ms_fire_w) begin
            ld_addr_r[ld_wr_p[LD_IW - 1 : 0] * 32 +: 32]  <= dc_ms_addr;
            ld_width_r[ld_wr_p[LD_IW - 1 : 0] * 2 +: 2]   <= dc_ms_width;
            ld_idx_r[ld_wr_p[LD_IW - 1 : 0] * LIW +: LIW] <= dc_ms_idx;
        end
    end

    // ==================== 3. L1 指令缓存 ====================
    // 交付语义与原来的取指预取窗口逐一对位 (同拍 imem_addr 请求 / 下一拍 inst_data + imem_valid /
    // 本拍 imem_hit 整批口径), 故 fetch.v 与 cpu_top 一行不改。三条不变量与全部实现理由见
    // core/icache.v 头注释 —— 改这一节前先读那份注释。
    wire          fill_req_valid_w;
    wire [31 : 0] fill_req_addr_w;
    // ★ 填充为需求 load 让路: 口径是"本拍真正的需求 AR 用户"(= dc_ms_valid), **不是**"本拍有
    //   load 被接受"。有 D-cache 后两者不再是同一件事 —— 命中流的 ld_accept 每拍为 1 却不占 AR
    //   槽, 拿它让路会把取指填充与 D 填充双双饿死。定义在第 6 节 (与另两个 ready 一起看)。
    // icache 的 fill_busy 是纯观测量, 本模块不用。**必须接一根真实导线**, 不能写 `.fill_busy()`:
    // 空连接在 MODE=diagnose 的 OPT_HIER (-hieropt) 下会报 "Port fill_busy ... not found in
    // module $paramod$...\icache" —— 该 pass 会重写参数化模块的端口表, 空连接项处理不了。
    // (MODE=opt 走 -flatten, 没有这个 pass, 所以一直没暴露)
    wire          unused_fill_busy_w;
    // 回包分流: 按 tag **值**精确比较 (三个读用户各一个码字, 见第 1 节 TW 的注释)
    wire          fill_rsp_valid_w = rd_resp_valid && (rd_resp_tag == TAG_IFILL);
    assign dfill_rsp_valid_w = rd_resp_valid && (rd_resp_tag == TAG_DFILL);

    icache #(
        .ISSUE_WIDTH(ISSUE_WIDTH), .IC_SIZE(IC_SIZE), .IC_LINE_WORDS(IC_LINE_WORDS),
        .IC_BYPASS(IC_BYPASS), .IC_PREFETCH(IC_PREFETCH)
    ) u_ic (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .inst_data(inst_data),
        .imem_valid(imem_valid), .imem_hit(imem_hit),
        .fill_req_valid(fill_req_valid_w), .fill_req_addr(fill_req_addr_w),
        .fill_req_ready(fill_req_ready_w),
        .fill_rsp_valid(fill_rsp_valid_w), .fill_rsp_data(rd_resp_data),
        .fill_busy(unused_fill_busy_w)                // 仅观测量, 见上面 unused_fill_busy_w 的注释
    );

    // ==================== 4. 已提交 store 队列 ====================
    reg [SQ_DEPTH * 32 - 1 : 0] sq_addr_r, sq_data_r;
    reg [SQ_DEPTH * 2 - 1 : 0]  sq_width_r;
    reg [SQ_DEPTH - 1 : 0]      sq_b_ack_r;
    reg [SQ_DEPTH * 16 - 1 : 0] sq_ticket_r;          // 该条 B 到达时的"已发出 load 数"
    reg [SQ_IW - 1 : 0]         sq_wr_p, sq_snd_p, sq_ret_p;
    reg [15 : 0]                ld_issue_cnt_r, ld_done_cnt_r;

    wire [SQ_IW - 1 : 0] sq_occ_w   = sq_wr_p - sq_ret_p;
    wire sq_full_w  = ((sq_wr_p + 1'b1) == sq_ret_p);
    wire sq_empty_w = (sq_wr_p == sq_ret_p);
    assign sw_ready = !sq_full_w;
    // 队列成员 = [ret_p, wr_p); 按条目号给出 valid 位 (供合并函数遍历)
    wire [SQ_DEPTH - 1 : 0] sq_v_w;
    genvar j;
    generate
        for (j = 0; j < SQ_DEPTH; j = j + 1) begin : sqv
            assign sq_v_w[j] = (((j - sq_ret_p) & (SQ_DEPTH - 1)) < {1'b0, sq_occ_w});
        end
    endgenerate

    // 字节地址 pos 的最终值: 扫队列 (由老到新, 后者覆盖前者 ⇒ 最年轻胜) → AXI 原始字节
    // ★ 遍历必须按**年龄** (队首 + 年龄, 模 SQ_DEPTH), 不能按槽号 0..SQ_DEPTH-1: 三指针是自由跑的
    //   回绕计数器, 队列一旦绕过一圈, **低槽号反而是更年轻的条目** ⇒ 按槽号扫会让最老的 store 赢,
    //   与"后写覆盖先写"正好相反 (载入结果被改写成一个过期值 —— 静默算错)。
    //   触发要两个条件同时成立: ①队列已回绕 ②>=2 条存活条目覆盖同一字节。
    //   lat=1 时 B 很快回来, 队列长期只占用 0~1 条 ⇒ 两个条件都难成立, 掩盖了缺陷;
    //   lat>=2 队列开始驻留并回绕, 才被 qsort 那种"先大量 store 再读回"的模式压出来。
    //   对照 lsq.v 的 merge_byte_f: 它用 (j - hd) & mask 显式算年龄取最大, 是同一个道理。
    // 状态一律作为参数传入 (iverilog 连续赋值中的函数不建立对模块级信号的事件依赖, 见 lsq.v 同款注释)
    //
    // ★ 这里**只**合并"已提交进队列"的 store, 不含本拍正在提交的那条。本拍提交的 store 由上层
    //   lsq.v 的合并兜住: 该 store 此刻仍在 LSQ 里 (失效发生在 posedge), 且它必然比正在完成的那个
    //   load 老 (提交前提 rob_ready ⇒ 它的数据早到一拍, 而完成的 load 数据本拍才到) ⇒ 命中 lsq.v:257
    //   的 `(j - hd) < dd` 分支 (dd = 完成 load 距 head 的距离, 比 dd 小 = 更老)。
    //   把本拍提交并进来曾写成 `sv` 参数 (S4), 结果造出一条零延迟组合环, 实测 Verilator 报
    //   UNOPTFLAT: sw_valid → ld_m0 → lsq.mem_done_data → lsq.mb0 → execute_slot → misp_det
    //   → cpu_top.ce_w → sw_valid。环上两处都不可动 (ce_w 的 misp 项是防提交副作用重复的硬要求,
    //   见 cpu_top.v 第 4/5 节), 而这一项本就冗余 ⇒ 删掉, 环随之消失。
    function [7 : 0] sq_merge_byte_f;
        input [31 : 0]                pos;
        input [SQ_DEPTH * 32 - 1 : 0] q_a, q_d;
        input [SQ_DEPTH * 2 - 1 : 0]  q_w;
        input [SQ_DEPTH - 1 : 0]      q_v;
        input [SQ_IW - 1 : 0]         q_ret;        // 队首 (最老条目所在槽)
        input [7 : 0]                 raw;
        integer m;
        reg [SQ_IW - 1 : 0] s;
        reg [31 : 0] q_addr;
        reg [7 : 0]  val;
        begin
            val = raw;
            for (m = 0; m < SQ_DEPTH; m = m + 1) begin
                s = q_ret + m[SQ_IW - 1 : 0];      // 年龄 m ⇒ 槽号 (模 SQ_DEPTH, 截断即取模)
                q_addr = q_a[s * 32 +: 32];
                if (q_v[s] && (pos >= q_addr) && (pos < (q_addr + wd_bytes(q_w[s * 2 +: 2]))))
                    val = q_d[s * 32 + (pos - q_addr) * 8 +: 8];
            end
            sq_merge_byte_f = val;
        end
    endfunction

    // ★ 合并链的输入是 dl_* (命中数据或回包数据) —— 命中路径同样可能读到缓存里的旧值, 必须一起兜
    wire [7 : 0] ld_m0 = sq_merge_byte_f(dl_addr_w + 32'd0,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, dl_raw_w[7 : 0]);
    wire [7 : 0] ld_m1 = sq_merge_byte_f(dl_addr_w + 32'd1,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, dl_raw_w[15 : 8]);
    wire [7 : 0] ld_m2 = sq_merge_byte_f(dl_addr_w + 32'd2,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, dl_raw_w[23 : 16]);
    wire [7 : 0] ld_m3 = sq_merge_byte_f(dl_addr_w + 32'd3,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, dl_raw_w[31 : 24]);

    // 零扩展 (符号由 lsq.v:291-297 按 is_unsigned_r 做)
    assign ld_done_data = (dl_width_w == 2'b10) ? {ld_m3, ld_m2, ld_m1, ld_m0}
                        : (dl_width_w == 2'b01) ? {16'd0, ld_m1, ld_m0}
                        : {24'd0, ld_m0};

    // SQ 里"B 尚未落盘"(sq_b_ack_r==0) 的条目所占的**组号位图** —— 交给 dcache 判填充污染。
    // 只要该组有未落盘的 store, 填充读回的数据就可能混进旧值 ⇒ 本次填充作废 (见 dcache.v 第五条
    // 不变量)。只查"安装那一拍 SQ 里有没有"不够: store 可能在最后一字落地前就退休出队。
    // 组号切分必须与 dcache.v 一致 (见第 1 节 DC_SPLIT/DC_IW)。
    function [DC_SETS - 1 : 0] sq_blk_f;
        input [SQ_DEPTH * 32 - 1 : 0] q_a;
        input [SQ_DEPTH - 1 : 0]      q_v;
        input [SQ_DEPTH - 1 : 0]      q_ack;
        integer m;
        reg [DC_SETS - 1 : 0] blk;
        reg [DC_IW - 1 : 0]   st;
        begin
            blk = {DC_SETS{1'b0}};
            for (m = 0; m < SQ_DEPTH; m = m + 1) begin
                st = (DC_SETS < 2) ? {DC_IW{1'b0}} : q_a[m * 32 + DC_SPLIT +: DC_IW];
                if (q_v[m] && !q_ack[m]) blk[st] = 1'b1;
            end
            sq_blk_f = blk;
        end
    endfunction
    assign sq_blk_w = sq_blk_f(sq_addr_r, sq_v_w, sq_b_ack_r);

    // 提交入队 / 发上总线 / 退休 (三指针: wr 入队, snd 已发, ret 已可弃)
    wire sq_push = sw_valid && !sq_full_w;
    wire sq_send = (sq_snd_p != sq_wr_p);
    wire [1 : 0] sq_off_w = sq_addr_r[sq_snd_p * 32 +: 2];      // 字内字节偏移 = addr[1:0]
    wire [1 : 0] sq_w_w   = sq_width_r[sq_snd_p * 2 +: 2];
    // 地址对齐到字, 字节道靠 strb 选 (从机口径: wstrb 第 i 位 ↔ address+i, 字节取 wdata[8i+:8])
    assign wr_req_valid = sq_send;
    assign wr_req_addr  = {sq_addr_r[sq_snd_p * 32 + 2 +: 30], 2'b00};
    assign wr_req_data  = sq_data_r[sq_snd_p * 32 +: 32] << {sq_off_w, 3'b000};
    assign wr_req_strb  = wd_mask(sq_w_w) << sq_off_w;
    assign wr_req_tag   = sq_snd_p;
    wire sq_send_hs = wr_req_valid && wr_req_ready;
    wire sq_b_hs    = wr_resp_valid && wr_resp_ready;
    // 退休: B 已握手 且 该 B 到达时已发出的 load 都已回 (模 2^15 比较, 处理计数器回绕)
    wire [15 : 0] sq_tick_w = sq_ticket_r[sq_ret_p * 16 +: 16];
    wire sq_ret_ok = sq_b_ack_r[sq_ret_p] && ((ld_done_cnt_r - sq_tick_w) < 16'h8000);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_wr_p  <= {SQ_IW{1'b0}};
            sq_snd_p <= {SQ_IW{1'b0}};
            sq_ret_p <= {SQ_IW{1'b0}};
            sq_b_ack_r <= {SQ_DEPTH{1'b0}};
            ld_issue_cnt_r <= 16'd0;
            ld_done_cnt_r  <= 16'd0;
        end else begin
            if (sq_push)    sq_wr_p  <= sq_wr_p + 1'b1;
            if (sq_send_hs) sq_snd_p <= sq_snd_p + 1'b1;
            if (!sq_empty_w && sq_ret_ok) begin
                sq_ret_p <= sq_ret_p + 1'b1;
                sq_b_ack_r[sq_ret_p] <= 1'b0;
            end
            // B 按发送序回; wr_resp_tag 即该条目号
            if (sq_b_hs) begin
                sq_b_ack_r[wr_resp_tag] <= 1'b1;
                sq_ticket_r[wr_resp_tag * 16 +: 16] <= ld_issue_cnt_r;
            end
            if (ld_accept)    ld_issue_cnt_r <= ld_issue_cnt_r + 16'd1;
            // ★ 必须数 ld_done_valid (= 命中 ∪ 回包), 不是 ld_resp_hs: 命中不回 AXI, 只数回包
            //   会让计数器每命中一次就落后 1 ⇒ sq_ret_ok 的模 2^15 比较先"未到"后"提前到",
            //   表现为条目先滞留再被提前退休 (提前退休 = 合并兜底失效 = 静默算错)。
            if (ld_done_valid) ld_done_cnt_r  <= ld_done_cnt_r + 16'd1;
        end
    end
    always @(posedge clk) begin
        if (sq_push) begin
            sq_addr_r[sq_wr_p * 32 +: 32] <= sw_addr;
            sq_data_r[sq_wr_p * 32 +: 32] <= sw_data;
            sq_width_r[sq_wr_p * 2 +: 2]  <= sw_width;
        end
    end

    // ==================== 5. 读口仲裁 (需求 load > 取指填充 > 数据填充) ====================
    // 三个用户各一个 tag 码字; 优先级即下面的串行 "&& !更高优先者"。三者都是有限长度的事务
    // (load 一笔、填充 IC_LINE_WORDS / DC_LINE_WORDS 笔) ⇒ 低优先者不会被无限饿死。
    // ★ 让路口径 (旧式写法在这里是错的): `fill_req_ready = rd_req_ready && !ld_accept` 在
    //   有 D-cache 后会把两条填充都饿死 —— 命中流的 ld_accept 每拍为 1 却不占 AR 槽。正确的
    //   让路条件是"本拍真正的需求 AR 用户" = dc_ms_valid。
    wire demand_ar_w = dc_ms_valid;
    assign dc_ms_fire_w = dc_ms_valid && dc_ms_ready;

    assign rd_req_valid = demand_ar_w || fill_req_valid_w || dc_fill_valid;
    assign rd_req_addr  = demand_ar_w       ? {dc_ms_addr[31 : 2], 2'b00}
                        : fill_req_valid_w ? fill_req_addr_w
                        :                    dc_fill_addr;
    assign rd_req_tag   = demand_ar_w       ? TAG_LOAD
                        : fill_req_valid_w ? TAG_IFILL
                        :                    TAG_DFILL;

    assign dc_ms_ready      = rd_req_ready;                                  // 需求 load: 最高
    assign fill_req_ready_w = rd_req_ready && !demand_ar_w;                  // 取指填充: 次之
    assign dc_fill_ready    = rd_req_ready && !demand_ar_w && !fill_req_valid_w;   // D 填充: 最低
endmodule
