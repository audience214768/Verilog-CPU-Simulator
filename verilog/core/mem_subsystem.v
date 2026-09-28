// 存储子系统: 把 cpu_top 的存储接口 (与 core/memory.v:10-38 逐一对位) 接到 axi_lite_master
// 内部三块: load 适配 / 取指预取窗口 (ifetch) / 已提交 store 队列 (store_queue)
//
// 【为什么不能简单直连】fetch.v 的隐含契约是"地址 A 上总线, 下一拍 inst_data 就是 A 处指令"
// (memory.v 的同步读), 而 AXI 读要 ~12 拍。故必须有窗口: 回包按地址存下, 只在**地址对得上**的
// 那拍才交付 (imem_valid=1), 对不上/未回则 imem_valid=0, fetch 自会把请求停在期望批上等它
// (见 fetch.v 的 pc_next 末支与 imem_hit)。
// 地址比对用本模块自建的 imem_addr_q (imem_addr 延迟一拍, 复位值逐槽 4*g), 与 fetch.v:184-192 的
// imem_addr_d 逐槽一致 ⇒ 两者恒等, 交付时机与 fetch 完全同步。
//
// 【取指预取窗口】PF_DEPTH 字, 按 addr[2 +: PF_IW] 直接映射, 每格存完整地址 tag + 数据 + valid:
//   - 发起时写 tag 并清 valid, 回包时写 data 并置 valid ⇒ "valid ⟺ 本格数据属于本格 tag"。
//     (若发起时不清 valid, 旧数据会被新 tag 冒充 ⇒ 假命中 —— 本模块最容易写错的一处)
//   - 预取流 pf_next_r 只朝前走, 超前 demand 不超过 PF_WIN 字; 而某格被流覆盖要等流再走
//     PF_DEPTH 字 ⇒ 只要 PF_WIN < PF_DEPTH, demand 需要的那格就不会被预取流自己冲掉。
//   - demand 未命中: 该地址不在飞则把流拉回 demand (别继续取没用的), 在飞则原地等 (防重复发)。
//   - demand 命中时流到窗口上界即停 ⇒ 不占总线, 那 1 字/拍让给 load (带宽区分点)。
//   - 反向后跳会让超前量超出一个缓冲区跨度 (pf_stale_w) ⇒ 同样拉回流, 顺带排除覆盖风险。
//   - 流前方已有本地址数据时只推进流不重发 (pf_dup_w): 既省带宽, 也避免"重发先把自己置无效"。
//   - ★ 本格有回包在飞时不得重发 (pf_pend_w): 回包只带下标不带地址, 重发等于让 A 的数据冒充 B。
//   - PF_WIN 是取指/load 的带宽分配旋钮: 窗口越大越能藏跳转延迟, 但重定向时在途的废请求
//     (最多 PF_WIN 个) 会挡在新地址前面, 每个多花 1 拍 ⇒ 消融时扫它。
//
// 【load 通路】ld_busy==0 是**必须当场兑现**的硬承诺 (lsq.v:158 组合自 !ld_busy, 且收到即置 issued;
//   反悔 ⇒ 该条目永久在飞 ⇒ head 卡死): 故 ld_busy 只由"在飞数 + 读口是否有空位"组合决定, 且 load
//   在发请求时**优先于**取指预取。每个被接受的 load **恰好**回一个 ld_done_valid (回包与请求一一对应,
//   且 rresp 不参与门控 —— LSQ 没有错误口, 少一个脉冲就是死锁)。
//   子字抽取: araddr 强制 4 字节对齐, 回包右移 8*addr[1:0] 后**零扩展** (符号扩展由 lsq.v:291-297 做)。
//   ⚠ 由此不支持跨 4 字节边界的非对齐访问 (memory.v 的平铺字节数组支持); 编译产出的 C 代码不会产生。
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
//
// 复位异步低有效 (与 axi_lite_master 一致; ASAP7 标准单元库只有异步复位触发器)
module mem_subsystem #(
    parameter ISSUE_WIDTH = 1,
    parameter LSQ_SIZE    = 16,
    parameter PF_DEPTH    = 16,      // 取指预取窗口字数 (2 的幂; 须 > PF_WIN)
    parameter PF_WIN      = 8,       // 预取流超前 demand 的字数上限
    parameter LD_INFLIGHT = 8,       // 在飞 load 上限
    parameter SQ_DEPTH    = 8,       // 已提交未可见 store 队列深度
    parameter RD_DEPTH    = 8,       // AXI 读事务 FIFO 深度
    parameter WR_DEPTH    = 8        // AXI 写事务 FIFO 深度
) (
    input  clk,
    input  rst_n,

    // ---- CPU 侧: 取指 (同步读语义: inst_data 对应上一拍的 imem_addr) ----
    output [ISSUE_WIDTH * 32 - 1 : 0] inst_data,
    input  [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    output                            imem_valid,   // 本拍 inst_data 确实是对应地址上的指令
    output                            imem_hit,     // 本拍 imem_addr 上的数据已在窗口里 (供 fetch 判能否预先发下一批请求)

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
    localparam PF_IW = $clog2(PF_DEPTH);
    localparam LD_IW = $clog2(LD_INFLIGHT);
    localparam LIW   = $clog2(LSQ_SIZE);
    localparam SQ_IW = $clog2(SQ_DEPTH);
    localparam TW    = 1 + PF_IW;                 // AXI 读 tag: 最高位 1=load, 0=取指 (低 PF_IW 位为下标)

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
    // 槽 g 的 imem_addr 复位值 = 4*g, 与 fetch.v:190 逐槽一致
    function [ISSUE_WIDTH * 32 - 1 : 0] slot_init_f;
        input dummy;                                  // 占位: iverilog 要求函数至少一个入参
        integer g;
        begin
            slot_init_f = {ISSUE_WIDTH * 32{1'b0}};
            for (g = 0; g < ISSUE_WIDTH; g = g + 1)
                slot_init_f[g * 32 +: 32] = g * 4;
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

    // ==================== 2. load 通路 ====================
    reg [LD_INFLIGHT * 32 - 1 : 0]  ld_addr_r;
    reg [LD_INFLIGHT * 2 - 1 : 0]   ld_width_r;
    reg [LD_INFLIGHT * LIW - 1 : 0] ld_idx_r;
    // 指针位宽 = LD_IW+1 (不是 LD_IW): 在飞数要能表示到 LD_INFLIGHT **本身**, 而 LD_IW 位的差
    // 是 mod LD_INFLIGHT 的 (N 与 0 同码) ⇒ "在飞 == N" 永不成立, 满判据失效, 第 N+1 条会覆盖
    // 第 1 条的槽位 (地址/idx 错位 ⇒ 完成脉冲带错 idx, LSQ 等一个永远不来的 ld_done ⇒ 挂死)。
    // 默认 8 时被 AXI 读深度 RD_DEPTH=8 掩盖, LD_INFLIGHT=2 时暴露。数组下标取低位 LD_IW 位。
    reg [LD_IW : 0]                 ld_wr_p, ld_rd_p;

    wire [LD_IW : 0] ld_inflight_w = ld_wr_p - ld_rd_p;
    // ★ 硬承诺: 有在飞余量**且**读口有空位才说不忙; 且 load 在发请求上优先于取指预取
    wire ld_accept = ld_start_valid && !ld_busy;
    assign ld_busy = (ld_inflight_w >= LD_INFLIGHT) || !rd_req_ready;
    wire ld_resp_hs = rd_resp_valid && rd_resp_tag[TW - 1];   // tag 最高位 1 = load (见第 5 节)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_wr_p <= {(LD_IW + 1){1'b0}};
            ld_rd_p <= {(LD_IW + 1){1'b0}};
        end else begin
            if (ld_accept)  ld_wr_p <= ld_wr_p + 1'b1;
            if (ld_resp_hs) ld_rd_p <= ld_rd_p + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (ld_accept) begin
            ld_addr_r[ld_wr_p[LD_IW - 1 : 0] * 32 +: 32]  <= ld_start_addr;
            ld_width_r[ld_wr_p[LD_IW - 1 : 0] * 2 +: 2]   <= ld_start_width;
            ld_idx_r[ld_wr_p[LD_IW - 1 : 0] * LIW +: LIW] <= ld_start_idx;
        end
    end

    // 回包与请求同序 (AXI 保证按 AR 序) ⇒ 读指针所指即本条
    wire [31 : 0]      ld_a_w   = ld_addr_r[ld_rd_p[LD_IW - 1 : 0] * 32 +: 32];
    wire [1 : 0]       ld_w_w   = ld_width_r[ld_rd_p[LD_IW - 1 : 0] * 2 +: 2];
    wire [LIW - 1 : 0] ld_i_w   = ld_idx_r[ld_rd_p[LD_IW - 1 : 0] * LIW +: LIW];
    wire [31 : 0]      ld_raw_w = rd_resp_data >> {ld_a_w[1 : 0], 3'b000};   // 对齐字 → 该地址起的字节

    assign ld_done_valid = ld_resp_hs;
    assign ld_done_idx   = ld_i_w;

    // ==================== 3. 取指预取窗口 ====================
    // **逐槽**延迟一拍 (≡ fetch.v:54 的 imem_addr_d, 同宽同复位值): 交付逻辑按槽取地址
    // imem_addr_q[g*32 +: 32], 只声明 32 位时 g>=1 会越界 —— Verilator 报 SELRANGE 并退化成
    // 槽 0 的值 ⇒ 槽 1 复用槽 0 的窗口项, 把错指令当"命中"交付 (slot_hit 仍为全 1, CPU 无从察觉)。
    // 实测 W=2: 取指在 pc=0x34/0x3C 之间每拍振荡, commit 数远超程序动态指令数, 永不触发停机 store。
    // 复位那行本来就按 slot_init_f 的**全宽**值写 (逐槽 4*g), 只是声明窄了被截断 —— W=1 只需槽 0。
    reg [ISSUE_WIDTH * 32 - 1 : 0] imem_addr_q;         // ≡ fetch.v 的 imem_addr_d
    reg [PF_DEPTH * 32 - 1 : 0] pf_tag_r;               // 发起时写: 该格正在取的地址
    reg [PF_DEPTH * 32 - 1 : 0] pf_data_r;              // 回包时写
    reg [PF_DEPTH - 1 : 0]      pf_valid_r;
    reg [PF_DEPTH - 1 : 0]      pf_pend_r;              // 在飞 (发起置位, 回包清)
    reg [31 : 0]                pf_next_r;              // 预取流: 下一个要取的地址

    // ---- 窗口读口: **one-hot + AND-OR** (原为 `pf_xxx_r[idx * W +: W]`) ----
    // 索引读综合出 PF_DEPTH 选 1 的 mux 树, 索引**最低位落在最宽的一级**:
    // 扇出 = (PF_DEPTH/2) × (1 + 1 + 32 + 32) = 8 × 66 = 528。而 demand 走的是 imem_addr_q,
    // 它同时喂 4 处读口, 实测峰值 797 —— 即容器报告里 13.24 ns 路径上最大的一级
    // _148978_ (AND2x2, 797 扇出, **907 ps**)。
    // 改成: 先把 4 个字段按格**重排**成 pf_ent[gp][PFW] (纯连线), 再把索引译成 one-hot
    // 后逐位 AND-OR ⇒ 每条 one-hot 只驱动 PFW 个 AND, 峰值扇出 528/797 → 66。
    // 索引最低位在 mux 树里落在最宽一级; 在 one-hot 里只驱动译码器 ⇒ 深度 15 级 → ~8 级。
    localparam PFW = 1 + 1 + 32 + 32;       // valid + pend + tag + data
    localparam PO_V = 0;                    // : 1
    localparam PO_P = PO_V + 1;             // : 1
    localparam PO_T = PO_P + 1;             // : 32
    localparam PO_D = PO_T + 32;            // : 32
    wire [PF_DEPTH * PFW - 1 : 0] pf_ent;
    genvar gp, gb;
    generate
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : pfpack
            assign pf_ent[gp * PFW +: PFW] = {
                pf_data_r[gp * 32 +: 32], pf_tag_r[gp * 32 +: 32],
                pf_pend_r[gp], pf_valid_r[gp] };
        end
    endgenerate

    wire [31 : 0]        demand_a  = imem_addr_q[0 * 32 +: 32];   // 只对槽 0 做流控 (批内其它槽随后即到)
    wire [PF_IW - 1 : 0] dem_idx   = demand_a[2 +: PF_IW];
    // 读口 A: 按 demand (即 imem_addr_q 的槽 0) 取
    wire [PF_DEPTH - 1 : 0] oh_dem;
    wire [PFW - 1 : 0]      sel_dem;
    generate
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : ohd
            assign oh_dem[gp] = (dem_idx == gp[PF_IW - 1 : 0]);
        end
        for (gb = 0; gb < PFW; gb = gb + 1) begin : redd
            wire [PF_DEPTH - 1 : 0] m;
            for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : e
                assign m[gp] = pf_ent[gp * PFW + gb] & oh_dem[gp];
            end
            assign sel_dem[gb] = |m;
        end
    endgenerate
    wire              dem_valid = sel_dem[PO_V];
    wire [31 : 0]     dem_tag   = sel_dem[PO_T +: 32];
    wire dem_hit  = dem_valid && (dem_tag == demand_a);
    wire dem_pend = sel_dem[PO_P] && (dem_tag == demand_a);   // 同址在飞
    wire [31 : 0] pf_ahead_w = pf_next_r - demand_a;     // 无符号减: 流若落后会得到大数 ⇒ 自然不满足上界
    wire pf_stale_w = (pf_ahead_w >= (PF_DEPTH * 4));    // 流跑到缓冲区跨度外 (含"落后于 demand"的绕回)
    // 拉回流: 未命中且不在飞, 或流已跑到缓冲区跨度外 (后者让"向后跳"后能重新填窗, 也排除覆盖风险)
    // ★ 2026-09-28 留档 (勿直接重做): 本处流控曾改写为 "pf_addr_w = pf_out_w ? demand_a : pf_next_r"
    //   (就地取 demand 而不拉回指针), 并把命中判定改成"逐槽全中" —— 两版**都回归**: W=2 官方
    //   add_to_100 由 PASS(462 拍) 变成 1e8 拍不终止 (array_test1 同步失守, 819 拍 → 超时)。
    //   下面是本轮在**修复版构建**上实测到的真死带 (array_test2, W=2, LATENCY=10):
    //   稳定停在 pf_next_r=0xE4 / demand_a=0xBC ⇒ pf_ahead_w=0x28=40 ∈ [PF_WIN*4=32, PF_DEPTH*4=64)
    //   —— 既 ≥ 上界不发、又 < 下界不拉回 ⇒ 流冻结, 期望批 {0xBC,0xC0} 永不凑齐
    //   (pc_r 在 0xBC/0xC4 每拍翻转, 1396 次/1500 拍; exp_pc_r 自 t=457 冻结在 0xBC)。
    //   死带是真的, 但改法必须**连同 demand 锚点一起改** —— "槽 0 口径"与"批口径"混用才是病根
    //   (demand_a 只锚槽 0, 而 imem_valid/cap_w 要求整批到齐)。片段与证据见 docs/plan.md §15.10.17 §三。
    wire pf_restart = !dem_pend && (pf_next_r != demand_a) && (!dem_hit || pf_stale_w);
    wire [PF_IW - 1 : 0] pf_idx_w = pf_next_r[2 +: PF_IW];
    // 读口 B: 按预取流指针 pf_next_r 取
    wire [PF_DEPTH - 1 : 0] oh_str;
    wire [PFW - 1 : 0]      sel_str;
    generate
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : ohs
            assign oh_str[gp] = (pf_idx_w == gp[PF_IW - 1 : 0]);
        end
        for (gb = 0; gb < PFW; gb = gb + 1) begin : reds
            wire [PF_DEPTH - 1 : 0] m;
            for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : e
                assign m[gp] = pf_ent[gp * PFW + gb] & oh_str[gp];
            end
            assign sel_str[gb] = |m;
        end
    endgenerate
    // 流前方已是本地址的数据 (反向后跳回到命中行时常见) ⇒ 直接跨过去, 不重发 (重发会先把自己置无效)
    wire pf_dup_w = sel_str[PO_V] && (sel_str[PO_T +: 32] == pf_next_r);
    // 本格还有回包在飞时**绝不能**重发: 回包只带下标、不带地址, 重发会让"A 的回包"落进
    // 已被改写成 B 的格 ⇒ tag 说 B、数据却是 A (实测到过: 停车位 0x700 的数据被判给 0x440,
    // 二者同落格 0)。等回包回来再发, 只损失一趟往返, 不错绑。
    wire pf_pend_w = sel_str[PO_P];
    wire pf_issue = !pf_restart && !pf_dup_w && !pf_pend_w && (pf_ahead_w < (PF_WIN * 4));
    wire pf_hs = pf_issue && !ld_accept && rd_req_ready;   // 本拍真正被收下的取指请求

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_addr_q <= slot_init_f(1'b0);
            pf_next_r   <= 32'd0;
            pf_valid_r  <= {PF_DEPTH{1'b0}};
            pf_pend_r   <= {PF_DEPTH{1'b0}};
        end else begin
            imem_addr_q <= imem_addr;
            if (pf_restart)     pf_next_r <= demand_a;
            else if (pf_hs)     pf_next_r <= pf_next_r + 32'd4;
            else if (pf_dup_w)  pf_next_r <= pf_next_r + 32'd4;   // 已有 ⇒ 只推进流, 不占总线
            // 发起: 写 tag + 清 valid + 置在飞 (清 valid 是必须的, 见头注释)
            if (pf_hs) begin
                pf_tag_r[pf_idx_w * 32 +: 32] <= pf_next_r;
                pf_valid_r[pf_idx_w] <= 1'b0;
                pf_pend_r[pf_idx_w]  <= 1'b1;
            end
            // 回包: 请求与回包一一对应且同序, 直接按 tag 下标落格
            if (rd_resp_valid && !rd_resp_tag[TW - 1]) begin
                pf_data_r[rd_resp_tag[PF_IW - 1 : 0] * 32 +: 32] <= rd_resp_data;
                pf_valid_r[rd_resp_tag[PF_IW - 1 : 0]] <= 1'b1;
                pf_pend_r[rd_resp_tag[PF_IW - 1 : 0]]  <= 1'b0;
            end
        end
    end

    // 交付: 每槽独立比对 (全中才算本拍数据可信)
    wire [ISSUE_WIDTH - 1 : 0] slot_hit;
    genvar g;
    generate
        for (g = 0; g < ISSUE_WIDTH; g = g + 1) begin : idat
            wire [31 : 0]        a_g = imem_addr_q[g * 32 +: 32];
            wire [PF_IW - 1 : 0] i_g = a_g[2 +: PF_IW];
            // 读口 A': 按槽 g 的地址取 (g=0 时 i_g 与 dem_idx 是同一表达式, 译码器被 CSE 合并)
            wire [PF_DEPTH - 1 : 0] oh_g;
            wire [PFW - 1 : 0]      sel_g;
            for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : ohg
                assign oh_g[gp] = (i_g == gp[PF_IW - 1 : 0]);
            end
            for (gb = 0; gb < PFW; gb = gb + 1) begin : redg
                wire [PF_DEPTH - 1 : 0] m;
                for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : e
                    assign m[gp] = pf_ent[gp * PFW + gb] & oh_g[gp];
                end
                assign sel_g[gb] = |m;
            end
            assign slot_hit[g] = sel_g[PO_V] && (sel_g[PO_T +: 32] == a_g);
            assign inst_data[g * 32 +: 32] = sel_g[PO_D +: 32];
        end
    endgenerate
    assign imem_valid = &slot_hit;
    // 本拍 imem_addr 的命中: 与上面同款比对, 但用**当前**请求地址 (非延迟一拍的 imem_addr_q)。
    //   fetch 用它判断"能否把请求预先推到下一批" —— 只有期望批已在窗口里才允许超前,
    //   否则请求地址会随数据未回而乱翻, 预取流再也填不满 (见 fetch.v 的 pc_lead_w 注释)。
    //   这里比的是批的首字 (槽 0), 与预取流控用的 demand 同一口径。
    // 读口 C: 按本拍 imem_addr 取 (非延迟一拍 ⇒ 与读口 A 不是同一个索引, 不能合用)
    wire [PF_IW - 1 : 0]     cur_idx = imem_addr[2 +: PF_IW];
    wire [PF_DEPTH - 1 : 0]  oh_cur;
    wire [PFW - 1 : 0]       sel_cur;
    generate
        for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : ohc
            assign oh_cur[gp] = (cur_idx == gp[PF_IW - 1 : 0]);
        end
        for (gb = 0; gb < PFW; gb = gb + 1) begin : redc
            wire [PF_DEPTH - 1 : 0] m;
            for (gp = 0; gp < PF_DEPTH; gp = gp + 1) begin : e
                assign m[gp] = pf_ent[gp * PFW + gb] & oh_cur[gp];
            end
            assign sel_cur[gb] = |m;
        end
    endgenerate
    assign imem_hit = sel_cur[PO_V] && (sel_cur[PO_T +: 32] == imem_addr[0 * 32 +: 32]);

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

    wire [7 : 0] ld_m0 = sq_merge_byte_f(ld_a_w + 32'd0,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, ld_raw_w[7 : 0]);
    wire [7 : 0] ld_m1 = sq_merge_byte_f(ld_a_w + 32'd1,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, ld_raw_w[15 : 8]);
    wire [7 : 0] ld_m2 = sq_merge_byte_f(ld_a_w + 32'd2,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, ld_raw_w[23 : 16]);
    wire [7 : 0] ld_m3 = sq_merge_byte_f(ld_a_w + 32'd3,
                                         sq_addr_r, sq_data_r, sq_width_r, sq_v_w, sq_ret_p, ld_raw_w[31 : 24]);

    // 零扩展 (符号由 lsq.v:291-297 按 is_unsigned_r 做)
    assign ld_done_data = (ld_w_w == 2'b10) ? {ld_m3, ld_m2, ld_m1, ld_m0}
                        : (ld_w_w == 2'b01) ? {16'd0, ld_m1, ld_m0}
                        : {24'd0, ld_m0};

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
            if (ld_accept)  ld_issue_cnt_r <= ld_issue_cnt_r + 16'd1;
            if (ld_resp_hs) ld_done_cnt_r  <= ld_done_cnt_r + 16'd1;
        end
    end
    always @(posedge clk) begin
        if (sq_push) begin
            sq_addr_r[sq_wr_p * 32 +: 32] <= sw_addr;
            sq_data_r[sq_wr_p * 32 +: 32] <= sw_data;
            sq_width_r[sq_wr_p * 2 +: 2]  <= sw_width;
        end
    end

    // ==================== 5. 读口仲裁 (load 优先) ====================
    assign rd_req_valid = ld_accept || pf_issue;
    assign rd_req_addr  = ld_accept ? {ld_start_addr[31 : 2], 2'b00} : pf_next_r;
    assign rd_req_tag   = ld_accept ? {1'b1, {PF_IW{1'b0}}} : {1'b0, pf_idx_w};
endmodule
