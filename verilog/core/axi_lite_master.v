// AXI4-Lite 主机 (纯协议层): 只把 CPU 侧的读/写事务搬上总线, 不含任何存储语义
//   (地址是否对齐/是否越界/是否 MMIO 一律不判断, 全由从机裁决)
//
// 读: 一条事务 FIFO + 四指针, 推进序 rd_wr_p → rd_ar_p → rd_r_p → rd_rd_p
//     数值上 rd_rd_p ≤ rd_r_p ≤ rd_ar_p ≤ rd_wr_p (模 2^RD_PW):
//       [rd_rd_p, rd_r_p) 数据已回, 等 CPU 取走 (rd_resp_*)
//       [rd_r_p,  rd_ar_p) AR 已发, 等 R
//       [rd_ar_p, rd_wr_p) 已收请求, 未发 AR
//     araddr 取自 FIFO 条目, 而条目只在握手拍才动 ⇒ VALID 稳定性天然成立 (结构上不可能组合依赖 ready)
// 写: 同样四指针, 推进序 wr_wr_p → wr_is_p → wr_b_p → wr_rd_p
//     AW 与 W 由**同一条目**在**同一拍**驱动 (只差各自的完成位), 且两拍都握手才推进 is_p
//     ⇒ AW 序 == W 序 == 提交序, 满足从机"按位置配对 aw.front()/w.front()"的要求
//     AW/W 的完成位是**全局**两个触发器 (同一时刻只有一条目在发), 不必每条目各存一份
//
// 关键约束 (违反任一条都会静默挂死):
//   * rready / bready 恒 1: 响应永远当场收下, 不给从机背压。若不驱动 bready,
//     停机 store 的 B 永不握手 ⇒ 从机 done 永假 ⇒ 所有用例超时 (且看着像 CPU 算错)
//   * 输出 (arvalid/awvalid/wvalid) 只由本模块寄存器决定, 与任何 ready 输入无关 (AXI 硬规则)
//   * 每个被收下的请求**恰好**在 FIFO 里占一条目, 响应也**恰好**回到该条目 (无 ID, 全靠顺序)
// 复位异步低有效 (ASAP7 标准单元库只有异步复位触发器; 同步复位要额外长复位 mux)
//
// 面积提示: 读条目 70 bit × RD_DEPTH, 写条目 74 bit × WR_DEPTH, 是本模块的主要寄存器开销,
//           两个深度都是参数 (见下), 面积敏感时先调它们
module axi_lite_master #(
    parameter RD_DEPTH = 16,      // 读事务在途上限 (须 < 从机 AR FIFO 深度, 免溢出)
    parameter WR_DEPTH = 8,       // 写事务在途上限 (须 < 从机 AW/W FIFO 深度)
    parameter RD_TW    = 4,       // 读 tag 位宽 (由调用方决定, 原样回传)
    parameter WR_TW    = 3        // 写 tag 位宽
) (
    input  clk,
    input  rst_n,

    // ---- CPU 侧读请求: valid/ready 握手, tag 随响应回传 ----
    input                      rd_req_valid,
    output                     rd_req_ready,
    input  [31 : 0]            rd_req_addr,
    input  [RD_TW - 1 : 0]     rd_req_tag,
    // ---- CPU 侧读响应: 按 AR 序交付, 与请求一一对应 ----
    output                     rd_resp_valid,
    input                      rd_resp_ready,
    output [31 : 0]            rd_resp_data,
    output [1 : 0]             rd_resp_resp,
    output [RD_TW - 1 : 0]     rd_resp_tag,

    // ---- CPU 侧写请求: 地址/数据/选通一次给出 (二者会同拍上总线) ----
    input                      wr_req_valid,
    output                     wr_req_ready,
    input  [31 : 0]            wr_req_addr,
    input  [31 : 0]            wr_req_data,
    input  [3 : 0]             wr_req_strb,
    input  [WR_TW - 1 : 0]     wr_req_tag,
    // ---- CPU 侧写响应 (B) ----
    output                     wr_resp_valid,
    input                      wr_resp_ready,
    output [1 : 0]             wr_resp_resp,
    output [WR_TW - 1 : 0]     wr_resp_tag,

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
    localparam RD_PW = $clog2(RD_DEPTH);
    localparam WR_PW = $clog2(WR_DEPTH);

    // ---- 读事务 FIFO: 每字段一条平铺向量 (与 rob/rs/lsq 同风格) ----
    reg [RD_DEPTH * 32 - 1 : 0]    rd_addr_r;
    reg [RD_DEPTH * RD_TW - 1 : 0] rd_tag_r;
    reg [RD_DEPTH * 32 - 1 : 0]    rd_data_r;
    reg [RD_DEPTH * 2 - 1 : 0]     rd_bresp_r;
    reg [RD_PW - 1 : 0]            rd_wr_p, rd_ar_p, rd_r_p, rd_rd_p;

    wire rd_full_w  = ((rd_wr_p + 1'b1) == rd_rd_p);          // 留一格区分空满

    // 每个被收下的请求占一条目, 直到其响应被 CPU 取走
    assign rd_req_ready   = !rd_full_w;
    assign rd_resp_valid  = (rd_rd_p != rd_r_p);
    assign rd_resp_data   = rd_data_r[rd_rd_p * 32 +: 32];
    assign rd_resp_resp   = rd_bresp_r[rd_rd_p * 2 +: 2];
    assign rd_resp_tag    = rd_tag_r[rd_rd_p * RD_TW +: RD_TW];

    // ---- 读通道: AR 只从 rd_ar_p 条目发 (VALID 稳定), R 只往 rd_r_p 条目收 ----
    assign araddr  = rd_addr_r[rd_ar_p * 32 +: 32];
    assign arvalid = (rd_ar_p != rd_wr_p);
    assign rready  = 1'b1;                                     // 恒收, 见头注释

    wire rd_req_hs = rd_req_valid && rd_req_ready;
    wire rd_ar_hs  = arvalid && arready;
    wire rd_r_hs   = rvalid;                                   // rready 恒 1
    wire rd_resp_hs = rd_resp_valid && rd_resp_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_wr_p <= {RD_PW{1'b0}};
            rd_ar_p <= {RD_PW{1'b0}};
            rd_r_p  <= {RD_PW{1'b0}};
            rd_rd_p <= {RD_PW{1'b0}};
        end else begin
            if (rd_req_hs) rd_wr_p <= rd_wr_p + 1'b1;
            if (rd_ar_hs)  rd_ar_p <= rd_ar_p + 1'b1;
            if (rd_r_hs)   rd_r_p  <= rd_r_p + 1'b1;
            if (rd_resp_hs) rd_rd_p <= rd_rd_p + 1'b1;
        end
    end

    // 请求字段入队 (与指针同拍写; 指针只在握手拍动, 故写位置必为空闲格)
    always @(posedge clk) begin
        if (rd_req_hs) begin
            rd_addr_r[rd_wr_p * 32 +: 32]    <= rd_req_addr;
            rd_tag_r[rd_wr_p * RD_TW +: RD_TW] <= rd_req_tag;
        end
        // R 响应落到"最早发出且未收到"的那一条 (无 ID, 从机保证按 AR 序返回)
        if (rd_r_hs) begin
            rd_data_r[rd_r_p * 32 +: 32]  <= rdata;
            rd_bresp_r[rd_r_p * 2 +: 2]   <= rresp;
        end
    end

    // ---- 写事务 FIFO ----
    reg [WR_DEPTH * 32 - 1 : 0]    wr_addr_r;
    reg [WR_DEPTH * 32 - 1 : 0]    wr_data_r;
    reg [WR_DEPTH * 4 - 1 : 0]     wr_strb_r;
    reg [WR_DEPTH * WR_TW - 1 : 0] wr_tag_r;
    reg [WR_DEPTH * 2 - 1 : 0]     wr_bresp_r;
    reg [WR_PW - 1 : 0]            wr_wr_p, wr_is_p, wr_b_p, wr_rd_p;
    // 当前发射条目的 AW/W 完成位 (全局: 同一时刻只有一条目在发)
    reg aw_done_r, w_done_r;

    wire wr_full_w = ((wr_wr_p + 1'b1) == wr_rd_p);
    wire wr_issue_any = (wr_is_p != wr_wr_p);

    assign wr_req_ready  = !wr_full_w;
    assign wr_resp_valid = (wr_rd_p != wr_b_p);
    assign wr_resp_resp  = wr_bresp_r[wr_rd_p * 2 +: 2];
    assign wr_resp_tag   = wr_tag_r[wr_rd_p * WR_TW +: WR_TW];

    // AW 与 W 同拍、同条目驱动 ⇒ 两通道顺序恒等 (从机按位置配对)
    assign awaddr  = wr_addr_r[wr_is_p * 32 +: 32];
    assign awvalid = wr_issue_any && !aw_done_r;
    assign wdata   = wr_data_r[wr_is_p * 32 +: 32];
    assign wstrb   = wr_strb_r[wr_is_p * 4 +: 4];
    assign wvalid  = wr_issue_any && !w_done_r;
    assign bready  = 1'b1;                                     // 恒收, 见头注释

    wire wr_req_hs = wr_req_valid && wr_req_ready;
    wire wr_aw_hs  = awvalid && awready;
    wire wr_w_hs   = wvalid && wready;
    wire wr_b_hs   = bvalid;                                   // bready 恒 1
    wire wr_resp_hs = wr_resp_valid && wr_resp_ready;
    // 本条目的 AW 与 W 都已完成 (本拍握手或此前已完成) → 发射指针前进
    wire wr_issue_done = wr_issue_any && (aw_done_r || wr_aw_hs) && (w_done_r || wr_w_hs);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_wr_p <= {WR_PW{1'b0}};
            wr_is_p <= {WR_PW{1'b0}};
            wr_b_p  <= {WR_PW{1'b0}};
            wr_rd_p <= {WR_PW{1'b0}};
            aw_done_r <= 1'b0;
            w_done_r  <= 1'b0;
        end else begin
            if (wr_req_hs) wr_wr_p <= wr_wr_p + 1'b1;
            if (wr_issue_done) wr_is_p <= wr_is_p + 1'b1;
            if (wr_b_hs)   wr_b_p  <= wr_b_p + 1'b1;
            if (wr_resp_hs) wr_rd_p <= wr_rd_p + 1'b1;
            // 完成位: 本条发完即清零 (给下一条目用), 否则按本拍握手置位
            if (wr_issue_done) begin
                aw_done_r <= 1'b0;
                w_done_r  <= 1'b0;
            end else begin
                if (wr_aw_hs) aw_done_r <= 1'b1;
                if (wr_w_hs)  w_done_r  <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (wr_req_hs) begin
            wr_addr_r[wr_wr_p * 32 +: 32]      <= wr_req_addr;
            wr_data_r[wr_wr_p * 32 +: 32]      <= wr_req_data;
            wr_strb_r[wr_wr_p * 4 +: 4]        <= wr_req_strb;
            wr_tag_r[wr_wr_p * WR_TW +: WR_TW] <= wr_req_tag;
        end
        // B 落到"最早发出且未应答"的那一条 (无 ID, 从机保证按 AW 序返回)
        if (wr_b_hs) wr_bresp_r[wr_b_p * 2 +: 2] <= bresp;
    end
endmodule
