// 顶层: RV32IM 乱序多发射 Tomasulo CPU 总流水线
// 三阶段结构 (与 C++ 参考 tick() 同构): 读端口 → 组合 assign → posedge 锁存
//   + **执行级再切一刀** (§15.10.13): execute_slot 内分 D 级(字段取 one-hot+AND-OR) /
//     Q 级(操作数获取 + alu/branch + CDB), 中间一个 144+1 位寄存器。rs 仲裁仍在 D 级当拍
//     出 sel_idx, 只是它下游的字段取与执行晚一拍; 配套的 rs_clear/flush/div 扣住规则见该文件头
// 组合块: B2 发射(全批 or 不批) B5 walker 回滚(组合部分) B6 提交(连续就绪, store≤1)
//         B1 操作数获取(CDB 旁路)/B3 执行分发/B4 误预测检测 → verilog/exec/execute_slot.v (Q 级)
//         误预测汇出链(最老优先)与 fetch 重定向/rob 截断/ras 恢复在此
// 多周期除法: div 槽只发起 (载荷取槽 0), 33 拍后由 div.v 经 CDB 槽 W+1 写回; 在飞条目靠
//         pipe_stall 扣住流水寄存器 (没被收下就不能清条目), 错路靠 div_kill 作废 —— 两者都是死锁/写坏
//         空闲 preg 的关口, 见各自 assign 处注释
module cpu_top #(
    parameter ISSUE_WIDTH  = 1,
    parameter ROB_SIZE     = 32,
    parameter RS_SIZE      = 16,
    parameter PRF_SIZE     = 64,
    parameter LSQ_SIZE     = 16,
    parameter BHT_SIZE     = 32,
    parameter RAS_SIZE     = 8
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
    wire [(ISSUE_WIDTH + 1) * PW - 1 : 0]  old_map_chain;
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0]   mem_cnt_chain;
    reg                            halt_q_r, ret_latched_r;
    reg  [7 : 0]                     ret_val_r;
    wire                           ret_sample;
    wire [RW - 1 : 0]                  misp_fs_w;
    wire [(ISSUE_WIDTH + 1) * PRF_SIZE - 1 : 0] rt_clear_c;   // one-hot 掩码累加链 (rename clear)
    wire [(ISSUE_WIDTH + 1) * PRF_SIZE - 1 : 0] flclr_c;      // one-hot 掩码累加链 (walker flush clear)
    wire [(ISSUE_WIDTH + 1) * LSQ_SIZE - 1 : 0] inv_c;        // one-hot 掩码累加链 (commit invalidate)
    // execute_slot 输出 (每槽) + misp 汇出链 (最老优先前缀 OR)
    wire [ISSUE_WIDTH - 1 : 0]        misp_det_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0]   misp_red_w;
    wire [ISSUE_WIDTH * RW - 1 : 0]   misp_fs_pay_w;
    wire [ISSUE_WIDTH * RA - 1 : 0]   misp_ras_pay_w;
    wire [ISSUE_WIDTH - 1 : 0]        br_inc_w;
    wire [ISSUE_WIDTH : 0]            misp_any_c;   // misp_det 前缀 OR (段值在 slt 内)
    // div 发起 (载荷取槽 0 位段; 段值/门控在 slt 内, 实例在下方)
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
        .inst_data(inst_data), .imem_valid(imem_valid), .imem_hit(imem_hit), .stall(fetch_stall),
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
    wire [ISSUE_WIDTH * PW - 1 : 0] map_out1, map_out2, alloc_val, walk_flush_old;
    wire [32 * PW - 1 : 0]          map_arch;
    wire [PCW - 1 : 0]            fl_count;
    wire [ISSUE_WIDTH - 1 : 0]    rename_valid, walk_flush_valid;
    wire [ISSUE_WIDTH * 5 - 1 : 0]  walk_flush_rd;
    wire [ISSUE_WIDTH - 1 : 0]    fl_push_valid;
    wire [ISSUE_WIDTH * PW - 1 : 0] fl_push_preg;
    rat #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE)) u_rat (
        .clk(clk), .rst_n(rst_n),
        .map_out1(map_out1), .map_out2(map_out2), .map_arch(map_arch),
        .read_rs1(d_rs1), .read_rs2(d_rs2),
        .rename_valid(rename_valid), .rename_rd(d_rd), .rename_new(alloc_val),
        .flush_valid(walk_flush_valid), .flush_rd(walk_flush_rd), .flush_old(walk_flush_old)
    );
    free_list #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE)) u_fl (
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
    wire [ISSUE_WIDTH - 1 : 0]    div_accept_w;   // div 发起被收下 (只有槽 0 可能为 1)
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
        .clk(clk), .rst_n(rst_n),
        .data_out1(prf_d1), .data_out2(prf_d2),
        .rd1_preg(rd1_preg), .rd2_preg(rd2_preg),
        .wr_valid(cdb_prf_valid), .wr_preg(cdb_prf_preg), .wr_data(cdb_prf_data)
    );
    wire [ISSUE_WIDTH - 1 : 0]    cdb_exec_valid;
    wire [ISSUE_WIDTH - 1 : 0]    cdb_exec_rob_wr = {ISSUE_WIDTH{1'b1}};   // 恒 1: 执行完成即置 ROB ready
    wire [ISSUE_WIDTH * PW - 1 : 0] cdb_exec_prd;
    wire [ISSUE_WIDTH * 32 - 1 : 0] cdb_exec_result;
    wire [ISSUE_WIDTH * RW - 1 : 0] cdb_exec_rob_tag;
    wire load_cdb_valid;
    wire [PW - 1 : 0]   load_cdb_prd;
    wire [31 : 0]     load_cdb_result;
    wire [RW - 1 : 0]   load_cdb_rob_tag;
    wire            load_cdb_rob_wr;
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

    // ---- div: 多周期除法器 (33 拍), 完成经 CDB 槽 W+1 ----
    // 只有槽 0 能启动 (仲裁见 div_go_w 处) ⇒ 载荷取槽 0 位段。
    // 没被收下时由本槽的 pipe_stall 扣住流水寄存器 (下一拍重发), 条目与发起严格一一对应 (丢 = 死锁)。
    assign div_op_w  = div_op_all[0 +: 2];
    assign div_a_w   = div_a_all[0 +: 32];
    assign div_b_w   = div_b_all[0 +: 32];
    assign div_prd_w = div_prd_all[0 +: PW];
    assign div_rob_w = div_rob_all[0 +: RW];
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
    wire [LSQ_SIZE - 1 : 0] lsq_flush_mask, lsq_invalidate;
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
        .mem_done_valid(ld_done_valid), .mem_done_idx(ld_done_idx), .mem_done_data(ld_done_data),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx), .ld_busy(ld_busy),
        .load_cdb_valid(load_cdb_valid), .load_cdb_prd(load_cdb_prd),
        .load_cdb_result(load_cdb_result), .load_cdb_rob_tag(load_cdb_rob_tag),
        .load_cdb_rob_wr(load_cdb_rob_wr)
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
    assign walk_done = flushing_r && (rem_w <= ISSUE_WIDTH);
    wire [ISSUE_WIDTH * RW - 1 : 0] walk_idx_w;
    wire [ISSUE_WIDTH - 1 : 0]    walked_valid;
    wire [ISSUE_WIDTH * PW - 1 : 0] wlk_push_preg;
    generate
        for (jj = 0; jj < ISSUE_WIDTH; jj = jj + 1) begin : walk
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
    assign rt_flush_clear_req = flclr_c[(ISSUE_WIDTH - 1) * PRF_SIZE +: PRF_SIZE];

    // ---- 计数链 (前缀累加; 段值在 slt/cmt generate 内生成) ----
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0] wr_acc, mem_acc, sel_acc, br_acc, com_acc;
    wire [2 : 0] n_wr, n_mem, n_commit, n_branch, sel_cnt;
    assign wr_acc[0 * 3 +: 3]  = 3'd0;
    assign mem_acc[0 * 3 +: 3] = 3'd0;
    assign sel_acc[0 * 3 +: 3] = 3'd0;
    assign br_acc[0 * 3 +: 3]  = 3'd0;
    assign com_acc[0 * 3 +: 3] = 3'd0;
    assign n_wr     = wr_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_mem    = mem_acc[ISSUE_WIDTH * 3 +: 3];
    assign sel_cnt  = sel_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_branch = br_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_commit = com_acc[ISSUE_WIDTH * 3 +: 3];

    // ---- 发射条件 (全批 or 不批; misp 周期抑制见约束 1) ----
    // halt 后不得再发射: fetch 冻结 → have_batch 常 1, 若不门控会把同一批反复压入 rob/rs (死循环)
    // lsq_free_w 已是"本拍可 push 数"(内部已含本拍失效腾出的槽), 此处不再另加本拍失效数
    // rs 项同样必须用"真空闲槽数": rs.v 的 push 分配器只认 !valid_r, 看不到本拍 clear,
    // 若把本拍选中数 sel_cnt 也算作可用, 会放行一次注定被 rs.v 丢弃的 push
    // (指令入 rob 却无 rs 条目 → 永不执行 → 依赖链死锁; 详见 docs/plan.md §7.4)
    wire have_batch = |f2i_valid;
    wire resources_ok = !rob_full && (rs_free_w >= ISSUE_WIDTH)
                     && (fl_count >= n_wr) && (lsq_free_w >= n_mem);
    wire issue_en = have_batch && !misp_valid && !flushing_r && !halt_q_r && resources_ok;

    // ---- 误预测汇出 (B4) ----
    wire [ISSUE_WIDTH * 32 - 1 : 0] redirect_c;
    wire [ISSUE_WIDTH * RW - 1 : 0] misp_fs_c;
    wire [ISSUE_WIDTH * RA - 1 : 0] misp_ras_c;
    assign misp_valid = |misp_det_w;
    assign redirect_pc_w = redirect_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign misp_fs_w     = misp_fs_c[(ISSUE_WIDTH - 1) * RW +: RW];
    assign misp_ras_w    = misp_ras_c[(ISSUE_WIDTH - 1) * RA +: RA];

    // ---- div 发起仲裁 (W>1: 只有槽 0 能启动) ----
    // 只让槽 0 启动是安全的: rs.v 的 W 级年龄仲裁是**稠密前缀** (第 k 级能选出候选 ⇒ 第 k-1 级
    // 必然也选出了), 所以槽 0 每拍都在推进 (启动或扣住后重选) ⇒ 高槽的 div 必然在有限拍内移到槽 0。
    // 忙时/冲刷中一律不启动: 忙时启动会丢这一发 (其 RS 条目已清) ⇒ 死锁;
    // 冲刷中启动则可能让错路 div 逃过 kill —— rs 失效掩码只在 walker 拍生效, 而 walker 可能当拍就走完。
    assign div_go_w = div_req_w[0] && !div_busy && !flushing_r;

    // ---- 每槽胶水 ----
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
            assign rob_push_valid[s] = issue_en;
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
            assign sel_acc[(s + 1) * 3 +: 3] = sel_acc[s * 3 +: 3] + sel_valid[s];
            // old_map 链段值 (批内同 rd 前递; 存于 old_map_chain; 末槽只读不求值, 防位段越界)
            if (s < ISSUE_WIDTH - 1) begin : omc
                assign old_map_chain[(s + 1) * PW +: PW] = (d_writes_rd[s] && (d_rd[s * 5 +: 5] == d_rd[(s + 1) * 5 +: 5]))
 ? alloc_val[s * PW +: PW] : old_map_chain[s * PW +: PW];
            end

            // ===== execute_slot 实例 (B3 字段取 / B1 旁路 / alu+branch / CDB 广播 / 访存 / B4 检测) =====
            wire [PW - 1 : 0] slot_rd1;
            execute_slot #(.ISSUE_WIDTH(ISSUE_WIDTH), .RS_SIZE(RS_SIZE), .PRF_SIZE(PRF_SIZE),
                           .LSQ_SIZE(LSQ_SIZE), .ROB_SIZE(ROB_SIZE), .RAS_SIZE(RAS_SIZE),
                           .BHT_SIZE(BHT_SIZE), .SLOT_ID(s)) u_slot (
                .clk(clk), .rst_n(rst_n),
                .flush_win(flushing_r), .flush_hit(misp_valid), .div_accept(div_accept_w[s]),
                .sel_valid(sel_valid[s]), .sel_idx(sel_idx[s * SRW +: SRW]),
                .rs_entry_opcode(rs_entry_opcode), .rs_entry_func3(rs_entry_func3), .rs_entry_func7(rs_entry_func7),
                .rs_entry_prs1(rs_entry_prs1), .rs_entry_prs2(rs_entry_prs2), .rs_entry_prd(rs_entry_prd),
                .rs_entry_pc(rs_entry_pc), .rs_entry_imm(rs_entry_imm),
                .rs_entry_lsq_tag(rs_entry_lsq_tag), .rs_entry_rob_tag(rs_entry_rob_tag),
                .rs_entry_pred_taken(rs_entry_pred_taken), .rs_entry_pred_target(rs_entry_pred_target),
                .rs_entry_ras_snap(rs_entry_ras_snap),
                .rt_ready(rt_ready_w), .prf_d1(prf_d1[s * 32 +: 32]), .prf_d2(prf_d2[s * 32 +: 32]),
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
            if (s == 0) begin : rd1mux
                assign rd1_preg[0 * PW +: PW] = sel_valid_q[0] ? slot_rd1 : (ret_sample ? map_arch[10 * PW +: PW] : {PW{1'b0}});
            end else begin : rd1plain
                assign rd1_preg[s * PW +: PW] = slot_rd1;
            end
            // div 发起是否被收下 (只有槽 0 能启动, 见上方 div_go_w)
            assign div_accept_w[s] = (s == 0) && div_go_w;
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
    // old_map 链初值 + mem_cnt_chain 链 (声明在顶部; 段值在 slt 内生成)
    assign old_map_chain[0 * PW +: PW] = map_arch[d_rd[0 * 5 +: 5] * PW +: PW];
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
    wire [ISSUE_WIDTH * PW - 1 : 0] cmt_push_p;
    wire [ISSUE_WIDTH * 32 - 1 : 0] sw_addr_c, sw_data_c;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  sw_width_c;
    generate
        for (c = 0; c < ISSUE_WIDTH; c = c + 1) begin : cmt
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
                assign ce_w[0] = !flushing_r && !misp_valid && !rob_empty && cmt_rdy
                                 && sw_ok_w;
            end else begin : cen
                assign ce_w[c] = ce_w[c - 1] && !is_store_w[c - 1] && cmt_rdy  // store 截断批
                                 && sw_ok_w;
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
    assign lsq_invalidate = inv_c[(ISSUE_WIDTH - 1) * LSQ_SIZE +: LSQ_SIZE];   // 末槽 chunk (链只写到 W-1)
    assign set_head_valid = (n_commit > 0);
    assign set_head_val   = rob_head_w + n_commit;
    assign sw_valid = |(ce_w & is_store_w);
    assign sw_addr  = sw_addr_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign sw_data  = sw_data_c[(ISSUE_WIDTH - 1) * 32 +: 32];
    assign sw_width = sw_width_c[(ISSUE_WIDTH - 1) * 2 +: 2];
    wire marker_commit = |marker_acc;
    // free_list push 端口复用: walker | commit (互斥: flushing 期间 commit 冻结)
    assign fl_push_valid = flushing_r ? walked_valid : cmt_push_v;
    assign fl_push_preg  = flushing_r ? wlk_push_preg : cmt_push_p;

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
            walk_ptr_r <= walk_ptr_r - ISSUE_WIDTH;   // 回绕
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
    always @(posedge clk) begin
        if (!rst_n) begin
            halt_q_r <= 1'b0;
            ret_latched_r <= 1'b0;
            ret_val_r <= 8'd0;
        end else begin
            if (marker_commit || mmio_exit) halt_q_r <= 1'b1;
            if (ret_sample) begin
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
    assign fetch_stall = (have_batch && !issue_en) || flushing_r || halt_q_r;
endmodule
