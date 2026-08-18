// 就绪表: 物理寄存器就绪位 (CDB 写回置位 / rename 清零 / walker 回滚清零)
// 优先级: flush_clear > clear > set (同 preg 同拍 set+clear → clear 赢: 刚重命名的 preg 新值未就绪)
// 复位: 0..31 置 1 (RAT 恒等映射), 其余 0; preg 0 常就绪
module ready_table #(
    parameter PRF_SIZE = 64
) (
    output [PRF_SIZE - 1 : 0] ready,
    input  [PRF_SIZE - 1 : 0] set_req,          // CDB 写回
    input  [PRF_SIZE - 1 : 0] clear_req,        // rename
    input  [PRF_SIZE - 1 : 0] flush_clear_req   // walker
);
    // TODO(Phase B): reg 数组 + 优先级组合
    assign ready = {PRF_SIZE{1'b0}};
endmodule
