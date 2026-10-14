// 官方顶层 student_top: 19 个 AXI4-Lite 端口, 端口名/位宽照抄 docs/description.md:194-226 的模板
//   clock / reset (高有效, 初始化保持 5 拍) / AR / R / AW / W / B, 无 PROT
// 结构: cpu_top (乱序流水线) + mem_subsystem (L1 指令缓存 / load 适配 / 已提交 store 队列)
//   cpu_top 的存储接口原样接到 mem_subsystem, 后者是唯一的 AXI 主机
// 停机: 程序向 MMIO 0x80000000 做一次 32 位 store ⇒ cpu_top 内 mmio_exit 拉起 halt;
//   退出值由官方从机在 B 握手时从 WDATA 取 (sim.cpp:119-121), 故本模块不引出 ret_val。
//   手写程序用的 TERM marker 判定保留 (OR 并存), 两条路径互不干扰。
// 复位: 外部 reset 高有效 ⇒ 内部 rst_n = ~reset (异步低有效, 与 ASAP7 触发器一致)
// 基准参数 = **基线 C** (2026-10-15 落地; 参数取自参数阶梯 t3q 的 q2 点 + 三把刀全部短路, 见 plan.md §1.1):
//   geo IPC **0.7739** (官方 make perf, 19/19 门禁通过, 2026-10-15); 逐程序 median 0.7084 / multiply 1.1184 /
//   qsort 0.6481 / rsort 0.7856 / towers 0.5992 / vvadd 0.8888
//   面积/频率 **从未综合**: C 比唯一有综合数的 cutAA (10395.630 µm² / 412.24 MHz, 新尺) 结构全面更大,
//   且三把刀短路方向对 fmax 是**负**的 ⇒ 阶段归属未定, 须综合复核 (plan.md §2 T0)
//   三把刀 = load 交付链上三级流水寄存器改组合直连: 刀 R (`mem_subsystem.v` 的 `dl_*_r`) /
//   刀 D/Q (`cpu_top.v` 的 `ld_done_*_q`) / 刀 A (`cpu_top.v` 的 load CDB 组); 合计 +13.9% IPC
//   短路后各级必须保持的不变式写在两处 RTL 头注释里 —— **再插同类寄存器前先读那里**
module student_top #(
    parameter ISSUE_WIDTH = 2,
    parameter ROB_SIZE    = 32,
    parameter RS_SIZE     = 8,
    parameter PRF_SIZE    = 64,
    parameter LSQ_SIZE    = 16,
    parameter BHT_SIZE    = 32,
    parameter RAS_SIZE     = 8,
    parameter ROLLBACK_WIDTH = 4,    // 回滚 walker 每拍撤销的条目数 (与 ISSUE_WIDTH 解耦)
    parameter IC_SIZE       = 512,   // I-cache 总容量 (字节)
    parameter IC_LINE_WORDS = 8,     // I-cache 行字数 (2 的幂; 须 ≥ ISSUE_WIDTH)
    parameter IC_BYPASS     = 0,     // 1 = 交付一次即失效 ⇒ 每次访问都 miss (缺陷归因对照)
    parameter IC_PREFETCH   = 1,     // 1 = 顺需求行预取下一行
    parameter DC_SIZE       = 4096,  // D-cache 总容量 (字节; 0 = 旁路)
    parameter DC_LINE_WORDS = 16,    // D-cache 行字数 (2 的幂)
    parameter DC_WAYS       = 2,     // D-cache 相联度 (2 路: SRAM 面积不变, geo IPC +2.2%, 见 plan.md §十六)
    parameter DC_PREFETCH   = 2,     // D-cache 下一行预取: 0=关 1=需求缺失起填那拍预取下一行 2=每次命中交付那拍预取 (现行基线)
    parameter LD_INFLIGHT = 4,       // 在飞 load 上限
    parameter SQ_DEPTH    = 8,       // 已提交 store 队列深度
    parameter RD_DEPTH    = 32,      // 读事务 FIFO 深度 (须 ≥ 2*IC_LINE_WORDS 且为 2 的幂, 见 mem_subsystem)
    parameter WR_DEPTH    = 8        // 写事务在途上限 (须 < 从机 AW/W FIFO 深度 = 16)
) (
    input  wire        clock,
    input  wire        reset,        // 高电平复位, 初始化时保持 5 周期高电平

    // AXI4-Lite 读地址通道 (AR)
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    // AXI4-Lite 读数据通道 (R)
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,        // 2'b00 = OKAY, 2'b10 = SLVERR, 2'b11 = DECERR
    input  wire        rvalid,
    output wire        rready,

    // AXI4-Lite 写地址通道 (AW)
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // AXI4-Lite 写数据通道 (W)
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,        // 字节写使能掩码
    output wire        wvalid,
    input  wire        wready,

    // AXI4-Lite 写响应通道 (B)
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    localparam LW = $clog2(LSQ_SIZE);

    wire rst_n = ~reset;

    // ---- cpu_top 与 mem_subsystem 之间的存储接口 ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] imem_addr;
    wire [ISSUE_WIDTH * 32 - 1 : 0] inst_data;
    wire                            imem_valid;
    wire                            imem_hit;
    wire                            imem_direct;
    wire                            ld_start_valid, ld_busy, ld_done_valid;
    wire [31 : 0]                   ld_start_addr, ld_done_data;
    wire [1 : 0]                    ld_start_width;
    wire [LW - 1 : 0]               ld_start_idx, ld_done_idx;
    wire                            sw_valid, sw_ready;
    wire [31 : 0]                   sw_addr, sw_data;
    wire [1 : 0]                    sw_width;

    cpu_top #(
        .ISSUE_WIDTH(ISSUE_WIDTH), .ROB_SIZE(ROB_SIZE), .RS_SIZE(RS_SIZE),
        .PRF_SIZE(PRF_SIZE), .LSQ_SIZE(LSQ_SIZE), .BHT_SIZE(BHT_SIZE), .RAS_SIZE(RAS_SIZE),
        .ROLLBACK_WIDTH(ROLLBACK_WIDTH)
    ) u_cpu (
        .clk(clock), .rst_n(rst_n),
        .imem_addr(imem_addr), .inst_data(inst_data), .imem_valid(imem_valid), .imem_hit(imem_hit),
        .imem_direct(imem_direct),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx), .ld_done_data(ld_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .sw_ready(sw_ready)
        // 其余 (halt / ret_val / 三个计数器 / rob_head) 是 TB 诊断口, 官方流程不用 ⇒ 悬空
    );

    mem_subsystem #(
        .ISSUE_WIDTH(ISSUE_WIDTH), .LSQ_SIZE(LSQ_SIZE),
        .IC_SIZE(IC_SIZE), .IC_LINE_WORDS(IC_LINE_WORDS),
        .IC_BYPASS(IC_BYPASS), .IC_PREFETCH(IC_PREFETCH),
        .DC_SIZE(DC_SIZE), .DC_LINE_WORDS(DC_LINE_WORDS), .DC_WAYS(DC_WAYS),
        .DC_PREFETCH(DC_PREFETCH),
        .LD_INFLIGHT(LD_INFLIGHT),
        .SQ_DEPTH(SQ_DEPTH), .RD_DEPTH(RD_DEPTH), .WR_DEPTH(WR_DEPTH)
    ) u_mem (
        .clk(clock), .rst_n(rst_n),
        .inst_data(inst_data), .imem_addr(imem_addr), .imem_valid(imem_valid), .imem_hit(imem_hit),
        .imem_direct(imem_direct),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(ld_done_valid), .ld_done_idx(ld_done_idx), .ld_done_data(ld_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .sw_ready(sw_ready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );
endmodule
