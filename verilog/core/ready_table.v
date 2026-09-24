// 就绪表: 物理寄存器就绪位 (CDB 写回置位 / rename 清零 / walker 回滚清零)
// 优先级: flush_clear > clear > set (同 preg 同拍 set+clear → clear 赢: 刚重命名的 preg 新值未就绪)
// 复位: 0..31 置 1 (RAT 恒等映射), 其余 0; preg 0 常就绪
module ready_table #(
    parameter PRF_SIZE = 64
) (
    input  clk,
    input  rst_n,
    output [PRF_SIZE - 1 : 0] ready,
    input  [PRF_SIZE - 1 : 0] set_req,          // CDB 写回
    input  [PRF_SIZE - 1 : 0] clear_req,        // rename
    input  [PRF_SIZE - 1 : 0] flush_clear_req   // walker
);
    reg [PRF_SIZE - 1 : 0] ready_r;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ready_r <= {{(PRF_SIZE - 32){1'b0}}, 32'hFFFFFFFF};   // 0..31 恒等映射就绪
        else begin
            for (i = 0; i < PRF_SIZE; i = i + 1) begin
                if (i == 0)
                    ready_r[i] <= 1'b1;                          // preg 0 常就绪
                else if (flush_clear_req[i])
                    ready_r[i] <= 1'b0;
                else if (clear_req[i])
                    ready_r[i] <= 1'b0;
                else if (set_req[i])
                    ready_r[i] <= 1'b1;
            end
        end
    end

    assign ready = ready_r;
endmodule
