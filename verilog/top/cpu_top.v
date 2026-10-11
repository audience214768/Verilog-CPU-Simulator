// 顶层: RV32IM 乱序多发射 Tomasulo CPU 总流水线
// 三阶段结构 (与 C++ 参考 tick() 同构): 读端口 → 组合 assign → posedge 锁存
//   + **执行级再切一刀** (§15.10.13): execute_slot 内分 D 级(字段取 one-hot+AND-OR) /
//     Q 级(操作数获取 + alu/branch + CDB), 中间一个 144+1 位寄存器。rs 仲裁仍在 D 级当拍
//     出 sel_idx, 只是它下游的字段取与执行晚一拍; 配套的 rs_clear/flush/div 扣住规则见该文件头
// 组合块: B2 发射(全批 or 不批) B5 walker 回滚(组合部分) B6 提交(连续就绪, store≤1)
//         B1 操作数获取(CDB 旁路)/B3 执行分发/B4 误预测检测 → verilog/exec/execute_slot.v (Q 级)
//         误预测汇出链(最老优先)与 fetch 重定向/rob 截断/ras 恢复在此
// 多周期除法: div 槽只发起 (载荷取槽 0), 34 拍后由 div.v 经 CDB 槽 W+1 写回; 在飞条目靠
//         pipe_stall 扣住流水寄存器 (没被收下就不能清条目), 错路靠 div_kill 作废 —— 两者都是死锁/写坏
//         空闲 preg 的关口, 见各自 assign 处注释
module cpu_top #(
    parameter ISSUE_WIDTH  = 1,
    parameter ROB_SIZE     = 32,
    parameter RS_SIZE      = 16,
    parameter PRF_SIZE     = 64,
    parameter LSQ_SIZE     = 16,
    parameter BHT_SIZE     = 32,
    parameter RAS_SIZE     = 8,
    // 回滚 walker 每拍撤销的 ROB 条目数。与 ISSUE_WIDTH **解耦**: 发射宽度决定"一拍进多少",
    // 回滚宽度决定"一拍退多少", 二者最优值不同 (错路长度 R 与批宽无关)。
    // 见 docs/plan.md: 一次误预测花 R 拍 (1 拍检测 + R-1 拍逐条撤), 加宽即削掉 R-1 那部分。
    parameter ROLLBACK_WIDTH = 4
) (
    input  clk,
    input  rst_n,
    output halt,
    output [7 : 0]       ret_val,
    output [31 : 0]      commit_count, flush_count, branch_count,
    output [$clog2(ROB_SIZE) - 1 : 0] rob_head,
    output             rob_ready_head,
    // ---- 存储接口 (原内部 u_mem 提升为端口; 端口名/位宽与 core/memory.v 逐一对位) ----
    // 取指: 同步读 (地址寄存一拍后数据返回; 固定 1 拍存储下 imem_valid 恒 1)
    output [ISSUE_WIDTH * 32 - 1 : 0] imem_addr,
    input  [ISSUE_WIDTH * 32 - 1 : 0] inst_data,
    input                             imem_valid,
    input                             imem_hit,        // 本拍 imem_addr 地址在存储中已可取 (固定 1 拍存储恒 1)
    input                             imem_direct,     // 本拍 inst_data 是"直通行"交付 (非跨行装配);
                                                      //   供 fetch 把新请求组合地提前到本拍 (带 cache 的
                                                      //   存储才有区别; 固定 1 拍存储 TB 恒接 1'b1)
    // load: 发起 ≤1/周期, 完成 ≤1/周期 (idx 由完成脉冲回传)
    output                            ld_start_valid,
    output [31 : 0]                   ld_start_addr,
    output [1 : 0]                    ld_start_width,
    output [$clog2(LSQ_SIZE) - 1 : 0] ld_start_idx,
    input                             ld_done_valid,
    input  [$clog2(LSQ_SIZE) - 1 : 0] ld_done_idx,
    input  [31 : 0]                   ld_done_data,
    input                             ld_busy,
    // store: 提交级直写 ≤1/周期 (sw_ready=0 表示下游队列满, 该 store 本拍不提交)
    output                            sw_valid,
    output [31 : 0]                   sw_addr,
    output [31 : 0]                   sw_data,
    output [1 : 0]                    sw_width,
    input                             sw_ready
);
    localparam PW  = $clog2(PRF_SIZE);
    localparam RW  = $clog2(ROB_SIZE);
    localparam LW  = $clog2(LSQ_SIZE);
    localparam SRW = $clog2(RS_SIZE);
    localparam CSW = $clog2(RS_SIZE + 1);
    localparam RCW = $clog2(ROB_SIZE + 1);
    localparam LCW = $clog2(LSQ_SIZE + 1);
    localparam PCW = $clog2(PRF_SIZE + 1);
    localparam BW  = $clog2(BHT_SIZE);
    localparam RA  = $clog2(RAS_SIZE);
    localparam TERM_RAW  = 32'h0FF06013;   // ori x0, x0, 255      (手写程序约定)
    localparam TERM_RAW2 = 32'h0FF00513;   // addi a0, x0, 255     (编译测试程序约定, 见 decode)
    localparam MMIO_EXIT_ADDR = 32'h8000_0000;   // 官方停机判据地址 (docs/description.md:131)

    // ---- 预声明 (iverilog: 实例端口表达式与 generate 内引用须先声明) ----
    wire [RA - 1 : 0]                  misp_ras_w;
    wire [PRF_SIZE - 1 : 0]            rt_ready_w;
    wire [(ISSUE_WIDTH + 1) * PW - 1 : 0]  cdb_tag_w;
    wire [ISSUE_WIDTH : 0]           cdb_slot_valid_w;
    wire [ROB_SIZE - 1 : 0]            rob_ready_set_w;
    wire [ISSUE_WIDTH * PW - 1 : 0]  old_map_chain;      // 逐槽 old 映射 (实现见下方 omc 链)
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0]   mem_cnt_chain;
    reg                            halt_q_r, ret_latched_r;
    reg  [7 : 0]                     ret_val_r;
    wire                           ret_sample;
    wire [RW - 1 : 0]                  misp_fs_w;
    wire [(ISSUE_WIDTH + 1) * PRF_SIZE - 1 : 0] rt_clear_c;   // one-hot 掩码累加链 (rename clear)
    wire [(ROLLBACK_WIDTH + 1) * PRF_SIZE - 1 : 0] flclr_c;      // one-hot 掩码累加链 (walker flush clear)
    wire [(ISSUE_WIDTH + 1) * LSQ_SIZE - 1 : 0] inv_c;        // one-hot 掩码累加链 (commit invalidate)
    // execute_slot 输出 (每槽) + misp 汇出链 (最老优先前缀 OR)
    wire [ISSUE_WIDTH - 1 : 0]        misp_det_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0]   misp_red_w;
    wire [ISSUE_WIDTH * RW - 1 : 0]   misp_fs_pay_w;
    wire [ISSUE_WIDTH * RA - 1 : 0]   misp_ras_pay_w;
    wire [ISSUE_WIDTH - 1 : 0]        br_inc_w;
    wire [ISSUE_WIDTH : 0]            misp_any_c;   // misp_det 前缀 OR (段值在 slt 内)
    // div 发起 (段值在 slt 内; 授权槽载荷在 "div 发起仲裁" 处选, 实例在下方)
    wire [ISSUE_WIDTH - 1 : 0]        div_req_w;
    wire [ISSUE_WIDTH * 2 - 1 : 0]    div_op_all;
    wire [ISSUE_WIDTH * 32 - 1 : 0]   div_a_all, div_b_all;
    wire [ISSUE_WIDTH * PW - 1 : 0]   div_prd_all;
    wire [ISSUE_WIDTH * RW - 1 : 0]   div_rob_all;
    wire                              div_go_w, div_kill;
    wire                              div_busy, div_done_valid;
    wire [RW - 1 : 0]                 div_fly_rob_tag;   // 在飞那发的 rob_tag (div.v 内部锁存)
    wire [PW - 1 : 0]                 div_done_prd;
    wire [RW - 1 : 0]                 div_done_rob_tag;
    wire [31 : 0]                     div_done_result;
    wire [1 : 0]                      div_op_w;
    wire [31 : 0]                     div_a_w, div_b_w;
    wire [PW - 1 : 0]                 div_prd_w;
    wire [RW - 1 : 0]                 div_rob_w;

    // ==================== 1. 实例化区 ====================

    // ---- fetch / decode ----
    wire [ISSUE_WIDTH - 1 : 0]    f2i_valid;
    wire [ISSUE_WIDTH * 32 - 1 : 0] f2i_raw, f2i_pc, f2i_pred_target;
    wire [ISSUE_WIDTH - 1 : 0]    f2i_pred_taken;
    wire [ISSUE_WIDTH * RA - 1 : 0] f2i_ras_snap;
    wire fetch_stall;
    wire misp_valid;
    wire [31 : 0] redirect_pc_w;
    wire [ISSUE_WIDTH - 1 : 0]    upd_req_w;
    wire [ISSUE_WIDTH * BW - 1 : 0] upd_idx_w;
    wire [ISSUE_WIDTH - 1 : 0]    upd_taken_w;
    fetch #(.ISSUE_WIDTH(ISSUE_WIDTH), .BHT_SIZE(BHT_SIZE), .RAS_SIZE(RAS_SIZE)) u_fetch (
        .clk(clk), .rst_n(rst_n),
        .f2i_valid(f2i_valid), .f2i_raw(f2i_raw), .f2i_pc(f2i_pc),
        .f2i_pred_taken(f2i_pred_taken), .f2i_pred_target(f2i_pred_target),
        .f2i_ras_snap(f2i_ras_snap), .imem_addr(imem_addr),
        .bht_upd_req(upd_req_w), .bht_upd_idx(upd_idx_w), .bht_upd_taken(upd_taken_w),
        .ras_restore_valid(misp_valid), .ras_restore_head(misp_ras_w),
        .inst_data(inst_data), .imem_valid(imem_valid), .imem_hit(imem_hit),
        .imem_direct(imem_direct), .stall(fetch_stall),
        .redirect_valid(misp_valid), .redirect_pc(redirect_pc_w), .halt(halt_q_r)
    );
    wire [ISSUE_WIDTH * 7 - 1 : 0]  d_opcode, d_func7;
    wire [ISSUE_WIDTH * 3 - 1 : 0]  d_func3;
    wire [ISSUE_WIDTH * 5 - 1 : 0]  d_rd, d_rs1, d_rs2;
    wire [ISSUE_WIDTH * 32 - 1 : 0] d_imm;
    wire [ISSUE_WIDTH - 1 : 0] d_is_alu, d_is_mul, d_is_div, d_is_load, d_is_store, d_is_branch,
                           d_is_jal, d_is_jalr, d_is_lui, d_is_auipc,
                           d_writes_rd, d_mem_unsigned;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  d_mem_width;
    decode #(.ISSUE_WIDTH(ISSUE_WIDTH)) u_decode (
        .raw(f2i_raw), .d_valid(f2i_valid),
        .opcode(d_opcode), .func3(d_func3), .func7(d_func7),
        .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2), .imm(d_imm),
        .is_alu(d_is_alu), .is_mul(d_is_mul), .is_div(d_is_div),
        .is_load(d_is_load), .is_store(d_is_store),
        .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr),
        .is_lui(d_is_lui), .is_auipc(d_is_auipc),
        .writes_rd(d_writes_rd), .mem_width(d_mem_width), .mem_unsigned(d_mem_unsigned)
    );

    // ---- rat / free_list ----
    wire [ISSUE_WIDTH * PW - 1 : 0] map_out1, map_out2, alloc_val;
    wire [ROLLBACK_WIDTH * PW - 1 : 0] walk_flush_old;
    wire [32 * PW - 1 : 0]          map_arch;
    wire [PCW - 1 : 0]            fl_count;
    wire [ISSUE_WIDTH - 1 : 0]    rename_valid;
    wire [ROLLBACK_WIDTH - 1 : 0] walk_flush_valid;
    wire [ROLLBACK_WIDTH * 5 - 1 : 0]  walk_flush_rd;
    wire [ROLLBACK_WIDTH - 1 : 0]    fl_push_valid;
    wire [ROLLBACK_WIDTH * PW - 1 : 0] fl_push_preg;
    rat #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE), .ROLLBACK_WIDTH(ROLLBACK_WIDTH)) u_rat (
        .clk(clk), .rst_n(rst_n),
        .map_out1(map_out1), .map_out2(map_out2), .map_arch(map_arch),
        .read_rs1(d_rs1), .read_rs2(d_rs2),
        .rename_valid(rename_valid), .rename_rd(d_rd), .rename_new(alloc_val),
        .flush_valid(walk_flush_valid), .flush_rd(walk_flush_rd), .flush_old(walk_flush_old)
    );
    free_list #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE), .ROLLBACK_WIDTH(ROLLBACK_WIDTH)) u_fl (
        .clk(clk), .rst_n(rst_n),
        .alloc_val(alloc_val), .count_out(fl_count),
        .pop_req(rename_valid), .push_valid(fl_push_valid), .push_preg(fl_push_preg)
    );

    // ---- rob ----
    wire [RW - 1 : 0]     rob_head_w, rob_last_w;
    wire              rob_empty, rob_full;
    wire [RCW - 1 : 0]    rob_free_w;
    wire [ROB_SIZE - 1 : 0]       rob_ready_w;
    wire [ROB_SIZE * 7 - 1 : 0]     rob_opcode_w;
    wire [ROB_SIZE * 5 - 1 : 0]     rob_rd_w;
    wire [ROB_SIZE * PW - 1 : 0]    rob_new_w, rob_old_w;
    wire [ROB_SIZE * LW - 1 : 0]    rob_lsq_w;
    wire [ROB_SIZE * 32 - 1 : 0]    rob_raw_w;
    wire [ISSUE_WIDTH - 1 : 0]    rob_push_valid;
    wire [ISSUE_WIDTH * 7 - 1 : 0]  rob_push_opcode;
    wire [ISSUE_WIDTH * 5 - 1 : 0]  rob_push_rd;
    wire [ISSUE_WIDTH * PW - 1 : 0] rob_push_new, rob_push_old;
    wire [ISSUE_WIDTH * LW - 1 : 0] rob_push_lsq;
    wire [ISSUE_WIDTH * 32 - 1 : 0] rob_push_raw;
    wire set_head_valid;
    wire [RW - 1 : 0] set_head_val;
    wire set_last_valid;
    wire [RW - 1 : 0] set_last_val;
    rob #(.ISSUE_WIDTH(ISSUE_WIDTH), .ROB_SIZE(ROB_SIZE), .PRF_SIZE(PRF_SIZE), .LSQ_SIZE(LSQ_SIZE)) u_rob (
        .clk(clk), .rst_n(rst_n),
        .head(rob_head_w), .last(rob_last_w), .empty(rob_empty), .full(rob_full),
        .free_count(rob_free_w),
        .ready(rob_ready_w), .opcode(rob_opcode_w), .rd(rob_rd_w),
        .new_pnum(rob_new_w), .old_pnum(rob_old_w), .lsq_tag(rob_lsq_w), .ins_raw(rob_raw_w),
        .push_valid(rob_push_valid), .push_opcode(rob_push_opcode), .push_rd(rob_push_rd),
        .push_new(rob_push_new), .push_old(rob_push_old),
        .push_lsq_tag(rob_push_lsq), .push_ins_raw(rob_push_raw),
        .set_head_valid(set_head_valid), .set_head_val(set_head_val),
        .set_last_valid(set_last_valid), .set_last_val(set_last_val),
        .set_ready_req(rob_ready_set_w)
    );

    // ---- rs ----
    wire [ISSUE_WIDTH - 1 : 0]    sel_valid;
    wire [ISSUE_WIDTH * SRW - 1 : 0] sel_idx;
    wire [ISSUE_WIDTH - 1 : 0]    sel_valid_q;    // execute_slot Q 级有效 (晚一拍)
    wire [ISSUE_WIDTH - 1 : 0]    pipe_stall_w;   // execute_slot Q 级冻结
    wire [ISSUE_WIDTH - 1 : 0]    div_accept_w;   // div 发起被收下 (每拍至多一个槽为 1)
    wire [ISSUE_WIDTH - 1 : 0]    rs_clear_valid;
    wire [ISSUE_WIDTH * SRW - 1 : 0] rs_clear_idx;
    wire [CSW - 1 : 0]            rs_free_w;
    wire [RS_SIZE - 1 : 0]        rs_entry_valid;
    wire [RS_SIZE * 7 - 1 : 0]      rs_entry_opcode, rs_entry_func7;
    wire [RS_SIZE * 3 - 1 : 0]      rs_entry_func3;
    wire [RS_SIZE * PW - 1 : 0]     rs_entry_prs1, rs_entry_prs2, rs_entry_prd;
    wire [RS_SIZE * 32 - 1 : 0]     rs_entry_pc, rs_entry_imm, rs_entry_pred_target;
    wire [RS_SIZE * LW - 1 : 0]     rs_entry_lsq_tag;
    wire [RS_SIZE * RW - 1 : 0]     rs_entry_rob_tag;
    wire [RS_SIZE - 1 : 0]        rs_entry_pred_taken;
    wire [RS_SIZE * RA - 1 : 0]     rs_entry_ras_snap;
    wire [ISSUE_WIDTH * 7 - 1 : 0]  rs_push_opcode, rs_push_func7;
    wire [ISSUE_WIDTH * 3 - 1 : 0]  rs_push_func3;
    wire [ISSUE_WIDTH * PW - 1 : 0] rs_push_prs1, rs_push_prs2, rs_push_prd;
    wire [ISSUE_WIDTH * 32 - 1 : 0] rs_push_pc, rs_push_imm, rs_push_pred_target;
    wire [ISSUE_WIDTH * LW - 1 : 0] rs_push_lsq_tag;
    wire [ISSUE_WIDTH * RW - 1 : 0] rs_push_rob_tag;
    wire [ISSUE_WIDTH - 1 : 0]    rs_push_pred_taken;
    wire [ISSUE_WIDTH * RA - 1 : 0] rs_push_ras_snap;
    wire [RS_SIZE - 1 : 0]        rs_flush_mask;
    rs #(.ISSUE_WIDTH(ISSUE_WIDTH), .RS_SIZE(RS_SIZE), .PRF_SIZE(PRF_SIZE),
         .ROB_SIZE(ROB_SIZE), .LSQ_SIZE(LSQ_SIZE), .BHT_SIZE(BHT_SIZE), .RAS_SIZE(RAS_SIZE)) u_rs (
        .clk(clk), .rst_n(rst_n),
        .sel_valid(sel_valid), .sel_idx(sel_idx), .free_count(rs_free_w),
        .entry_valid(rs_entry_valid), .entry_opcode(rs_entry_opcode), .entry_func3(rs_entry_func3),
        .entry_func7(rs_entry_func7), .entry_prs1(rs_entry_prs1), .entry_prs2(rs_entry_prs2),
        .entry_prd(rs_entry_prd), .entry_pc(rs_entry_pc), .entry_imm(rs_entry_imm),
        .entry_lsq_tag(rs_entry_lsq_tag), .entry_rob_tag(rs_entry_rob_tag),
        .entry_pred_taken(rs_entry_pred_taken), .entry_pred_target(rs_entry_pred_target),
        .entry_ras_snap(rs_entry_ras_snap),
        .rt_ready(rt_ready_w), .cdb_tag(cdb_tag_w), .cdb_slot_valid(cdb_slot_valid_w),
        .rob_head(rob_head_w),
        .push_valid(rob_push_valid), .push_opcode(rs_push_opcode), .push_func3(rs_push_func3),
        .push_func7(rs_push_func7), .push_prs1(rs_push_prs1), .push_prs2(rs_push_prs2),
        .push_prd(rs_push_prd), .push_pc(rs_push_pc), .push_imm(rs_push_imm),
        .push_lsq_tag(rs_push_lsq_tag), .push_rob_tag(rs_push_rob_tag),
        .push_pred_taken(rs_push_pred_taken), .push_pred_target(rs_push_pred_target),
        .push_ras_snap(rs_push_ras_snap),
        .clear_valid(rs_clear_valid), .clear_idx(rs_clear_idx),
        .flush_mask(rs_flush_mask)
    );
    // 执行槽清空 = 本拍选择结果 (rs 内部 posedge 应用)
    // 例外: 该槽的流水寄存器本拍**冻结** (pipe_stall) 时必须一起放过 —— 冻结期间 D 级选中
    // 的条目既没进寄存器也(若还清)不会被重选, 指令就丢了。冻结的三种成因见 execute_slot.v 文件头:
    // 冲刷窗口 / 本拍检出误预测 / 本槽的 div 没被除法器收下 (条目在入选那拍已清, 只能扣寄存器,
    // 所以"条目扣住"这个旧手段在流水化后不成立了, 必须换成同一条件放过 rs_clear)。
    assign rs_clear_valid = sel_valid & ~pipe_stall_w;
    assign rs_clear_idx   = sel_idx;

    // ---- ready_table / prf / cdb ----
    wire [PRF_SIZE - 1 : 0] rt_clear_req, rt_flush_clear_req;
    wire [PRF_SIZE - 1 : 0] rt_set_req_w;
    ready_table #(.PRF_SIZE(PRF_SIZE)) u_rt (
        .clk(clk), .rst_n(rst_n),
        .ready(rt_ready_w), .set_req(rt_set_req_w),
        .clear_req(rt_clear_req), .flush_clear_req(rt_flush_clear_req)
    );
    wire [ISSUE_WIDTH * 32 - 1 : 0] prf_d1, prf_d2;
    wire [ISSUE_WIDTH * PW - 1 : 0] rd1_preg, rd2_preg;
    wire [ISSUE_WIDTH + 1 : 0]          cdb_prf_valid;
    wire [(ISSUE_WIDTH + 2) * PW - 1 : 0] cdb_prf_preg;
    wire [(ISSUE_WIDTH + 2) * 32 - 1 : 0] cdb_prf_data;
    prf #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE)) u_prf (
        .clk(clk),
        .data_out1(prf_d1), .data_out2(prf_d2),
        .rd1_preg(rd1_preg), .rd2_preg(rd2_preg),
        .wr_valid(cdb_prf_valid), .wr_preg(cdb_prf_preg), .wr_data(cdb_prf_data)
    );
    wire [ISSUE_WIDTH - 1 : 0]    cdb_exec_valid;
    wire [ISSUE_WIDTH - 1 : 0]    cdb_exec_rob_wr = {ISSUE_WIDTH{1'b1}};   // 恒 1: 执行完成即置 ROB ready
    wire [ISSUE_WIDTH * PW - 1 : 0] cdb_exec_prd;
    wire [ISSUE_WIDTH * 32 - 1 : 0] cdb_exec_result;
    wire [ISSUE_WIDTH * RW - 1 : 0] cdb_exec_rob_tag;
    // ---- load CDB 组: lsq 出口 → 边界寄存一级 (刀 A, plan §20/§21: 拆流水级) ----
    // 关键路径 (diag9 逐级归因) 是 dcache 读口 → mem_subsystem → lsq 合并 → CDB → slot 旁路 →
    // branch 加法器 → misp 广播 → fetch/rs 一条**单拍**长链; 在这一刀之前 lsq 的 5 根 CDB 输出
    // 同拍喂给 u_cdb / u_slot 旁路 / rs 唤醒广播。这里整组寄存, 所有消费者**一致**晚一拍 ⇒ 语义 =
    // "load-use 延迟 +1 拍" (实测 geo IPC −3.42%, plan §21.4)。
    // **陈旧广播**: 打一拍后本组可能指向**已被 flush 杀掉**的条目 (raw 那拍还合法, 下一拍到),
    // 而那个槽可能已被复用的新指令占用 ⇒ 消费者必须让"新住户"赢, 否则新指令带 ready 入队:
    //   · rob: push 的清零压过 set_ready (plan §21.3 —— 修复前 magic 静默死锁)
    //   · ready_table: clear(重分配/冲刷) 压过 set (既有优先级, 无需改)
    // prd 复用另有一层安全: load 的 prd 只能在自己提交后才回收, 而提交依赖本组里的 rob_ready
    // (同样晚一拍) ⇒ 回收 ≥ N+2、再分配 ≥ N+3, 本组的 prf 写落在 posedge N+1 ⇒ 早于任何再分配。
    wire            load_cdb_valid_raw;
    wire [PW - 1 : 0]   load_cdb_prd_raw;
    wire [31 : 0]     load_cdb_result_raw;
    wire [RW - 1 : 0]   load_cdb_rob_tag_raw;
    wire            load_cdb_rob_wr_raw;
    reg             load_cdb_valid;
    reg [PW - 1 : 0]    load_cdb_prd;
    reg [31 : 0]      load_cdb_result;
    reg [RW - 1 : 0]    load_cdb_rob_tag;
    reg             load_cdb_rob_wr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cdb_valid   <= 1'b0;
            load_cdb_prd     <= {PW{1'b0}};
            load_cdb_result  <= 32'd0;
            load_cdb_rob_tag <= {RW{1'b0}};
            load_cdb_rob_wr  <= 1'b0;
        end else begin
            load_cdb_valid   <= load_cdb_valid_raw;
            load_cdb_prd     <= load_cdb_prd_raw;
            load_cdb_result  <= load_cdb_result_raw;
            load_cdb_rob_tag <= load_cdb_rob_tag_raw;
            load_cdb_rob_wr  <= load_cdb_rob_wr_raw;
        end
    end
    cdb #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE), .ROB_SIZE(ROB_SIZE)) u_cdb (
        .exec_valid(cdb_exec_valid), .exec_prd(cdb_exec_prd), .exec_result(cdb_exec_result),
        .exec_rob_tag(cdb_exec_rob_tag), .exec_rob_wr(cdb_exec_rob_wr),
        .load_valid(load_cdb_valid), .load_prd(load_cdb_prd), .load_result(load_cdb_result),
        .load_rob_tag(load_cdb_rob_tag), .load_rob_wr(load_cdb_rob_wr),
        .div_valid(div_done_valid), .div_prd(div_done_prd),
        .div_result(div_done_result), .div_rob_tag(div_done_rob_tag),
        .prf_valid(cdb_prf_valid), .prf_preg(cdb_prf_preg), .prf_data(cdb_prf_data),
        .rt_set_req(rt_set_req_w), .rob_ready_req(rob_ready_set_w)
    );

    // ---- div: 多周期除法器 (34 拍), 完成经 CDB 槽 W+1 ----
    // 发起仲裁与授权槽的载荷选取都在下方 "div 发起仲裁" 处 (用 generate, 须排在 genvar 声明之后)。
    div #(.PRF_SIZE(PRF_SIZE), .ROB_SIZE(ROB_SIZE)) u_div (
        .clk(clk), .rst_n(rst_n),
        .start_valid(div_go_w), .start_op(div_op_w),
        .start_a(div_a_w), .start_b(div_b_w),
        .start_prd(div_prd_w), .start_rob_tag(div_rob_w),
        .kill(div_kill),
        .busy(div_busy), .busy_rob_tag(div_fly_rob_tag),
        .done_valid(div_done_valid), .done_prd(div_done_prd),
        .done_rob_tag(div_done_rob_tag), .done_result(div_done_result)
    );

    // ---- lsq / memory ----
    wire [LW - 1 : 0]     lsq_head_w, lsq_last_w;
    wire              lsq_full;
    wire [LCW - 1 : 0]    lsq_free_w;
    wire [LSQ_SIZE - 1 : 0] lsq_valid_w, lsq_is_load_w, lsq_addr_ready_w, lsq_data_ready_w;
    wire [LSQ_SIZE * 32 - 1 : 0] lsq_addr_w, lsq_data_w;
    wire [LSQ_SIZE * RW - 1 : 0] lsq_rob_tag_w;
    wire [LSQ_SIZE * PW - 1 : 0] lsq_prs2_or_prd_w;
    wire [LSQ_SIZE * 2 - 1 : 0]  lsq_width_w;
    wire [LSQ_SIZE - 1 : 0]    lsq_is_unsigned_w;
    wire [ISSUE_WIDTH - 1 : 0]    lsq_push_valid;
    wire [ISSUE_WIDTH * RW - 1 : 0] lsq_push_rob_tag;
    wire [ISSUE_WIDTH * PW - 1 : 0] lsq_push_prs2_or_prd;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  lsq_push_width;
    wire [ISSUE_WIDTH - 1 : 0]    lsq_push_is_unsigned, lsq_push_is_load;
    wire [ISSUE_WIDTH - 1 : 0]    set_addr_req, set_data_req;
    wire [ISSUE_WIDTH * LW - 1 : 0] set_addr_idx, set_data_idx;
    wire [ISSUE_WIDTH * 32 - 1 : 0] set_addr_val, set_data_val;
    wire [LSQ_SIZE - 1 : 0] lsq_flush_mask, lsq_invalidate_c;
    // 提交失效**延迟一拍**送 LSQ: load 完成数据在时钟沿采样 (沿前的存储内容), 而 store 的写与
    // 条目失效落在同一沿 ⇒ 数据恰在提交后一拍返回的 load 会**两条路同时丢**这个 store
    // (lsq 的字节前向要求条目仍 valid, 存储侧又还没见到这次写) ⇒ 静默读到陈旧值。
    // 延迟一拍后, 该条目在唯一危险的那一拍仍可供前向。无容量损失: skip/dead 同拍就把它算作
    // 已死, head 也正因为 kill 才跳过它 ⇒ 延迟掩码不可能打到已被复用的槽位。
    reg [LSQ_SIZE - 1 : 0] lsq_invalidate;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lsq_invalidate <= {LSQ_SIZE{1'b0}};
        else        lsq_invalidate <= lsq_invalidate_c;
    end
    // ---- load 完成口: 存储边界寄存一级 (刀 D, plan §22: 拆流水级, 靶 = §21.6 墙 ①) ----
    // 墙 ① 的 64 级里, 存储侧 (dcache 填充/写回引擎 → mem_subsystem 的字节合并) 与消费侧 (lsq 的
    // SQ 字节前向 + 符号扩展 → load_cdb 寄存器) 各占约一半, 故在边界断一刀。三件套必须整组同拍寄存
    // (valid/idx 与 data 错开 = idx 配错数据)。端口级契约不变: 仍是"接受一个 load 恰好回一个
    // ld_done_valid", 只是这一拍晚到; ld_busy **保持组合不动** —— 它是"当场兑现"的承诺
    // (mem_subsystem.v:20-22), 寄存即死锁。
    // 陈旧完成安全: lsq 的 issued_r 是完成与请求之间唯一的身份标识, 在飞条目即使 valid 被清也
    // 不算死、槽位不可复用 (lsq.v 头注释 ②) ⇒ 多等一拍不会打到已被 push 复用的新条目。
    // 复位与 mem_subsystem 同步断言 ⇒ 在飞 load 不跨复位存活 (两侧 issued/计数一起清)。
    // ★ 刀 Q (2026-10-11): 同一拍**另寄存一份 one-hot** (`ld_done_oh_q`) 给 lsq 的索引读用 ——
    //   4 位索引在 lsq 里要展开成"取哪个条目的地址/宽度/prd/rob_tag"的 16 选 1 宽译码, 索引 bit0
    //   单脚驱动 120 脚、级 0~2 共 1.01 ns (头名家族 (c) 的 21%)。译码挪到本寄存器的 **D 端**
    //   (与 `cpu_top.v` 提交口的 `lsq_oh` 同一写法), 索引位就只剩 16 个 2 输入比较器, 而且**越过
    //   寄存器之后 abc 无法反推**"它是那个索引的 one-hot"(对下游组合锥它只是主输入) ⇒ 结构必保。
    //   索引本身仍要寄存 (`ddi` 的年龄减法用) ⇒ 两个寄存器**同一 always 块同拍更新**(错拍 = 索引配错数据)。
    //   one-hot 生效后完成脉冲不再需要单独寄存 valid (lsq 的选通一律走 `mem_done_oh`) ⇒ 原
    //   `ld_done_valid_q` 与 lsq 的 `mem_done_valid` 端口一并净删 (各 1 个触发器/端口)。
    reg [LW - 1 : 0] ld_done_idx_q;
    reg [31 : 0]     ld_done_data_q;
    reg [LSQ_SIZE - 1 : 0] ld_done_oh_q;
    integer ldoh;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_done_idx_q   <= {LW{1'b0}};
            ld_done_data_q  <= 32'd0;
            ld_done_oh_q    <= {LSQ_SIZE{1'b0}};
        end else begin
            ld_done_idx_q   <= ld_done_idx;
            ld_done_data_q  <= ld_done_data;
            // valid 折进 one-hot (与 `lsq_oh` 同款): "无完成"时全 0 ⇒ 下游 AND-OR 天然为 0
            for (ldoh = 0; ldoh < LSQ_SIZE; ldoh = ldoh + 1)
                ld_done_oh_q[ldoh] <= ld_done_valid && (ld_done_idx == ldoh[LW - 1 : 0]);
        end
    end
    lsq #(.ISSUE_WIDTH(ISSUE_WIDTH), .LSQ_SIZE(LSQ_SIZE), .PRF_SIZE(PRF_SIZE), .ROB_SIZE(ROB_SIZE)) u_lsq (
        .clk(clk), .rst_n(rst_n),
        .head(lsq_head_w), .last(lsq_last_w), .full(lsq_full), .free_count(lsq_free_w),
        .valid(lsq_valid_w), .is_load(lsq_is_load_w), .addr_ready(lsq_addr_ready_w),
        .data_ready(lsq_data_ready_w), .addr(lsq_addr_w), .data(lsq_data_w),
        .rob_tag(lsq_rob_tag_w), .prs2_or_prd(lsq_prs2_or_prd_w),
        .width(lsq_width_w), .is_unsigned(lsq_is_unsigned_w),
        .rob_head(rob_head_w),
        .push_valid(lsq_push_valid), .push_rob_tag(lsq_push_rob_tag),
        .push_prs2_or_prd(lsq_push_prs2_or_prd), .push_width(lsq_push_width),
        .push_is_unsigned(lsq_push_is_unsigned), .push_is_load(lsq_push_is_load),
        .set_addr_req(set_addr_req), .set_addr_idx(set_addr_idx), .set_addr_val(set_addr_val),
        .set_data_req(set_data_req), .set_data_idx(set_data_idx), .set_data_val(set_data_val),
        .flush_mask(lsq_flush_mask), .invalidate(lsq_invalidate),
        .mem_done_idx(ld_done_idx_q), .mem_done_data(ld_done_data_q),
        .mem_done_oh(ld_done_oh_q),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx), .ld_busy(ld_busy),
        .load_cdb_valid(load_cdb_valid_raw), .load_cdb_prd(load_cdb_prd_raw),
        .load_cdb_result(load_cdb_result_raw), .load_cdb_rob_tag(load_cdb_rob_tag_raw),
        .load_cdb_rob_wr(load_cdb_rob_wr_raw)
    );
    // 存储由外部提供 (TB 例化 core/memory.v, student_top 例化 core/mem_subsystem.v)

    // ==================== 2. B5 walker 状态与回滚组合 ====================
    genvar s, j, jj, mm, c, e;
    reg flushing_r;
    reg [RW - 1 : 0] flush_fs_r, walk_ptr_r;
    wire [RW - 1 : 0] fs_eff_w, rem_w;
    wire walk_done;
    // 当拍新误预测是否比已注册的冲刷点更老 (冲刷中才可能为真: 更老的条目在 walker 期间才执行)
    wire misp_older_w = (misp_fs_w - rob_head_w) < (flush_fs_r - rob_head_w);
    // fs_eff = 当前生效冲刷点 (中途新误预测更老 → 取新); 无 flush 时组合为 misp_fs, 仅 walker 用 (flushing_r 门控)
    assign fs_eff_w = flushing_r ? ((misp_valid && misp_older_w) ? misp_fs_w : flush_fs_r)
 : misp_fs_w;
    assign rem_w    = walk_ptr_r - fs_eff_w;   // 待回滚条数 (fs+1..walk_ptr]
    assign walk_done = flushing_r && (rem_w <= ROLLBACK_WIDTH);
    wire [ROLLBACK_WIDTH * RW - 1 : 0] walk_idx_w;
    wire [ROLLBACK_WIDTH - 1 : 0]    walked_valid;
    wire [ROLLBACK_WIDTH * PW - 1 : 0] wlk_push_preg;
    generate
        for (jj = 0; jj < ROLLBACK_WIDTH; jj = jj + 1) begin : walk
            assign walk_idx_w[jj * RW +: RW] = walk_ptr_r - jj;            // 回绕
            assign walked_valid[jj]        = flushing_r && (rem_w > jj);
            // 回滚 rename 状态: rat.flush(恢复 old_pnum) + free_list push(new_pnum) + ready_table 清零
            assign walk_flush_rd[jj * 5 +: 5]    = rob_rd_w[walk_idx_w[jj * RW +: RW] * 5 +: 5];
            assign walk_flush_old[jj * PW +: PW] = rob_old_w[walk_idx_w[jj * RW +: RW] * PW +: PW];
            assign walk_flush_valid[jj]        = walked_valid[jj] && (rob_new_w[walk_idx_w[jj * RW +: RW] * PW +: PW] != 0);
            wire [PW - 1 : 0] wlk_preg = rob_new_w[walk_idx_w[jj * RW +: RW] * PW +: PW];
            assign wlk_push_preg[jj * PW +: PW]  = wlk_preg;
            // preg 0 常就绪, 不可被清零 (one-hot 掩码链)
            wire [PRF_SIZE - 1 : 0] flc_one = (walked_valid[jj] && (wlk_preg != 0))
 ? ({{(PRF_SIZE - 1){1'b0}}, 1'b1} << wlk_preg) : {PRF_SIZE{1'b0}};
            if (jj == 0) begin : fc0
                assign flclr_c[0 * PRF_SIZE +: PRF_SIZE] = flc_one;
            end else begin : fcn
                assign flclr_c[jj * PRF_SIZE +: PRF_SIZE] = flclr_c[(jj - 1) * PRF_SIZE +: PRF_SIZE] | flc_one;
            end
        end
    endgenerate

    // ==================== 3. 发射 (B2) + 执行槽分发 (B1/B3/B4) ====================
    assign rt_flush_clear_req = flclr_c[(ROLLBACK_WIDTH - 1) * PRF_SIZE +: PRF_SIZE];

    // ---- 计数链 (前缀累加; 段值在 slt/cmt generate 内生成) ----
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0] wr_acc, mem_acc, sel_acc, br_acc, com_acc, v_acc;
    wire [2 : 0] n_wr, n_mem, n_commit, n_branch, sel_cnt, n_valid;
    assign wr_acc[0 * 3 +: 3]  = 3'd0;
    assign mem_acc[0 * 3 +: 3] = 3'd0;
    assign sel_acc[0 * 3 +: 3] = 3'd0;
    assign br_acc[0 * 3 +: 3]  = 3'd0;
    assign com_acc[0 * 3 +: 3] = 3'd0;
    assign v_acc[0 * 3 +: 3]   = 3'd0;
    assign n_wr     = wr_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_mem    = mem_acc[ISSUE_WIDTH * 3 +: 3];
    assign sel_cnt  = sel_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_branch = br_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_commit = com_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_valid  = v_acc[ISSUE_WIDTH * 3 +: 3];   // 本批有效指令数 = 本拍 ROB push 数

    // ---- 发射条件 (全批 or 不批; misp 周期抑制见约束 1) ----
    // ★ 锥 ② 频率刀 (2026-10-11): 这里**不再**门控 halt_q_r, fetch_stall 同步去掉 halt_q_r。
    //   原写法 `&& !halt_q_r` 的动机是"halt 后 fetch 冻结 ⇒ have_batch 常 1 ⇒ 同一批反复压入
    //   rob/rs 死循环"; 但那个死循环的真正成因是 **fetch_stall 也含 halt_q_r** ⇒ stall 恒 1 ⇒
    //   batch_taken 恒 0 ⇒ f2i_valid_r 永不清。两项同删后握手自洽: 停机时 f2i 里那**至多一条**
    //   残余批照常发射、batch_taken 同拍清 f2i_valid_r ⇒ have_batch 落 0 ⇒ 不再发射, ROB 排空
    //   ⇒ ret_sample 照常成立。残余批至多一条, 因为 fetch 的 .halt() 仍冻结 pc_r 与 cap_w
    //   (cap_w 含 !halt) ⇒ 停机后不可能再交付新批; redirect 分支可改 pc, 但 cap_w 依旧把它挡在
    //   接收之外。副作用: 这条残余指令会照常执行/提交 (它在停机 store 之后, 只能写 PRF/内存,
    //   碰不到退出值 = prf_d1[0]/x0, 也碰不到 halt_q_r 的锁存)。
    //   收益 (改动前实测): halt_q_r 是官方流程头名起点 `_157633_/QN` —— 5.8926 ns, 全设计
    //   2546/3012 条 >3.333 ns 的路径都从它出发, 终点 fetch.v:209-212 (pc_r)。它是**一次性
    //   0→1 电平**, 却因这两项被并进"发射资源/唤醒"那片深组合云 (netattr: `_029214_` 反锥
    //   叶子含 cpu_top.v:936-948×2)。删掉后该锥整族消失 (下一名 = 4.5920 ns 的 axi_lite_master 读指针)。
    // lsq_free_w 已是"本拍可 push 数"(内部已含本拍失效腾出的槽), 此处不再另加本拍失效数
    // rs 项同样必须用"真空闲槽数": rs.v 的 push 分配器只认 !valid_r, 看不到本拍 clear,
    // 若把本拍选中数 sel_cnt 也算作可用, 会放行一次注定被 rs.v 丢弃的 push
    // (指令入 rob 却无 rs 条目 → 永不执行 → 依赖链死锁; 详见 docs/plan.md §7.4)
    wire have_batch = |f2i_valid;
    // ROB 必须按**本批实际 push 数** n_valid 预留: 原来只查 !rob_full (空闲 >= 1) 是 W=1 的口径,
    // W>=2 时 rob 只剩 1 个空位也照收 2 条 —— free_r 是 RCW 位计数器, 1-2 下溢回绕成 63
    // ⇒ 占用量 rob_occ = ROB_SIZE - free_r 越界 (33 > ROB_SIZE), 而 cmt_in_win = (c < rob_occ)
    // 因此对**窗口外槽**也成立 (这条判据本就是为"越窗提交"打的补丁, 被回绕整条绕过);
    // 同时 last_r 越过真实占用, walker 从 last_r-1 起回滚就走到**从未 push 过的残留槽**。
    // 两条路径都把已回收过的 preg 又回收一次 (旧条目的 old_pnum / 残留槽的 new_pnum)
    // ⇒ 池内重复项 ⇒ 同一 preg 发给两条在飞指令; 且 empty (free_r == ROB_SIZE) 长期不成立
    // ⇒ 停机锁存永不置位。W=1 每批至多 1 条 ⇒ 该缺陷不可见。
    wire resources_ok = (rob_free_w >= n_valid) && (rs_free_w >= ISSUE_WIDTH)
                     && (fl_count >= n_wr) && (lsq_free_w >= n_mem);
    wire issue_en = have_batch && !misp_valid && !flushing_r && resources_ok;

    // ---- 误预测汇出 (B4) ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] redirect_c;
    wire [ISSUE_WIDTH * RW - 1 : 0] misp_fs_c;
    wire [ISSUE_WIDTH * RA - 1 : 0] misp_ras_c;
    assign misp_valid = |misp_det_w;
    assign redirect_pc_w = redirect_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign misp_fs_w     = misp_fs_c[(ISSUE_WIDTH - 1) * RW +: RW];
    assign misp_ras_w    = misp_ras_c[(ISSUE_WIDTH - 1) * RA +: RA];

    // ---- div 发起仲裁 (**任意槽**可发起, 每拍至多收下一个: 最低请求槽优先) ----
    // "收下"与"放行"必须同拍且一一对应: execute_slot 的 q_freeze = ... && !div_accept, div_accept 是
    // Q 级唯一的放行条件 ⇒ 收下却不放行 = Q 级永久冻结; 放行却没被收下 = 这一发没人执行。
    // 后者是致命的, 因为 RS 条目**在入选那拍就被清** (execute_slot.v 不变量 1), 冻结寄存器里的副本
    // 就是唯一副本 —— 没有"重选"这回事。曾据此假定"只让槽 0 启动, 高槽的 div 会随槽 0 推进而移回
    // 槽 0", **该推理是错的**: 槽 >= 1 上的 div 直接丢失, 而它在 ROB 里必须按序提交 ⇒ 全机挂死
    // (ISSUE_WIDTH=2 实测 100M 拍超时)。现在任何槽都能被授权, 没轮上的槽下一拍重发, 无丢失路径。
    // 忙时/冲刷中一律不授权: 忙时启动会丢这一发 (同上); 冲刷中启动则可能让错路 div 逃过 kill ——
    // rs 失效掩码只在 walker 拍生效, 而 walker 可能当拍就走完。误预测当拍 Q 寄存器是被**清空**的
    // (flush_hit), 故冲刷窗口结束后各槽都不会残留错路 div。
    genvar gm, gs;
    wire [ISSUE_WIDTH - 1 : 0] div_gnt_w;    // 授权槽 (one-hot)
    // x & (-x) = 最低置位 ⇒ 多槽同时请求时按槽号仲裁, 每拍恰好一个
    assign div_gnt_w = div_req_w & (~div_req_w + {{(ISSUE_WIDTH - 1){1'b0}}, 1'b1});
    assign div_go_w  = (|div_gnt_w) && !div_busy && !flushing_r;
    // 授权槽载荷: one-hot ⇒ 逐位 AND-OR 归约 (与 execute_slot 的字段取同法)。不用变量索引的
    // 位段取: 它会综合成 mux 树且索引最低位落在最宽一级 (见 execute_slot 的注释)。
    localparam PLW = 2 + 32 + 32 + PW + RW;      // op + a + b + prd + rob_tag
    localparam O_DOP  = 0;                        // : 2
    localparam O_DA   = O_DOP  + 2;               // : 32
    localparam O_DB   = O_DA   + 32;              // : 32
    localparam O_DPRD = O_DB   + 32;              // : PW
    localparam O_DROB = O_DPRD + PW;              // : RW
    wire [ISSUE_WIDTH * PLW - 1 : 0] div_pl_all;
    wire [PLW - 1 : 0] div_pl;
    generate
        for (gs = 0; gs < ISSUE_WIDTH; gs = gs + 1) begin : dpl
            assign div_pl_all[gs * PLW +: PLW] = {
                div_rob_all[gs * RW +: RW], div_prd_all[gs * PW +: PW],
                div_b_all[gs * 32 +: 32],   div_a_all[gs * 32 +: 32],
                div_op_all[gs * 2 +: 2] };
        end
        for (gm = 0; gm < PLW; gm = gm + 1) begin : dsel
            wire [ISSUE_WIDTH - 1 : 0] m;
            for (gs = 0; gs < ISSUE_WIDTH; gs = gs + 1) begin : e
                assign m[gs] = div_pl_all[gs * PLW + gm] & div_gnt_w[gs];
            end
            assign div_pl[gm] = |m;
        end
    endgenerate
    assign div_op_w  = div_pl[O_DOP  +: 2];
    assign div_a_w   = div_pl[O_DA   +: 32];
    assign div_b_w   = div_pl[O_DB   +: 32];
    assign div_prd_w = div_pl[O_DPRD +: PW];
    assign div_rob_w = div_pl[O_DROB +: RW];

    // ---- 每槽胶水 ----
    // ret_sample 打一拍的锁存 (Cut B, 语义见下面 "halt / ret_val 锁存" 一节):
    // 声明必须在**使用它的槽 0 读口 mux 之前** —— iverilog 的 generate 作用域不做前向绑定
    // (Verilator/Yosys 容忍, 但 tb_cpu_prog 这条 iverilog 路会直接编不过)。
    reg ret_sample_q;
    generate
        for (s = 0; s < ISSUE_WIDTH; s = s + 1) begin : slt
            // ===== B2 发射: 每槽 push/rename 信号 =====
            wire ren_v = issue_en && d_writes_rd[s];
            wire memop = d_is_load[s] || d_is_store[s];
            wire [2 : 0] lsq_off = mem_cnt_chain[s * 3 +: 3];   // 本槽前 memop 数 (lsq_tag 前缀)
            assign rename_valid[s] = ren_v;
            wire [PW - 1 : 0] wnew = alloc_val[s * PW +: PW];
            // 新映射未就绪 (clear 优先于 set; one-hot 掩码链)
            wire [PRF_SIZE - 1 : 0] rtc_one = ren_v ? ({{(PRF_SIZE - 1){1'b0}}, 1'b1} << wnew) : {PRF_SIZE{1'b0}};
            if (s == 0) begin : rc0
                assign rt_clear_c[0 * PRF_SIZE +: PRF_SIZE] = rtc_one;
            end else begin : rcn
                assign rt_clear_c[s * PRF_SIZE +: PRF_SIZE] = rt_clear_c[(s - 1) * PRF_SIZE +: PRF_SIZE] | rtc_one;
            end
            // 必须带 f2i_valid[s]: issue_en 是**整批**决定 (W=1 时 f2i_valid 只有 1 位 ⇒ 二者等价),
            // 而 f2i_valid 是**稠密前缀** —— 批内首个预测跳转之后的槽是错误路径 (fetch.v:225)。
            // 漏掉这一项, 那些槽会用 d_* 的全 0 (decode 输出按 d_valid 门控) 压进 rob+rs:
            // 幽灵条目 opcode=0 → 无功能单元认领 → ready 永不为 1 (rob.v 唯一置位源是 CDB)
            // → ROB 头堵死。实测表现: 无分支的 naive 通过, 凡有预测跳转的程序全挂。
            assign rob_push_valid[s] = issue_en && f2i_valid[s];
            assign rob_push_opcode[s * 7 +: 7]    = d_opcode[s * 7 +: 7];
            assign rob_push_rd[s * 5 +: 5]        = d_rd[s * 5 +: 5];
            assign rob_push_new[s * PW +: PW]     = ren_v ? alloc_val[s * PW +: PW] : {PW{1'b0}};
            assign rob_push_old[s * PW +: PW]     = ren_v ? old_map_chain[s * PW +: PW] : {PW{1'b0}};
            assign rob_push_lsq[s * LW +: LW]     = memop ? (lsq_last_w + lsq_off) : {LW{1'b0}};
            assign rob_push_raw[s * 32 +: 32]     = f2i_raw[s * 32 +: 32];
            assign rs_push_opcode[s * 7 +: 7]     = d_opcode[s * 7 +: 7];
            assign rs_push_func3[s * 3 +: 3]      = d_func3[s * 3 +: 3];
            assign rs_push_func7[s * 7 +: 7]      = d_func7[s * 7 +: 7];
            assign rs_push_prs1[s * PW +: PW]     = map_out1[s * PW +: PW];
            assign rs_push_prs2[s * PW +: PW]     = map_out2[s * PW +: PW];
            assign rs_push_prd[s * PW +: PW]      = ren_v ? alloc_val[s * PW +: PW] : {PW{1'b0}};
            assign rs_push_pc[s * 32 +: 32]       = f2i_pc[s * 32 +: 32];
            assign rs_push_imm[s * 32 +: 32]      = d_imm[s * 32 +: 32];
            assign rs_push_lsq_tag[s * LW +: LW]  = memop ? (lsq_last_w + lsq_off) : {LW{1'b0}};
            assign rs_push_rob_tag[s * RW +: RW]  = rob_last_w + s;   // = ROB 写入 index (last_r + psum)
            assign rs_push_pred_taken[s]        = f2i_pred_taken[s];
            assign rs_push_pred_target[s * 32 +: 32] = f2i_pred_target[s * 32 +: 32];
            assign rs_push_ras_snap[s * RA +: RA]    = f2i_ras_snap[s * RA +: RA];
            assign lsq_push_valid[s]        = issue_en && memop;
            assign lsq_push_rob_tag[s * RW +: RW]   = rob_last_w + s;   // = ROB 写入 index
            assign lsq_push_prs2_or_prd[s * PW +: PW] = d_is_load[s] ? alloc_val[s * PW +: PW] : map_out2[s * PW +: PW];
            assign lsq_push_width[s * 2 +: 2]        = d_mem_width[s * 2 +: 2];
            assign lsq_push_is_unsigned[s]         = d_mem_unsigned[s];
            assign lsq_push_is_load[s]             = d_is_load[s];
            // 计数链段值
            assign wr_acc[(s + 1) * 3 +: 3]  = wr_acc[s * 3 +: 3] + (f2i_valid[s] && d_writes_rd[s]);
            assign mem_acc[(s + 1) * 3 +: 3] = mem_acc[s * 3 +: 3] + (f2i_valid[s] && memop);
            assign v_acc[(s + 1) * 3 +: 3]   = v_acc[s * 3 +: 3] + f2i_valid[s];
            assign sel_acc[(s + 1) * 3 +: 3] = sel_acc[s * 3 +: 3] + sel_valid[s];
            // (old_map 链段值改为在 generate 外统一生成 —— 见下方 omc 块)

            // ===== 逐槽 flush_hit (误预测当拍销毁哪几槽的 Q 级) =====
            // 不能全局广播 misp_valid: Q 级会被**冻结** (div 没被收下 / 冲刷窗口), 冻住那槽仍持有
            // 它入选那拍的那条, 而另一槽在这期间已前进若干条 ⇒ 两槽 Q **不再是年龄序**, 冻住的
            // 那条可能比误预测分支更老 ⇒ 正确路 (rs 条目在入选当拍已清 ⇒ Q 是唯一副本), 清了就是
            // 指令丢失 ⇒ 它的 ROB 条目永不就绪 ⇒ 提交停摆 ⇒ free_list 漏干 ⇒ 全机死锁。
            // 口径与 rs/lsq 失效掩码、div_kill 完全一致: 年龄 >= 冲刷点 ⇒ 分支本人/错路 ⇒ 清;
            // 更老 ⇒ 正确路 ⇒ 保住。另一支 !q_freeze: 本拍 W 级会收下它 (结果/重定向照发), 清掉
            // 只等于"不放新指令进来", 与旧行为一致 (旧行为对这类槽本就安全)。
            wire              q_freeze_s;
            wire [RW - 1 : 0] q_rob_tag_s;
            wire              flush_hit_s = misp_valid
                && (!q_freeze_s || ((q_rob_tag_s - rob_head_w) >= (fs_eff_w - rob_head_w)));

            // ===== execute_slot 实例 (B3 字段取 / B1 旁路 / alu+branch / CDB 广播 / 访存 / B4 检测) =====
            wire [PW - 1 : 0] slot_rd1;
            execute_slot #(.ISSUE_WIDTH(ISSUE_WIDTH), .RS_SIZE(RS_SIZE), .PRF_SIZE(PRF_SIZE),
                           .LSQ_SIZE(LSQ_SIZE), .ROB_SIZE(ROB_SIZE), .RAS_SIZE(RAS_SIZE),
                           .BHT_SIZE(BHT_SIZE), .SLOT_ID(s)) u_slot (
                .clk(clk), .rst_n(rst_n),
                .flush_win(flushing_r), .flush_hit(flush_hit_s), .div_accept(div_accept_w[s]),
                .q_freeze(q_freeze_s), .q_rob_tag(q_rob_tag_s),
                .sel_valid(sel_valid[s]), .sel_idx(sel_idx[s * SRW +: SRW]),
                .rs_entry_opcode(rs_entry_opcode), .rs_entry_func3(rs_entry_func3), .rs_entry_func7(rs_entry_func7),
                .rs_entry_prs1(rs_entry_prs1), .rs_entry_prs2(rs_entry_prs2), .rs_entry_prd(rs_entry_prd),
                .rs_entry_pc(rs_entry_pc), .rs_entry_imm(rs_entry_imm),
                .rs_entry_lsq_tag(rs_entry_lsq_tag), .rs_entry_rob_tag(rs_entry_rob_tag),
                .rs_entry_pred_taken(rs_entry_pred_taken), .rs_entry_pred_target(rs_entry_pred_target),
                .rs_entry_ras_snap(rs_entry_ras_snap),
                .prf_d1(prf_d1[s * 32 +: 32]), .prf_d2(prf_d2[s * 32 +: 32]),
                .cdb_slot_valid(cdb_slot_valid_w), .cdb_tag(cdb_tag_w),
                .cdb_exec_result(cdb_exec_result), .load_cdb_result(load_cdb_result),
                .div_start_req(div_req_w[s]), .div_op(div_op_all[s * 2 +: 2]),
                .div_a(div_a_all[s * 32 +: 32]), .div_b(div_b_all[s * 32 +: 32]),
                .div_prd(div_prd_all[s * PW +: PW]), .div_rob_tag(div_rob_all[s * RW +: RW]),
                .rd1_preg(slot_rd1), .rd2_preg(rd2_preg[s * PW +: PW]),
                .exec_valid(cdb_exec_valid[s]), .exec_prd(cdb_exec_prd[s * PW +: PW]),
                .exec_result(cdb_exec_result[s * 32 +: 32]), .exec_rob_tag(cdb_exec_rob_tag[s * RW +: RW]),
                .set_addr_req(set_addr_req[s]), .set_addr_idx(set_addr_idx[s * LW +: LW]),
                .set_addr_val(set_addr_val[s * 32 +: 32]),
                .set_data_req(set_data_req[s]), .set_data_idx(set_data_idx[s * LW +: LW]),
                .set_data_val(set_data_val[s * 32 +: 32]),
                .misp_det(misp_det_w[s]), .misp_red(misp_red_w[s * 32 +: 32]),
                .misp_fs(misp_fs_pay_w[s * RW +: RW]), .misp_ras(misp_ras_pay_w[s * RA +: RA]),
                .br_inc(br_inc_w[s]),
                .sel_valid_q(sel_valid_q[s]), .pipe_stall(pipe_stall_w[s]),
                .upd_req(upd_req_w[s]), .upd_idx(upd_idx_w[s * BW +: BW]), .upd_taken(upd_taken_w[s])
            );
            // 槽 0 读口复用为 ret_val 采样 (rob 空 ⇒ rs 已排空 ⇒ Q 级 sel_valid_q[0]==0)
            // 判据必须是 Q 级 (rd1_preg 现在由 Q 级字段驱动), 用 D 级的 sel_valid[0] 会晚一拍判错
            // ★ 频率刀 (2026-10-11, Cut B): 选择端用**打了一拍**的 ret_sample_q —— 原来的组合
            //   ret_sample 让 rob 指针 (head/last/free) 经 rob_empty 直接落在这条读口地址通路上
            //   (实测头名级 0~3 = 0.31 ns 全是 rob 指针 → rob_empty → ret_sample → 本 mux)。
            //   与锁存的 ret_sample_q 同拍 ⇒ 读口地址与 ret_val_r 采样仍然是同一个 map_arch[10]
            //   (停机后 fetch 冻结 ⇒ 无新 rename; 唯一可能的"残余批"必在 ROB 里才可能 rename ⇒
            //   rob_empty 期间 map_r 恒定) ⇒ 语义逐位不变, 只晚一拍。
            if (s == 0) begin : rd1mux
                assign rd1_preg[0 * PW +: PW] = sel_valid_q[0] ? slot_rd1 : (ret_sample_q ? map_arch[10 * PW +: PW] : {PW{1'b0}});
            end else begin : rd1plain
                assign rd1_preg[s * PW +: PW] = slot_rd1;
            end
            // div 发起是否被收下 (本槽拿到授权且除法器当拍空闲; 见上方 "div 发起仲裁")
            assign div_accept_w[s] = div_gnt_w[s] && div_go_w;
            // CDB 标签/有效别名 (与 exec_valid 同源; load 槽由模块内排除)
            assign cdb_slot_valid_w[s] = cdb_exec_valid[s];
            assign cdb_tag_w[s * PW +: PW] = cdb_exec_prd[s * PW +: PW];
            // misp 汇出链 (最老优先: 前缀 OR, 低槽赢; 门控折叠为 misp_sel ? x : 0)
            if (s == 0) begin : m0
                assign misp_any_c[0] = misp_det_w[0];
                assign redirect_c[0 * 32 +: 32] = misp_det_w[0] ? misp_red_w[0 * 32 +: 32] : 32'd0;
                assign misp_fs_c[0 * RW +: RW]  = misp_det_w[0] ? misp_fs_pay_w[0 * RW +: RW] : {RW{1'b0}};
                assign misp_ras_c[0 * RA +: RA] = misp_det_w[0] ? misp_ras_pay_w[0 * RA +: RA] : {RA{1'b0}};
            end else begin : mn
                assign misp_any_c[s] = misp_any_c[s - 1] | misp_det_w[s];
                assign redirect_c[s * 32 +: 32] = redirect_c[(s - 1) * 32 +: 32]
                    | ((misp_det_w[s] && !misp_any_c[s - 1]) ? misp_red_w[s * 32 +: 32] : 32'd0);
                assign misp_fs_c[s * RW +: RW]  = misp_fs_c[(s - 1) * RW +: RW]
                    | ((misp_det_w[s] && !misp_any_c[s - 1]) ? misp_fs_pay_w[s * RW +: RW] : {RW{1'b0}});
                assign misp_ras_c[s * RA +: RA] = misp_ras_c[(s - 1) * RA +: RA]
                    | ((misp_det_w[s] && !misp_any_c[s - 1]) ? misp_ras_pay_w[s * RA +: RA] : {RA{1'b0}});
            end
            // 分支计数链段
            assign br_acc[(s + 1) * 3 +: 3] = br_acc[s * 3 +: 3] + br_inc_w[s];
        end
    endgenerate
    assign rt_clear_req = rt_clear_c[(ISSUE_WIDTH - 1) * PRF_SIZE +: PRF_SIZE];   // 末槽 chunk
    // load 完成槽 (CDB 槽 W): 有效 + 旁路标签
    assign cdb_slot_valid_w[ISSUE_WIDTH]   = load_cdb_valid;
    assign cdb_tag_w[ISSUE_WIDTH * PW +: PW] = load_cdb_prd;
    // old_map 链: 槽 s 的 old = "本批早于 s 的**最后一个同 rd 写者**产出的 preg, 无则取 RAT 当前映射"
    // 逐级 j 递增比较, 最后匹配者 (j 最大) 赢 —— 与 rat.v 读口的批内转发同规则 (读口 i 看 rename j<i)。
    // 旧实现只在"相邻槽同 rd"时前递, 否则回落到**前一槽的 old**, 那是**另一个 rd 的映射**:
    // W>=2 时任何相邻槽写不同 rd 的批都会把 old 记错 ⇒ 提交回收的是别人的 preg (提前回收,
    // 池内出现重复项 ⇒ 同一 preg 发给两条在飞指令, 后者的生产者标签对不上 ⇒ 依赖者永不就绪 ⇒
    // 死锁), 冲刷回滚也会把两个 rd 写成同一 preg ⇒ RAT 失去单射性。实测 W=2 时 gcd 在 59 拍就开始
    // 出现池内重复项 (preg 43/49/36), 最终卡在 0x111c 的 blt。W=1 无相邻槽 ⇒ 这条 bug 不可见。
    wire [ISSUE_WIDTH * ISSUE_WIDTH * PW - 1 : 0] omc_c;      // [s][j] 级联
    generate
        for (s = 0; s < ISSUE_WIDTH; s = s + 1) begin : omc
            assign omc_c[(s * ISSUE_WIDTH + 0) * PW +: PW] =
                   ((s != 0) && d_writes_rd[0] && (d_rd[0 * 5 +: 5] == d_rd[s * 5 +: 5]))
                   ? alloc_val[0 * PW +: PW] : map_arch[d_rd[s * 5 +: 5] * PW +: PW];
            for (j = 1; j < ISSUE_WIDTH; j = j + 1) begin : fwd
                assign omc_c[(s * ISSUE_WIDTH + j) * PW +: PW] =
                       ((j < s) && d_writes_rd[j] && (d_rd[j * 5 +: 5] == d_rd[s * 5 +: 5]))
                       ? alloc_val[j * PW +: PW] : omc_c[(s * ISSUE_WIDTH + j - 1) * PW +: PW];
            end
            assign old_map_chain[s * PW +: PW] =
                   omc_c[(s * ISSUE_WIDTH + ISSUE_WIDTH - 1) * PW +: PW];
        end
    endgenerate
    assign mem_cnt_chain[0 * 3 +: 3]    = 3'd0;
    generate
        for (mm = 0; mm < ISSUE_WIDTH; mm = mm + 1) begin : isschain
            assign mem_cnt_chain[(mm + 1) * 3 +: 3] = mem_cnt_chain[mm * 3 +: 3]
 + (f2i_valid[mm] && (d_is_load[mm] || d_is_store[mm]));
        end
    endgenerate

    // ---- 冲刷动作 (B4): rob 截断 + fetch 重定向 + ras 恢复 (bht 更新在 slt 内) ----
    // 冲刷中只接受"更老"的新误预测: 否则会按更新的条目截断 rob, 把 walker 正在回滚的窗口重新撑大
    // (那些错路条目不再被 walker 回滚, 却留在窗口内 → 可能被提交)
    assign set_last_valid = misp_valid && (!flushing_r || misp_older_w);
    // +1: rob 的 last 是"空槽位"语义, 存活窗口是 [head, last) ⇒ set_last = fs 会把误预测的那条
    // 自己也丢掉。而误预测只说明"它后面取的那串是错路", 它本身是必须提交的有效指令 ——
    // 丢了它, jalr 写 rd 的副作用就没了 (官方题集用 jalr ra,off(ra) 做调用 ⇒ 返回地址丢失 ⇒ 死循环),
    // 且它占的 preg 永远不回池 (free_list 逐次漏干 → 死锁, 见 docs/plan.md §15)。
    // 与 RS/LSQ 失效掩码 (`> fs` 严格大于, 即"只废比它新的") 口径一致。
    assign set_last_val   = misp_fs_w + 1'b1;

    // ==================== 4. flush 窗口 (rs/lsq 失效, 年龄 > fs) ====================
    // 掩码只用"已注册"的冲刷状态 (flushing_r/flush_fs_r), 不可用当拍 misp_valid/fs_eff_w:
    //   sel → misp_det → misp_valid → fs_eff(= 误预测分支 rob_tag) → mask → cand → sel
    //   是零延迟组合环 (misp 撤销瞬间 fs_eff 落到 0 → 掩码反把误预测条目自己杀掉 → 振荡)。
    // 误预测拍因此不失效条目: W=1 时该拍选中的正是误预测分支本身, 错路条目本就不会被选中;
    // walker 拍 (flushing_r=1) 掩码生效, 在 walker 的 posedge 清条目 (最少 1 拍, 不增停顿)。
    wire flush_sel = flushing_r;
    wire [RW - 1 : 0] fs_sel = flush_fs_r;
    generate
        for (e = 0; e < RS_SIZE; e = e + 1) begin : rsfm
            assign rs_flush_mask[e] = flush_sel && rs_entry_valid[e]
                && ((rs_entry_rob_tag[e * RW +: RW] - rob_head_w) > (fs_sel - rob_head_w));
        end
        for (e = 0; e < LSQ_SIZE; e = e + 1) begin : lsqfm
            assign lsq_flush_mask[e] = flush_sel && lsq_valid_w[e]
                && ((lsq_rob_tag_w[e * RW +: RW] - rob_head_w) > (fs_sel - rob_head_w));
        end
    endgenerate

    // ==================== 4b. 在飞 div 的作废判据 ====================
    // 与上面 rs/lsq 掩码严格同口径 ("年龄 > 生效冲刷点" ⇒ 错路), 但**每拍评估**而不是只在 walker 拍:
    // 误预测当拍该 div 就已在飞 (乱序: 更老的误预测分支后执行), 拖到 walker 拍才杀会多浪费 1 拍,
    // 且 walker 可能只走一拍 —— 那时掩码对"已不在 rs 里"的在飞 div 已无从下手。
    // age 用 (tag - rob_head) 自然回绕比较: 在飞 div 必然未提交 (READY 未置), 故 age ∈ [0, ROB_SIZE)。
    // 被杀的 div 不产生 done_valid, 也永远不会写 PRF/置 ready ⇒ 年龄比较不会越界。
    assign div_kill = (misp_valid || flushing_r)
                   && ((div_fly_rob_tag - rob_head_w) > (fs_eff_w - rob_head_w));

    // ==================== 5. 提交 (B6) ====================
    // ---- 提交级读口: **one-hot + AND-OR** (原为 `rob_xxx_w[eidx * W +: W]`) ----
    // 索引读综合出 32 选 1 的 mux 树, 索引**最低位落在最宽的一级**:
    // 扇出 = 16 × (7 + 1 + PW + PW + LW + 32) = 16 × 56 = 896 (实测 900)。
    // 官方 abc 无 `-constr` ⇒ 不做 buffer/upsize (§15.10.8), 那一级实测 4.67 ns = 关键路径的 23%。
    // 改成: 先把 6 个字段按条目**重排**成 cmt_ent[ge][CTW] (纯连线, 不产生门),
    // 再把 eidx 译成 one-hot 后逐位 AND-OR ⇒ 每条 one-hot 只驱动 CTW 个 AND, 峰值扇出 896 → 56。
    // 面积持平 (mux ≈ 2 门/位/级 vs AND2 + OR2 ≈ 2 门), 深度 31 级 → ~9 级。
    // 注: 不能只把 mux 换成 one-hot 就完事 —— 它选出的 cmt_lsq 又当下游 LSQ 读口的索引,
    //     原样传下去等于把 16 × 66 = 1056 的扇出留在原地; 故 LSQ 三个读口同样 one-hot 化 (见下)。
    localparam CTW = 7 + 1 + PW + PW + LW + 32;      // 提交级要读的 ROB 字段合计位宽
    // 各字段在打包总线里的起始位 (逐行累加, 行尾注释即该字段宽度; 与下面拼接顺序一一对应)
    localparam CO_CK  = 0;                           // : 7
    localparam CO_RDY = CO_CK  + 7;                  // : 1
    localparam CO_NEW = CO_RDY + 1;                  // : PW
    localparam CO_OLD = CO_NEW + PW;                 // : PW
    localparam CO_LSQ = CO_OLD + PW;                 // : LW
    localparam CO_RAW = CO_LSQ + LW;                 // : 32
    wire [ROB_SIZE * CTW - 1 : 0] cmt_ent;
    genvar gc, gb;
    generate
        for (gc = 0; gc < ROB_SIZE; gc = gc + 1) begin : cpack
            assign cmt_ent[gc * CTW +: CTW] = {
                rob_raw_w[gc * 32 +: 32], rob_lsq_w[gc * LW +: LW],
                rob_old_w[gc * PW +: PW], rob_new_w[gc * PW +: PW],
                rob_ready_w[gc], rob_opcode_w[gc * 7 +: 7] };
        end
    endgenerate

    wire [ISSUE_WIDTH - 1 : 0] ce_w, is_store_w, is_memop_w, cmt_push_v, marker_acc;
    // 提交槽是否**在 ROB 占用窗口内**: 占用量 = ROB_SIZE - free_count (rob.v 的 empty/full 也用它,
    // 满/空不靠 head==last 区分)。槽 c 的索引是 head + c, 只有 c < 占用量时该条目才存在。
    // 缺这一项时 c>=1 的槽会越过 last 提交"窗口外"的自由槽 —— 它的 ready 位是上一位租客的残留,
    // 于是 head 越过 last ⇒ 占用量算成负 ⇒ **empty (free==ROB_SIZE) 永不成立** ⇒ 提交逻辑空转
    // (实测 W=2: head 绕着整圈反复提交同一批陈旧槽, 停机锁存 ret_latched_r 永不置位)。
    // W=1 无 c>=1 的槽 ⇒ 这条 bug 在 W=1 不可见。占用量当拍口径: free_r 是本拍提交前的值, 与
    // "本拍提交在时钟沿发生"一致。
    localparam [RCW - 1 : 0] ROB_FULL = ROB_SIZE;
    wire [RCW - 1 : 0] rob_occ = ROB_FULL - rob_free_w;
    wire [ISSUE_WIDTH * PW - 1 : 0] cmt_push_p;
    wire [ISSUE_WIDTH * 32 - 1 : 0] sw_addr_c, sw_data_c;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  sw_width_c;
    generate
        for (c = 0; c < ISSUE_WIDTH; c = c + 1) begin : cmt
            localparam [RCW - 1 : 0] CMT_OFF = c;      // 槽序号 (位宽对齐, 免隐式截断)
            wire cmt_in_win = (CMT_OFF < rob_occ);
            wire [RW - 1 : 0] eidx = rob_head_w + c;                    // 回绕
            // 本槽的 ROB 字段取: one-hot 译码 eidx → 逐位 AND-OR (置换了原来 6 处 `rob_xxx_w[eidx * W +: W]`)
            wire [ROB_SIZE - 1 : 0] cmt_oh;
            wire [CTW - 1 : 0] cmt_sel;
            for (gc = 0; gc < ROB_SIZE; gc = gc + 1) begin : cod
                assign cmt_oh[gc] = (eidx == gc[RW - 1 : 0]);
            end
            for (gb = 0; gb < CTW; gb = gb + 1) begin : cor
                wire [ROB_SIZE - 1 : 0] m;
                for (gc = 0; gc < ROB_SIZE; gc = gc + 1) begin : e
                    assign m[gc] = cmt_ent[gc * CTW + gb] & cmt_oh[gc];
                end
                assign cmt_sel[gb] = |m;
            end
            wire [6 : 0]      cmt_opc = cmt_sel[CO_CK  +: 7];
            wire              cmt_rdy = cmt_sel[CO_RDY];
            wire [PW - 1 : 0] cmt_new = cmt_sel[CO_NEW +: PW];
            wire [PW - 1 : 0] cmt_old = cmt_sel[CO_OLD +: PW];
            wire [LW - 1 : 0] cmt_lsq = cmt_sel[CO_LSQ +: LW];
            wire [31 : 0]     cmt_raw = cmt_sel[CO_RAW +: 32];
            assign is_store_w[c] = (cmt_opc == 7'h23);
            assign is_memop_w[c] = (cmt_opc == 7'h03) || is_store_w[c];
            // store 提交需下游队列有空位 (sw_ready=0 ⇒ 该槽不提交, 整批到此截断, 不产生任何副作用);
            // store 截断批 ⇒ 一批至多一个 store ⇒ 这条门控等价于"整批是否被压住"
            wire sw_ok_w = sw_ready || !is_store_w[c];
            if (c == 0) begin : ce0
                // misp 拍禁提交: rob 内 set_last 优先于 set_head (head 不前进), 但提交副作用
                // (free_list 回收 / RAT arch / 计数) 已发生 → 同一条目会再提交一次, free_list 出重
                assign ce_w[0] = !flushing_r && !misp_valid && cmt_in_win && cmt_rdy
                                 && sw_ok_w;      // c==0: cmt_in_win ≡ !rob_empty (占用量 >= 1)
            end else begin : cen
                assign ce_w[c] = ce_w[c - 1] && !is_store_w[c - 1] && cmt_in_win && cmt_rdy
                                 && sw_ok_w;      // store 截断批; cmt_in_win 见上方说明
            end
            assign com_acc[(c + 1) * 3 +: 3] = com_acc[c * 3 +: 3] + ce_w[c];
            // free_list 回收: new_pnum!=0 才 push old_pnum
            assign cmt_push_v[c] = ce_w[c] && (cmt_new != 0);
            assign cmt_push_p[c * PW +: PW] = cmt_old;
            // memop 提交 → lsq 条目失效
            wire [LW - 1 : 0] cmt_lsq_tag = cmt_lsq;
            // one-hot 掩码链 (iverilog: 连续赋值 LHS 位选择须常量索引)
            wire [LSQ_SIZE - 1 : 0] inv_one = (ce_w[c] && is_memop_w[c])
 ? ({{(LSQ_SIZE - 1){1'b0}}, 1'b1} << cmt_lsq_tag) : {LSQ_SIZE{1'b0}};
            if (c == 0) begin : ic0
                assign inv_c[0 * LSQ_SIZE +: LSQ_SIZE] = inv_one;
            end else begin : icn
                assign inv_c[c * LSQ_SIZE +: LSQ_SIZE] = inv_c[(c - 1) * LSQ_SIZE +: LSQ_SIZE] | inv_one;
            end
            // store 直写 (≤1/批: 截断保证; OR-reduce 链)
            // LSQ 三个读口同样 one-hot + AND-OR: 索引 cmt_lsq 直接落到 16 选 1 mux 的最宽一级
            // ⇒ 扇出 = 8 × (32 + 32 + 2) = 528。把"是否本拍提交的 store"折进 one-hot 里,
            // 未提交时全 0 ⇒ OR 结果天然为 0, 与原 `? : 32'd0` 等价且省掉末级 mux。
            wire lsq_rd_en = ce_w[c] && is_store_w[c];
            wire [LSQ_SIZE - 1 : 0] lsq_oh;
            for (gc = 0; gc < LSQ_SIZE; gc = gc + 1) begin : lod
                assign lsq_oh[gc] = lsq_rd_en && (cmt_lsq == gc[LW - 1 : 0]);
            end
            wire [31 : 0] sw_a, sw_d;
            wire [1 : 0]  sw_w;
            for (gb = 0; gb < 32; gb = gb + 1) begin : lor
                wire [LSQ_SIZE - 1 : 0] ma, md;
                for (gc = 0; gc < LSQ_SIZE; gc = gc + 1) begin : e
                    wire [31 : 0] ent_a = lsq_addr_w[gc * 32 +: 32];
                    wire [31 : 0] ent_d = lsq_data_w[gc * 32 +: 32];
                    assign ma[gc] = ent_a[gb] & lsq_oh[gc];
                    assign md[gc] = ent_d[gb] & lsq_oh[gc];
                end
                assign sw_a[gb] = |ma;
                assign sw_d[gb] = |md;
            end
            for (gb = 0; gb < 2; gb = gb + 1) begin : loww
                wire [LSQ_SIZE - 1 : 0] mw;
                for (gc = 0; gc < LSQ_SIZE; gc = gc + 1) begin : e
                    wire [1 : 0] ent_w = lsq_width_w[gc * 2 +: 2];
                    assign mw[gc] = ent_w[gb] & lsq_oh[gc];
                end
                assign sw_w[gb] = |mw;
            end
            if (c == 0) begin : sw0
                assign sw_addr_c[0 * 32 +: 32]  = sw_a;
                assign sw_data_c[0 * 32 +: 32]  = sw_d;
                assign sw_width_c[0 * 2 +: 2]   = sw_w;
            end else begin : swn
                assign sw_addr_c[c * 32 +: 32]  = sw_addr_c[(c - 1) * 32 +: 32] | sw_a;
                assign sw_data_c[c * 32 +: 32]  = sw_data_c[(c - 1) * 32 +: 32] | sw_d;
                assign sw_width_c[c * 2 +: 2]   = sw_width_c[(c - 1) * 2 +: 2] | sw_w;
            end
            assign marker_acc[c] = ce_w[c] && ((cmt_raw == TERM_RAW) || (cmt_raw == TERM_RAW2));
        end
    endgenerate
    assign lsq_invalidate_c = inv_c[(ISSUE_WIDTH - 1) * LSQ_SIZE +: LSQ_SIZE];   // 末槽 chunk (链只写到 W-1)
    assign set_head_valid = (n_commit > 0);
    assign set_head_val   = rob_head_w + n_commit;
    assign sw_valid = |(ce_w & is_store_w);
    assign sw_addr  = sw_addr_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign sw_data  = sw_data_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign sw_width = sw_width_c[(ISSUE_WIDTH - 1) * 2 +: 2];
    wire marker_commit = |marker_acc;
    // free_list push 端口复用: walker | commit (互斥: flushing 期间 commit 冻结)
    // commit 侧只有 ISSUE_WIDTH 项 ⇒ 零扩展到 ROLLBACK_WIDTH (高位 push_ok 恒 0, 不写池)
    assign fl_push_valid = flushing_r ? walked_valid
                                      : {{(ROLLBACK_WIDTH - ISSUE_WIDTH){1'b0}}, cmt_push_v};
    assign fl_push_preg  = flushing_r ? wlk_push_preg
                                      : {{(ROLLBACK_WIDTH - ISSUE_WIDTH) * PW{1'b0}}, cmt_push_p};

    // ==================== 6. 时序 (walker FSM / halt / ret_val / 计数器) ====================
    always @(posedge clk) begin
        if (!rst_n) begin
            flushing_r <= 1'b0;
            flush_fs_r <= {RW{1'b0}};
            walk_ptr_r <= {RW{1'b0}};
        end else if (misp_valid && !flushing_r) begin
            flushing_r <= 1'b1;
            flush_fs_r <= misp_fs_w;
            walk_ptr_r <= rob_last_w - 1'b1;   // 最年轻的有效条目 (last 是空槽位, 不可回滚)
        end else if (flushing_r) begin
            // 中途新误预测: 更老才扩范围 (walk_ptr 照常递减, 防重复回滚)
            if (misp_valid && misp_older_w) flush_fs_r <= misp_fs_w;
            walk_ptr_r <= walk_ptr_r - ROLLBACK_WIDTH;   // 回绕
            if (walk_done) flushing_r <= 1'b0;
        end
    end

    // ---- halt / ret_val 锁存 ----
    // 官方停机: 向 MMIO 0x80000000 做一次 32 位 store。sw_width==2'b10 ⇔ wstrb==4'hf,
    // 与从机判据 (sim.cpp:91-92) 一致。sw_valid 已由 sw_ready 门控 (见第 5 节) ⇒ 该 store
    // 必已被 store 队列收下, 一定会发上总线; 写别的地址/别的宽度都只是普通写, 不停机。
    // 手写程序走的 TERM marker 与本路径 OR 并存: 0x80000000 远超 TB 的 MEM_SIZE, 不会误命中。
    wire mmio_exit = sw_valid && sw_ready && (sw_addr == MMIO_EXIT_ADDR) && (sw_width == 2'b10);
    assign ret_sample = halt_q_r && rob_empty && !ret_latched_r;
    // ★ 频率刀 (2026-10-11, Cut B): ret_sample 打一拍。它是头名 (rob 指针 → div 寄存器, 5.4051 ns)
    //   的级 3~4 —— 组合的 ret_sample 直接把 rob 指针牵进读口地址 mux。打拍后 rob 指针只驱动
    //   本寄存器的 D 脚, 读口地址选择端换成 FF 输出 ⇒ 头名级 0~3 整段拿掉。
    //   同一拍喂两处 (本锁存 + cpu_top 的 rd1mux), 两处必须同用 ret_sample_q, 否则读到槽 0 的旧地址。
    //   (声明在"每槽胶水"之前 —— 那里的读口 mux 先用它, 见其处注释。)
    always @(posedge clk) begin
        if (!rst_n) begin
            halt_q_r <= 1'b0;
            ret_latched_r <= 1'b0;
            ret_val_r <= 8'd0;
            ret_sample_q <= 1'b0;
        end else begin
            if (marker_commit || mmio_exit) halt_q_r <= 1'b1;
            ret_sample_q <= ret_sample;
            if (ret_sample_q) begin
                ret_latched_r <= 1'b1;
                ret_val_r <= prf_d1[0 * 32 +: 32] & 8'hFF;
            end
        end
    end

    // ---- 性能统计 (窗口 = 程序本身, 不含 halt 之后的 ROB 排空) ----
    // halt 后 fetch 冻结但**提交不停**: ret_sample 要等 rob_empty (见上方 halt 锁存),
    // 故 halt 标记之后的条目会继续提交。若照常累加, "已提交指令数"就多出 ≤ ROB_SIZE 条,
    // 且多出的部分随 halt 时刻的 ROB 占用浮动 —— 实测 naive 真值 18 条被记成 27 条,
    // 而 27 = 18 + 9 (halt 标记后方 rob 内的条目数)。
    // 故三个计数器一律在 halt 抬起后冻结, 与 TB 侧 STALL/JUMP 的采样窗口
    // (tb_cpu_prog.v: rst_n && !dut.halt_q_r) 对齐, 使 PASS 行与 STALL/JUMP 行同窗口。
    // 注意: halt_q_r 在 halt 标记**提交的那一拍**仍为 0, 故标记本身计入 (naive 的 18 含它)。
    reg [31 : 0] commit_count_r, flush_count_r, branch_count_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            commit_count_r <= 32'd0;
            flush_count_r <= 32'd0;
            branch_count_r <= 32'd0;
        end else if (!halt_q_r) begin
            commit_count_r <= commit_count_r + {29'd0, n_commit};
            flush_count_r <= flush_count_r + {31'd0, misp_valid};
            branch_count_r <= branch_count_r + {29'd0, n_branch};
        end
    end

    // ---- 调试输出 / fetch 控制 ----
    assign halt = halt_q_r;
    assign ret_val = ret_val_r;
    assign commit_count = commit_count_r;
    assign flush_count = flush_count_r;
    assign branch_count = branch_count_r;
    assign rob_head = rob_head_w;
    assign rob_ready_head = rob_ready_w[rob_head_w];
    // ★ 与 issue_en 同删 halt_q_r (锥 ② 频率刀, 见上文 issue_en 处的整段说明): 留着它反而制造
    //   死循环 —— stall 恒 1 ⇒ fetch 的 batch_taken 恒 0 ⇒ f2i_valid_r 永不清 ⇒ have_batch 常 1
    //   ⇒ 同一批被反复发射。halt 对取指的冻结已由 fetch 的 .halt() 单独承担 (cap_w/pc_next 都含它),
    //   本项是冗余的。
    assign fetch_stall = (have_batch && !issue_en) || flushing_r;
endmodule
