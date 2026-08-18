// 顶层: RV32IM 乱序多发射 Tomasulo CPU 总流水线 (胶水全部在此, 无新增模块)
// 三阶段结构 (与 C++ 参考 tick() 同构): 读端口 → 组合 assign → posedge 锁存
// 组合块: B1 操作数获取(CDB 旁路) B2 发射(全批 or 不批) B3 执行槽分发
//         B4 误预测检测(最老优先) B5 walker 回滚(组合部分) B6 提交(连续就绪, store≤1)
// 关键时序约束:
//  - misp 周期抑制 issue (错路批会落在 walker 捕获的 walk_ptr 之外 → RAT/preg 泄漏)
//  - flushing 期间: issue 抑制 + fetch stall + commit 冻结
//  - rob 内部写优先级 set_last > set_head > set_ready > push (push 清该条目 ready)
//  - walker 回滚与 rat flush 同 posedge; free_list push 端口 walker|commit 复用 (flushing 判互斥)
//  - 终止标记 TERM_RAW 提交 → halt 锁存; ROB 排空后经槽 0 读口采样 ret_val
module cpu_top #(
    parameter ISSUE_WIDTH  = 1,
    parameter ROB_SIZE     = 32,
    parameter RS_SIZE      = 16,
    parameter PRF_SIZE     = 64,
    parameter LSQ_SIZE     = 16,
    parameter BHT_SIZE     = 32,
    parameter RAS_SIZE     = 8,
    parameter MEM_SIZE     = 65536,
    parameter MEM_LATENCY  = 3,
    parameter MEM_INFLIGHT = 4,
    parameter INIT_FILE    = ""
) (
    input  clk,
    input  rst_n,
    output halt,
    output [7 : 0]       ret_val,
    output [31 : 0]      commit_count, flush_count, branch_count,
    output [$clog2(ROB_SIZE) - 1 : 0] rob_head,
    output             rob_ready_head
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
    localparam TERM_RAW = 32'h0FF06093;   // ori x0, x0, 255

    // ---- 预声明 (iverilog: 实例端口表达式与 generate 内引用须先声明) ----
    wire [RA - 1 : 0]                  misp_ras_w;
    wire [PRF_SIZE - 1 : 0]            rt_ready_w;
    wire [(ISSUE_WIDTH + 1) * PW - 1 : 0]  cdb_tag_w;
    wire [ISSUE_WIDTH : 0]           cdb_slot_valid_w;
    wire [ROB_SIZE - 1 : 0]            rob_ready_set_w;
    wire                           sw_valid;
    wire [31 : 0]                    sw_addr, sw_data;
    wire [1 : 0]                     sw_width;
    wire [(ISSUE_WIDTH + 1) * PW - 1 : 0]  omacc;
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0]   macc;
    reg                            halt_q_r, ret_latched_r;
    reg  [7 : 0]                     ret_val_r;
    wire                           ret_sample;
    wire [RW - 1 : 0]                  misp_fs_w;
    wire [(ISSUE_WIDTH + 1) * PRF_SIZE - 1 : 0] rt_clear_c;   // one-hot 掩码累加链 (rename clear)
    wire [(ISSUE_WIDTH + 1) * PRF_SIZE - 1 : 0] flclr_c;      // one-hot 掩码累加链 (walker flush clear)
    wire [(ISSUE_WIDTH + 1) * LSQ_SIZE - 1 : 0] inv_c;        // one-hot 掩码累加链 (commit invalidate)

    // ==================== 1. 实例化区 ====================

    // ---- fetch / decode ----
    wire [ISSUE_WIDTH - 1 : 0]    f2i_valid;
    wire [ISSUE_WIDTH * 32 - 1 : 0] f2i_raw, f2i_pc, f2i_pred_target, imem_addr_w, inst_data;
    wire [ISSUE_WIDTH - 1 : 0]    f2i_pred_taken;
    wire [ISSUE_WIDTH * RA - 1 : 0] f2i_ras_snap;
    wire fetch_stall;
    wire misp_valid;
    wire [31 : 0] redirect_pc_w;
    wire [ISSUE_WIDTH - 1 : 0]    upd_req_w;
    wire [ISSUE_WIDTH * BW - 1 : 0] upd_idx_w;
    wire [ISSUE_WIDTH - 1 : 0]    upd_taken_w;
    fetch #(.ISSUE_WIDTH(ISSUE_WIDTH), .BHT_SIZE(BHT_SIZE), .RAS_SIZE(RAS_SIZE)) u_fetch (
        .f2i_valid(f2i_valid), .f2i_raw(f2i_raw), .f2i_pc(f2i_pc),
        .f2i_pred_taken(f2i_pred_taken), .f2i_pred_target(f2i_pred_target),
        .f2i_ras_snap(f2i_ras_snap), .imem_addr(imem_addr_w),
        .bht_upd_req(upd_req_w), .bht_upd_idx(upd_idx_w), .bht_upd_taken(upd_taken_w),
        .ras_restore_valid(misp_valid), .ras_restore_head(misp_ras_w),
        .inst_data(inst_data), .stall(fetch_stall),
        .redirect_valid(misp_valid), .redirect_pc(redirect_pc_w), .halt(halt_q_r)
    );
    wire [ISSUE_WIDTH * 7 - 1 : 0]  d_opcode, d_func7;
    wire [ISSUE_WIDTH * 3 - 1 : 0]  d_func3;
    wire [ISSUE_WIDTH * 5 - 1 : 0]  d_rd, d_rs1, d_rs2;
    wire [ISSUE_WIDTH * 32 - 1 : 0] d_imm;
    wire [ISSUE_WIDTH - 1 : 0] d_is_alu, d_is_mul, d_is_load, d_is_store, d_is_branch,
                           d_is_jal, d_is_jalr, d_is_lui, d_is_auipc,
                           d_writes_rd, d_mem_unsigned;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  d_mem_width;
    decode #(.ISSUE_WIDTH(ISSUE_WIDTH)) u_decode (
        .raw(f2i_raw), .d_valid(f2i_valid),
        .opcode(d_opcode), .func3(d_func3), .func7(d_func7),
        .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2), .imm(d_imm),
        .is_alu(d_is_alu), .is_mul(d_is_mul), .is_load(d_is_load), .is_store(d_is_store),
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
        .map_out1(map_out1), .map_out2(map_out2), .map_arch(map_arch),
        .read_rs1(d_rs1), .read_rs2(d_rs2),
        .rename_valid(rename_valid), .rename_rd(d_rd), .rename_new(alloc_val),
        .flush_valid(walk_flush_valid), .flush_rd(walk_flush_rd), .flush_old(walk_flush_old)
    );
    free_list #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE)) u_fl (
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
    assign rs_clear_valid = sel_valid;
    assign rs_clear_idx   = sel_idx;

    // ---- ready_table / prf / cdb ----
    wire [PRF_SIZE - 1 : 0] rt_clear_req, rt_flush_clear_req;
    wire [PRF_SIZE - 1 : 0] rt_set_req_w;
    ready_table #(.PRF_SIZE(PRF_SIZE)) u_rt (
        .ready(rt_ready_w), .set_req(rt_set_req_w),
        .clear_req(rt_clear_req), .flush_clear_req(rt_flush_clear_req)
    );
    wire [ISSUE_WIDTH * 32 - 1 : 0] prf_d1, prf_d2;
    wire [ISSUE_WIDTH * PW - 1 : 0] rd1_preg, rd2_preg;
    wire [ISSUE_WIDTH : 0]          cdb_prf_valid;
    wire [(ISSUE_WIDTH + 1) * PW - 1 : 0] cdb_prf_preg;
    wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] cdb_prf_data;
    prf #(.ISSUE_WIDTH(ISSUE_WIDTH), .PRF_SIZE(PRF_SIZE)) u_prf (
        .data_out1(prf_d1), .data_out2(prf_d2),
        .rd1_preg(rd1_preg), .rd2_preg(rd2_preg),
        .wr_valid(cdb_prf_valid), .wr_preg(cdb_prf_preg), .wr_data(cdb_prf_data)
    );
    wire [ISSUE_WIDTH - 1 : 0]    cdb_exec_valid, cdb_exec_rob_wr;
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
        .prf_valid(cdb_prf_valid), .prf_preg(cdb_prf_preg), .prf_data(cdb_prf_data),
        .rt_set_req(rt_set_req_w), .rob_ready_req(rob_ready_set_w)
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
    wire ld_start_valid, ld_busy;
    wire [31 : 0] ld_start_addr;
    wire [1 : 0]  ld_start_width;
    wire [LW - 1 : 0] ld_start_idx;
    wire mem_done_valid;
    wire [LW - 1 : 0] mem_done_idx;
    wire [31 : 0] mem_done_data;
    lsq #(.ISSUE_WIDTH(ISSUE_WIDTH), .LSQ_SIZE(LSQ_SIZE), .PRF_SIZE(PRF_SIZE), .ROB_SIZE(ROB_SIZE)) u_lsq (
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
        .mem_done_valid(mem_done_valid), .mem_done_idx(mem_done_idx), .mem_done_data(mem_done_data),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx), .ld_busy(ld_busy),
        .load_cdb_valid(load_cdb_valid), .load_cdb_prd(load_cdb_prd),
        .load_cdb_result(load_cdb_result), .load_cdb_rob_tag(load_cdb_rob_tag),
        .load_cdb_rob_wr(load_cdb_rob_wr)
    );
    memory #(.ISSUE_WIDTH(ISSUE_WIDTH), .MEM_SIZE(MEM_SIZE), .MEM_LATENCY(MEM_LATENCY),
             .MEM_INFLIGHT(MEM_INFLIGHT), .LSQ_SIZE(LSQ_SIZE), .INIT_FILE(INIT_FILE)) u_mem (
        .inst_data(inst_data), .imem_addr(imem_addr_w),
        .ld_start_valid(ld_start_valid), .ld_start_addr(ld_start_addr),
        .ld_start_width(ld_start_width), .ld_start_idx(ld_start_idx),
        .ld_done_valid(mem_done_valid), .ld_done_idx(mem_done_idx), .ld_done_data(mem_done_data),
        .ld_busy(ld_busy),
        .sw_valid(sw_valid), .sw_addr(sw_addr), .sw_data(sw_data), .sw_width(sw_width),
        .init_valid(1'b0), .init_addr(32'd0), .init_data(8'd0)
    );

    // ==================== 2. B5 walker 状态与回滚组合 ====================
    genvar s, j, jj, mm, c, e;
    reg flushing_r;
    reg [RW - 1 : 0] flush_fs_r, walk_ptr_r;
    wire [RW - 1 : 0] fs_eff_w, rem_w;
    wire walk_done;
    // fs_eff = 当前生效冲刷点 (中途新误预测更老 → 取新); 无 flush 时组合为 misp_fs (=0), 由 flush_active 门控
    assign fs_eff_w = flushing_r ? ((misp_valid && ((misp_fs_w - rob_head_w) < (flush_fs_r - rob_head_w))) ? misp_fs_w : flush_fs_r)
 : misp_fs_w;
    assign rem_w    = walk_ptr_r - fs_eff_w;   // 待回滚条数 (fs+1..walk_ptr]
    assign walk_done = flushing_r && (rem_w <= ISSUE_WIDTH);
    wire [ISSUE_WIDTH * RW - 1 : 0] walk_idx_w;
    wire [ISSUE_WIDTH - 1 : 0]    walked_valid;
    wire [ISSUE_WIDTH * PW - 1 : 0] wlk_push_preg;
    generate
        for (jj = 0; jj < ISSUE_WIDTH; jj = jj + 1) begin : wlk
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
    assign rt_flush_clear_req = flclr_c[ISSUE_WIDTH * PRF_SIZE +: PRF_SIZE];

    // ---- 计数链 (前缀累加; 段值在 slt/cmt generate 内生成) ----
    wire [(ISSUE_WIDTH + 1) * 3 - 1 : 0] wr_acc, mem_acc, sel_acc, br_acc, com_acc, inv_acc;
    wire [2 : 0] n_wr, n_mem, n_commit, n_branch, n_inv, sel_cnt;
    assign wr_acc[0 * 3 +: 3]  = 3'd0;
    assign mem_acc[0 * 3 +: 3] = 3'd0;
    assign sel_acc[0 * 3 +: 3] = 3'd0;
    assign br_acc[0 * 3 +: 3]  = 3'd0;
    assign com_acc[0 * 3 +: 3] = 3'd0;
    assign inv_acc[0 * 3 +: 3] = 3'd0;
    assign n_wr     = wr_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_mem    = mem_acc[ISSUE_WIDTH * 3 +: 3];
    assign sel_cnt  = sel_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_branch = br_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_commit = com_acc[ISSUE_WIDTH * 3 +: 3];
    assign n_inv    = inv_acc[ISSUE_WIDTH * 3 +: 3];

    // ---- 发射条件 (全批 or 不批; misp 周期抑制见约束 1) ----
    wire have_batch = |f2i_valid;
    wire resources_ok = !rob_full && (rs_free_w + sel_cnt >= ISSUE_WIDTH)
                     && (fl_count >= n_wr) && (lsq_free_w + n_inv >= n_mem);
    wire issue_en = have_batch && !misp_valid && !flushing_r && resources_ok;

    // ---- 误预测汇出 (B4) ----
    wire [ISSUE_WIDTH - 1 : 0] misp_w, misp_sel_w;
    wire [ISSUE_WIDTH * 32 - 1 : 0] redirect_c;
    wire [ISSUE_WIDTH * RW - 1 : 0] misp_fs_c;
    wire [ISSUE_WIDTH * RA - 1 : 0] misp_ras_c;
    assign misp_valid = |misp_w;
    assign redirect_pc_w = redirect_c[ISSUE_WIDTH * 32 +: 32];
    assign misp_fs_w     = misp_fs_c[ISSUE_WIDTH * RW +: RW];
    assign misp_ras_w    = misp_ras_c[ISSUE_WIDTH * RA +: RA];

    // ---- 每槽胶水 ----
    generate
        for (s = 0; s < ISSUE_WIDTH; s = s + 1) begin : slt
            // ===== B2 发射: 每槽 push/rename 信号 =====
            wire ren_v = issue_en && d_writes_rd[s];
            wire memop = d_is_load[s] || d_is_store[s];
            wire [2 : 0] lsq_off = macc[s * 3 +: 3];   // 本槽前 memop 数 (lsq_tag 前缀)
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
            assign rob_push_old[s * PW +: PW]     = ren_v ? omacc[s * PW +: PW] : {PW{1'b0}};
            assign rob_push_lsq[s * LW +: LW]     = memop ? (lsq_last_w + 1 + lsq_off) : {LW{1'b0}};
            assign rob_push_raw[s * 32 +: 32]     = f2i_raw[s * 32 +: 32];
            assign rs_push_opcode[s * 7 +: 7]     = d_opcode[s * 7 +: 7];
            assign rs_push_func3[s * 3 +: 3]      = d_func3[s * 3 +: 3];
            assign rs_push_func7[s * 7 +: 7]      = d_func7[s * 7 +: 7];
            assign rs_push_prs1[s * PW +: PW]     = map_out1[s * PW +: PW];
            assign rs_push_prs2[s * PW +: PW]     = map_out2[s * PW +: PW];
            assign rs_push_prd[s * PW +: PW]      = ren_v ? alloc_val[s * PW +: PW] : {PW{1'b0}};
            assign rs_push_pc[s * 32 +: 32]       = f2i_pc[s * 32 +: 32];
            assign rs_push_imm[s * 32 +: 32]      = d_imm[s * 32 +: 32];
            assign rs_push_lsq_tag[s * LW +: LW]  = memop ? (lsq_last_w + 1 + lsq_off) : {LW{1'b0}};
            assign rs_push_rob_tag[s * RW +: RW]  = rob_last_w + 1 + s;
            assign rs_push_pred_taken[s]        = f2i_pred_taken[s];
            assign rs_push_pred_target[s * 32 +: 32] = f2i_pred_target[s * 32 +: 32];
            assign rs_push_ras_snap[s * RA +: RA]    = f2i_ras_snap[s * RA +: RA];
            assign lsq_push_valid[s]        = issue_en && memop;
            assign lsq_push_rob_tag[s * RW +: RW]   = rob_last_w + 1 + s;
            assign lsq_push_prs2_or_prd[s * PW +: PW] = d_is_load[s] ? alloc_val[s * PW +: PW] : map_out2[s * PW +: PW];
            assign lsq_push_width[s * 2 +: 2]        = d_mem_width[s * 2 +: 2];
            assign lsq_push_is_unsigned[s]         = d_mem_unsigned[s];
            assign lsq_push_is_load[s]             = d_is_load[s];
            // 计数链段值
            assign wr_acc[(s + 1) * 3 +: 3]  = wr_acc[s * 3 +: 3] + (f2i_valid[s] && d_writes_rd[s]);
            assign mem_acc[(s + 1) * 3 +: 3] = mem_acc[s * 3 +: 3] + (f2i_valid[s] && memop);
            assign sel_acc[(s + 1) * 3 +: 3] = sel_acc[s * 3 +: 3] + sel_valid[s];
            // old_map 链段值 (批内同 rd 前递; 存于 omacc; 末槽只读不求值, 防位段越界)
            if (s < ISSUE_WIDTH - 1) begin : omc
                assign omacc[(s + 1) * PW +: PW] = (d_writes_rd[s] && (d_rd[s * 5 +: 5] == d_rd[(s + 1) * 5 +: 5]))
 ? alloc_val[s * PW +: PW] : omacc[s * PW +: PW];
            end

            // ===== B3 执行槽字段: 按 sel_idx 取 RS 条目 =====
            wire [6 : 0] slot_opcode = rs_entry_opcode[sel_idx[s * SRW +: SRW] * 7 +: 7];
            wire [2 : 0] slot_func3  = rs_entry_func3[sel_idx[s * SRW +: SRW] * 3 +: 3];
            wire [6 : 0] slot_func7  = rs_entry_func7[sel_idx[s * SRW +: SRW] * 7 +: 7];
            wire [PW - 1 : 0] slot_prs1  = rs_entry_prs1[sel_idx[s * SRW +: SRW] * PW +: PW];
            wire [PW - 1 : 0] slot_prs2  = rs_entry_prs2[sel_idx[s * SRW +: SRW] * PW +: PW];
            wire [PW - 1 : 0] slot_prd   = rs_entry_prd[sel_idx[s * SRW +: SRW] * PW +: PW];
            wire [31 : 0] slot_pc     = rs_entry_pc[sel_idx[s * SRW +: SRW] * 32 +: 32];
            wire [31 : 0] slot_imm    = rs_entry_imm[sel_idx[s * SRW +: SRW] * 32 +: 32];
            wire [LW - 1 : 0] slot_lsq_tag = rs_entry_lsq_tag[sel_idx[s * SRW +: SRW] * LW +: LW];
            wire [RW - 1 : 0] slot_rob_tag = rs_entry_rob_tag[sel_idx[s * SRW +: SRW] * RW +: RW];
            wire slot_pred_taken  = rs_entry_pred_taken[sel_idx[s * SRW +: SRW]];
            wire [31 : 0] slot_pred_target = rs_entry_pred_target[sel_idx[s * SRW +: SRW] * 32 +: 32];
            wire [RA - 1 : 0] slot_ras_snap  = rs_entry_ras_snap[sel_idx[s * SRW +: SRW] * RA +: RA];

            wire slot_is_r     = (slot_opcode == 7'h33);
            wire slot_is_i     = (slot_opcode == 7'h13);
            wire slot_is_lui   = (slot_opcode == 7'h37);
            wire slot_is_auipc = (slot_opcode == 7'h17);
            wire slot_is_load  = (slot_opcode == 7'h03);
            wire slot_is_store = (slot_opcode == 7'h23);
            wire slot_is_branch = (slot_opcode == 7'h63);
            wire slot_is_jal   = (slot_opcode == 7'h6F);
            wire slot_is_jalr  = (slot_opcode == 7'h67);
            wire slot_is_mul   = slot_is_r && (slot_func7 == 7'h01);
            wire slot_is_ctrl  = slot_is_branch || slot_is_jal || slot_is_jalr;
            wire slot_is_mem   = slot_is_load || slot_is_store;

            // ===== B1 操作数获取 (CDB 旁路 + ready_table→PRF 索引读) =====
            // 旁路链: 遍历槽 j∈[0..W] (槽 W = load 完成), 至多一个匹配
            wire [(ISSUE_WIDTH + 1) * 32 - 1 : 0] byp1_acc, byp2_acc, byp1_c, byp2_c;
            wire [ISSUE_WIDTH : 0] m1, m2;
            wire m1_any = |m1, m2_any = |m2;
            for (j = 0; j <= ISSUE_WIDTH; j = j + 1) begin : byp
                    wire res1 = cdb_slot_valid_w[j] && (cdb_tag_w[j * PW +: PW] == slot_prs1);
                    wire res2 = cdb_slot_valid_w[j] && (cdb_tag_w[j * PW +: PW] == slot_prs2);
                    wire [31 : 0] resv = (j < ISSUE_WIDTH) ? cdb_exec_result[j * 32 +: 32] : load_cdb_result;
                    assign m1[j] = res1;
                    assign m2[j] = res2;
                    assign byp1_acc[j * 32 +: 32] = res1 ? resv : 32'd0;
                    assign byp2_acc[j * 32 +: 32] = res2 ? resv : 32'd0;
                    if (j == 0) begin : b0
                        assign byp1_c[0 * 32 +: 32] = byp1_acc[0 * 32 +: 32];
                        assign byp2_c[0 * 32 +: 32] = byp2_acc[0 * 32 +: 32];
                    end else begin : bn
                        assign byp1_c[j * 32 +: 32] = byp1_c[(j - 1) * 32 +: 32] | byp1_acc[j * 32 +: 32];
                        assign byp2_c[j * 32 +: 32] = byp2_c[(j - 1) * 32 +: 32] | byp2_acc[j * 32 +: 32];
                    end
                end
            wire [31 : 0] byp1 = byp1_c[ISSUE_WIDTH * 32 +: 32];
            wire [31 : 0] byp2 = byp2_c[ISSUE_WIDTH * 32 +: 32];
            // 注: prs==0 短路 0; 旁路优先; 否则 ready_table 命中读 PRF (索引读)
            wire [31 : 0] op1 = (slot_prs1 == 0) ? 32'd0 : (m1_any ? byp1 : (rt_ready_w[slot_prs1] ? prf_d1[s * 32 +: 32] : 32'd0));
            wire [31 : 0] op2 = (slot_prs2 == 0) ? 32'd0 : (m2_any ? byp2 : (rt_ready_w[slot_prs2] ? prf_d2[s * 32 +: 32] : 32'd0));
            // prf 读地址: 槽 0 复用为 ret_val 采样口 (rob 空时 sel_valid[0]==0)
            if (s == 0) begin : rd1mux
                assign rd1_preg[0 * PW +: PW] = sel_valid[0] ? slot_prs1 : (ret_sample ? map_arch[10 * PW +: PW] : {PW{1'b0}});
            end else begin : rd1plain
                assign rd1_preg[s * PW +: PW] = slot_prs1;
            end
            assign rd2_preg[s * PW +: PW] = slot_prs2;

            // ===== B3 执行: alu + branch =====
            wire [31 : 0] alu_a = slot_is_lui ? 32'd0 : (slot_is_auipc ? slot_pc : op1);
            wire [31 : 0] alu_b = (slot_is_lui || slot_is_auipc || slot_is_i || slot_is_mem) ? slot_imm : op2;
            // alu op 编码: 0=add 1=sub 2=sll 3=slt 4=sltu 5=xor 6=srl 7=sra 8=or 9=and 10..13=mul*
            wire [4 : 0] alu_op = slot_is_r ? (slot_is_mul
 ? (slot_func3 == 3'd0 ? 5'd10 : slot_func3 == 3'd1 ? 5'd11
 : slot_func3 == 3'd2 ? 5'd12 : 5'd13)
 : (slot_func3 == 3'd0 ? (slot_func7[5] ? 5'd1 : 5'd0)
 : slot_func3 == 3'd1 ? 5'd2 : slot_func3 == 3'd2 ? 5'd3
 : slot_func3 == 3'd3 ? 5'd4 : slot_func3 == 3'd4 ? 5'd5
 : slot_func3 == 3'd5 ? (slot_func7[5] ? 5'd7 : 5'd6)
 : slot_func3 == 3'd6 ? 5'd8 : 5'd9))
 : slot_is_i ? (slot_func3 == 3'd0 ? 5'd0 : slot_func3 == 3'd1 ? 5'd2
 : slot_func3 == 3'd2 ? 5'd3 : slot_func3 == 3'd3 ? 5'd4
 : slot_func3 == 3'd4 ? 5'd5 : slot_func3 == 3'd5 ? (slot_func7[5] ? 5'd7 : 5'd6)
 : slot_func3 == 3'd6 ? 5'd8 : 5'd9)
 : 5'd0;   // lui/auipc/load/store/NOP → add
            wire [31 : 0] alu_result;
            alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .result(alu_result));
            wire [1 : 0]  br_mode = slot_is_jal ? 2'd1 : (slot_is_jalr ? 2'd2 : 2'd0);
            wire br_taken;
            wire [31 : 0] br_link, br_target;
            branch u_br (.rs1(op1), .rs2(op2), .pc(slot_pc), .imm(slot_imm),
                         .mode(br_mode), .br_op(slot_func3), .taken(br_taken),
                         .target(br_target), .link(br_link));

            // ===== 执行广播 (CDB 生产者; load 槽排除: 其 prd 是"地址", 见约束 13) =====
            assign cdb_exec_valid[s]    = sel_valid[s] && !slot_is_load;
            assign cdb_exec_prd[s * PW +: PW]    = slot_prd;
            assign cdb_exec_result[s * 32 +: 32] = slot_is_ctrl ? br_link : alu_result;
            assign cdb_exec_rob_tag[s * RW +: RW] = slot_rob_tag;
            assign cdb_exec_rob_wr[s]    = 1'b1;
            assign cdb_slot_valid_w[s]   = cdb_exec_valid[s];
            assign cdb_tag_w[s * PW +: PW] = slot_prd;

            // ===== 访存: 地址 = alu 结果, store 数据 = rs2 =====
            assign set_addr_req[s]   = sel_valid[s] && slot_is_mem;
            assign set_addr_idx[s * LW +: LW] = slot_lsq_tag;
            assign set_addr_val[s * 32 +: 32] = alu_result;
            assign set_data_req[s]   = sel_valid[s] && slot_is_store;
            assign set_data_idx[s * LW +: LW] = slot_lsq_tag;
            assign set_data_val[s * 32 +: 32] = op2;

            // ===== B4 误预测检测 (最老 = 低槽优先) =====
            wire smisp = sel_valid[s] && ((slot_is_branch && (br_taken != slot_pred_taken))
                                        || (slot_is_jalr && (br_target != slot_pred_target)));
            assign misp_w[s] = smisp;
            if (s == 0) begin : msel0
                assign misp_sel_w[0] = smisp;
            end else begin : mseln
                assign misp_sel_w[s] = smisp && !(|misp_w[s - 1 : 0]);
            end
            // bht 更新 (仅条件分支, 实际方向)
            assign upd_req_w[s]   = sel_valid[s] && slot_is_branch;
            assign upd_idx_w[s * BW +: BW] = (slot_pc >> 2) % BHT_SIZE;
            assign upd_taken_w[s] = br_taken;
            // 计数链: 分支数
            assign br_acc[(s + 1) * 3 +: 3] = br_acc[s * 3 +: 3] + (sel_valid[s] && slot_is_branch);
            // 误预测汇出 (OR-reduce 链; misp_sel 单热)
            if (s == 0) begin : mr0
                assign redirect_c[0 * 32 +: 32] = smisp ? br_target : 32'd0;
                assign misp_fs_c[0 * RW +: RW]  = smisp ? slot_rob_tag : {RW{1'b0}};
                assign misp_ras_c[0 * RA +: RA] = smisp ? slot_ras_snap : {RA{1'b0}};
            end else begin : mrn
                assign redirect_c[s * 32 +: 32] = redirect_c[(s - 1) * 32 +: 32] | (misp_sel_w[s] ? br_target : 32'd0);
                assign misp_fs_c[s * RW +: RW]  = misp_fs_c[(s - 1) * RW +: RW] | (misp_sel_w[s] ? slot_rob_tag : {RW{1'b0}});
                assign misp_ras_c[s * RA +: RA] = misp_ras_c[(s - 1) * RA +: RA] | (misp_sel_w[s] ? slot_ras_snap : {RA{1'b0}});
            end
        end
    endgenerate
    assign rt_clear_req = rt_clear_c[ISSUE_WIDTH * PRF_SIZE +: PRF_SIZE];
    // load 完成槽 (CDB 槽 W): 有效 + 旁路标签
    assign cdb_slot_valid_w[ISSUE_WIDTH]   = load_cdb_valid;
    assign cdb_tag_w[ISSUE_WIDTH * PW +: PW] = load_cdb_prd;
    // old_map 链初值 + macc 链 (声明在顶部; 段值在 slt 内生成)
    assign omacc[0 * PW +: PW] = map_arch[d_rd[0 * 5 +: 5] * PW +: PW];
    assign macc[0 * 3 +: 3]    = 3'd0;
    generate
        for (mm = 0; mm < ISSUE_WIDTH; mm = mm + 1) begin : isschain
            assign macc[(mm + 1) * 3 +: 3] = macc[mm * 3 +: 3]
 + (f2i_valid[mm] && (d_is_load[mm] || d_is_store[mm]));
        end
    endgenerate

    // ---- 冲刷动作 (B4): rob 截断 + fetch 重定向 + ras 恢复 (bht 更新在 slt 内) ----
    assign set_last_valid = misp_valid;
    assign set_last_val   = misp_fs_w;

    // ==================== 4. flush 窗口 (rs/lsq 失效, 年龄 > fs) ====================
    wire flush_active = misp_valid || flushing_r;
    generate
        for (e = 0; e < RS_SIZE; e = e + 1) begin : rsfm
            assign rs_flush_mask[e] = flush_active && rs_entry_valid[e]
                && ((rs_entry_rob_tag[e * RW +: RW] - rob_head_w) > (fs_eff_w - rob_head_w));
        end
        for (e = 0; e < LSQ_SIZE; e = e + 1) begin : lsqfm
            assign lsq_flush_mask[e] = flush_active && lsq_valid_w[e]
                && ((lsq_rob_tag_w[e * RW +: RW] - rob_head_w) > (fs_eff_w - rob_head_w));
        end
    endgenerate

    // ==================== 5. 提交 (B6) ====================
    wire [ISSUE_WIDTH - 1 : 0] ce_w, is_store_w, is_memop_w, cmt_push_v, marker_acc;
    wire [ISSUE_WIDTH * PW - 1 : 0] cmt_push_p;
    wire [ISSUE_WIDTH * 32 - 1 : 0] sw_addr_c, sw_data_c;
    wire [ISSUE_WIDTH * 2 - 1 : 0]  sw_width_c;
    generate
        for (c = 0; c < ISSUE_WIDTH; c = c + 1) begin : cmt
            wire [RW - 1 : 0] eidx = rob_head_w + c;                    // 回绕
            assign is_store_w[c] = (rob_opcode_w[eidx * 7 +: 7] == 7'h23);
            assign is_memop_w[c] = (rob_opcode_w[eidx * 7 +: 7] == 7'h03) || is_store_w[c];
            if (c == 0) begin : ce0
                assign ce_w[0] = !flushing_r && !rob_empty && rob_ready_w[rob_head_w];
            end else begin : cen
                assign ce_w[c] = ce_w[c - 1] && !is_store_w[c - 1] && rob_ready_w[eidx];  // store 截断批
            end
            assign com_acc[(c + 1) * 3 +: 3] = com_acc[c * 3 +: 3] + ce_w[c];
            assign inv_acc[(c + 1) * 3 +: 3] = inv_acc[c * 3 +: 3] + (ce_w[c] && is_memop_w[c]);
            // free_list 回收: new_pnum!=0 才 push old_pnum
            assign cmt_push_v[c] = ce_w[c] && (rob_new_w[eidx * PW +: PW] != 0);
            assign cmt_push_p[c * PW +: PW] = rob_old_w[eidx * PW +: PW];
            // memop 提交 → lsq 条目失效
            wire [LW - 1 : 0] cmt_lsq_tag = rob_lsq_w[eidx * LW +: LW];
            // one-hot 掩码链 (iverilog: 连续赋值 LHS 位选择须常量索引)
            wire [LSQ_SIZE - 1 : 0] inv_one = (ce_w[c] && is_memop_w[c])
 ? ({{(LSQ_SIZE - 1){1'b0}}, 1'b1} << cmt_lsq_tag) : {LSQ_SIZE{1'b0}};
            if (c == 0) begin : ic0
                assign inv_c[0 * LSQ_SIZE +: LSQ_SIZE] = inv_one;
            end else begin : icn
                assign inv_c[c * LSQ_SIZE +: LSQ_SIZE] = inv_c[(c - 1) * LSQ_SIZE +: LSQ_SIZE] | inv_one;
            end
            // store 直写 (≤1/批: 截断保证; OR-reduce 链)
            wire [31 : 0] sw_a = (ce_w[c] && is_store_w[c]) ? lsq_addr_w[rob_lsq_w[eidx * LW +: LW] * 32 +: 32] : 32'd0;
            wire [31 : 0] sw_d = (ce_w[c] && is_store_w[c]) ? lsq_data_w[rob_lsq_w[eidx * LW +: LW] * 32 +: 32] : 32'd0;
            wire [1 : 0]  sw_w = (ce_w[c] && is_store_w[c]) ? lsq_width_w[rob_lsq_w[eidx * LW +: LW] * 2 +: 2] : 2'd0;
            if (c == 0) begin : sw0
                assign sw_addr_c[0 * 32 +: 32]  = sw_a;
                assign sw_data_c[0 * 32 +: 32]  = sw_d;
                assign sw_width_c[0 * 2 +: 2]   = sw_w;
            end else begin : swn
                assign sw_addr_c[c * 32 +: 32]  = sw_addr_c[(c - 1) * 32 +: 32] | sw_a;
                assign sw_data_c[c * 32 +: 32]  = sw_data_c[(c - 1) * 32 +: 32] | sw_d;
                assign sw_width_c[c * 2 +: 2]   = sw_width_c[(c - 1) * 2 +: 2] | sw_w;
            end
            assign marker_acc[c] = ce_w[c] && (rob_raw_w[eidx * 32 +: 32] == TERM_RAW);
        end
    endgenerate
    assign lsq_invalidate = inv_c[ISSUE_WIDTH * LSQ_SIZE +: LSQ_SIZE];
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
            walk_ptr_r <= rob_last_w;          // 从触发时 last 开始回滚
        end else if (flushing_r) begin
            // 中途新误预测: 更老才扩范围 (walk_ptr 照常递减, 防重复回滚)
            if (misp_valid && ((misp_fs_w - rob_head_w) < (flush_fs_r - rob_head_w))) flush_fs_r <= misp_fs_w;
            walk_ptr_r <= walk_ptr_r - ISSUE_WIDTH;   // 回绕
            if (walk_done) flushing_r <= 1'b0;
        end
    end

    // ---- halt / ret_val 锁存 ----
    assign ret_sample = halt_q_r && rob_empty && !ret_latched_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            halt_q_r <= 1'b0;
            ret_latched_r <= 1'b0;
            ret_val_r <= 8'd0;
        end else begin
            if (marker_commit) halt_q_r <= 1'b1;
            if (ret_sample) begin
                ret_latched_r <= 1'b1;
                ret_val_r <= prf_d1[0 * 32 +: 32] & 8'hFF;
            end
        end
    end

    // ---- 性能统计 ----
    reg [31 : 0] commit_count_r, flush_count_r, branch_count_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            commit_count_r <= 32'd0;
            flush_count_r <= 32'd0;
            branch_count_r <= 32'd0;
        end else begin
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
