// 多周期除法器: radix-2 恢复余数迭代, 32 次迭代 + 1 拍输出 = **33 拍**延迟
// 支持 RV32M 的 DIV/DIVU/REM/REMU (start_op: 0=div 1=divu 2=rem 3=remu, 即 func3[1:0])
//
// 【为何多周期】32 级借位链叠在本已由华莱士树主导的执行级路径上会跌破 300MHz 硬性前提
// (mul 自身 F2F 实测 2.0879 ns, 500MHz 档已超预算; 见 docs/plan.md §13.5)。迭代式把
// 每拍深度压到"33 位比较 + 33 位加减 + 移位", 不进关键路径。
//
// 【握手】
//   * start_valid && !busy 当拍被收下 (锁存 op/a/b/prd/rob_tag), busy 随即抬起
//   * busy 期间 start_valid 被忽略 —— 上层靠"不释放 RS 条目"防重复发射 (见 cpu_top 的 rs_clear 门控)
//   * 收下后**恰好**过 33 拍出 done_valid (1 拍脉冲), 同拍 done_prd/done_rob_tag/done_result 有效
//   * kill 只作用于**在飞**的那一发: 当拍清 busy 且不产生 done_valid。
//     ⚠ 空闲时 kill 不得压掉同拍的新 start —— 那条指令的 RS 条目已被上层清掉,
//       漏收即永久不被执行 ⇒ 死锁。故判据写成 `kill && busy_r`。
//
// 【算法】取 |a|/|b| 做无符号恢复余数迭代, 商/余按符号修正
//   R 恒 < |b| (恢复余数的循环不变式) ⇒ R 只用 32 位; Rs = {R, A[31]} 33 位才需比较/相减。
//   每拍: Rs = {R, A[31]}; 若 Rs >= |b| 则 R <= Rs-|b| 且商位 1, 否则 R <= Rs 且商位 0。
//   符号修正: q = (a_neg ^ b_neg) ? -|q| : |q|;  r = a_neg ? -|r| : |r|  (截断除法, 向零取整)
//   ⇒ 角例天然正确: INT_MIN/-1 的 |q| = 2^31 按有符号解释恰为 INT_MIN, 余数 0。
//   ⇒ 除零: 迭代会给出全 1 商 (Rs>=0 恒真), 但余数语义要显式 mux: b==0 → 商全 1, 余 = 被除数。
//
// 注: 本实现取**恢复余数**而非非恢复余数 —— 非恢复的 R ∈ (-|b|, |b|), 移位后需 34 位有符号
// 中间量, 且末尾要补一次修正; 恢复式 R ∈ [0, |b|) 只要 33 位无符号, 无修正步, 面积更小。
//
// 复位异步低有效 (ASAP7 r28 无同步复位触发器)
module div #(
    parameter PRF_SIZE = 64,
    parameter ROB_SIZE = 32
) (
    input  clk,
    input  rst_n,
    // ---- 发起 (上层保证 busy 期间不再拉起 start_valid) ----
    input                             start_valid,
    input  [1 : 0]                    start_op,
    input  [31 : 0]                   start_a,
    input  [31 : 0]                   start_b,
    input  [$clog2(PRF_SIZE) - 1 : 0] start_prd,
    input  [$clog2(ROB_SIZE) - 1 : 0] start_rob_tag,
    // ---- 作废在飞的那一发 (误预测冲刷; 见 cpu_top 的 div_kill) ----
    input                             kill,
    // ---- 状态 / 结果 ----
    output                            busy,
    output [$clog2(ROB_SIZE) - 1 : 0] busy_rob_tag,   // 在飞那发的 rob_tag (上层算 kill 判据用;
                                                      // 发起时其 RS 条目已释放, 无别的副本)
    output                            done_valid,
    output [$clog2(PRF_SIZE) - 1 : 0] done_prd,
    output [$clog2(ROB_SIZE) - 1 : 0] done_rob_tag,
    output [31 : 0]                   done_result
);
    localparam PW = $clog2(PRF_SIZE);
    localparam RW = $clog2(ROB_SIZE);

    reg               busy_r, done_r;
    reg  [5 : 0]      cnt_r;                       // 剩余迭代次数 (32 → 1)
    reg  [31 : 0]     a_r, b_r;                    // 原始操作数 (除零 mux 与符号修正用)
    reg  [31 : 0]     a_sh_r;                      // 被除数移位寄存器 (初值 |a|)
    reg  [31 : 0]     b_abs_r;                     // |b|
    reg  [31 : 0]     q_r, r_r;                    // 商 / 余 (绝对值)
    reg  [1 : 0]      op_r;
    reg               a_neg_r, b_neg_r;
    reg  [PW - 1 : 0] prd_r;
    reg  [RW - 1 : 0] rob_r;

    // 发起拍: 由 op 决定是否按有符号取模 (divu/remu 的 op[0]=1)
    wire          is_uns_w = start_op[0];
    wire          a_neg_w  = start_a[31] && !is_uns_w;
    wire          b_neg_w  = start_b[31] && !is_uns_w;
    wire [31 : 0] a_abs_w  = a_neg_w ? (~start_a + 32'd1) : start_a;
    wire [31 : 0] b_abs_w  = b_neg_w ? (~start_b + 32'd1) : start_b;

    // 一次迭代的组合部分: Rs = {R, A[31]}, 够减则减并置商位
    // 取 33 位是教科书形式 (R<<1 后可达 2|b|), 不依赖任何附加不变量; 面积代价仅 1 位。
    wire [32 : 0] rs_w    = {r_r, a_sh_r[31]};
    wire [32 : 0] b_ext_w = {1'b0, b_abs_r};
    wire [32 : 0] d_w     = rs_w - b_ext_w;
    wire          ge_w    = (rs_w >= b_ext_w);
    // 减法结果恒 < |b| ⇒ 32 位足够; 不减法时 Rs 就是结果本身
    wire [31 : 0] r_nx_w  = ge_w ? d_w[31 : 0] : rs_w[31 : 0];
    wire [31 : 0] q_nx_w  = {q_r[30 : 0], ge_w};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r <= 1'b0;  done_r <= 1'b0;  cnt_r <= 6'd0;
            a_r <= 32'd0;    b_r <= 32'd0;    a_sh_r <= 32'd0;  b_abs_r <= 32'd0;
            q_r <= 32'd0;    r_r <= 32'd0;    op_r <= 2'd0;
            a_neg_r <= 1'b0; b_neg_r <= 1'b0;
            prd_r <= {PW{1'b0}};  rob_r <= {RW{1'b0}};
        end else begin
            done_r <= 1'b0;                        // 1 拍脉冲: 默认落
            if (kill && busy_r) begin               // 只杀在飞的那发 (空闲时不得吞掉新 start)
                busy_r <= 1'b0;
            end else if (!busy_r) begin
                if (start_valid) begin
                    busy_r  <= 1'b1;
                    cnt_r   <= 6'd32;
                    a_r     <= start_a;
                    b_r     <= start_b;
                    a_sh_r  <= a_abs_w;
                    b_abs_r <= b_abs_w;
                    q_r     <= 32'd0;
                    r_r     <= 32'd0;
                    op_r    <= start_op;
                    a_neg_r <= a_neg_w;
                    b_neg_r <= b_neg_w;
                    prd_r   <= start_prd;
                    rob_r   <= start_rob_tag;
                end
            end else begin
                a_sh_r <= {a_sh_r[30 : 0], 1'b0};
                q_r    <= q_nx_w;
                r_r    <= r_nx_w;                  // 末次迭代与 done_r 同拍生效 ⇒ 输出已定型
                if (cnt_r == 6'd1) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    cnt_r <= cnt_r - 1'b1;
                end
            end
        end
    end

    // 结果: 符号修正 + 除零 mux (op[1] 选商/余, op[0] 选有无符号)
    wire          b_zero_w = (b_r == 32'd0);
    wire          is_rem_w = op_r[1];
    wire [31 : 0] q_fix_w  = (a_neg_r ^ b_neg_r) ? (~q_r + 32'd1) : q_r;
    wire [31 : 0] r_fix_w  = a_neg_r ? (~r_r + 32'd1) : r_r;

    assign busy         = busy_r;
    assign busy_rob_tag = rob_r;
    assign done_valid   = done_r;
    assign done_prd     = prd_r;
    assign done_rob_tag = rob_r;
    assign done_result  = is_rem_w ? (b_zero_w ? a_r : r_fix_w)
                                   : (b_zero_w ? 32'hFFFF_FFFF : q_fix_w);
endmodule
