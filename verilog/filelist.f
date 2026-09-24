# RTL 源文件列表 —— 路径相对本文件所在目录 (verilog/)
# 顶层模块必须命名为 student_top (见 scripts/build.py 的 --top-module)
#
# 现状 (2026-09-24): 顶层仍是 cpu_top (仅 clk/rst_n + 调试口), 官方要求的
# student_top + AXI4-Lite 包层尚未落地 ⇒ 官方 `make build` 暂时跑不通,
# 属已知过渡态, 见 docs/plan.md 的「Phase C — 官方框架对接」。
#
# 顺序: 叶子在前 (exec → front → core → top), 与 synth/cpu.ys 的读入顺序一致。

# --- exec (无参数) ---
exec/adder32.v
exec/mul.v
exec/alu.v
exec/branch.v
exec/execute_slot.v

# --- front ---
front/decode.v
front/bht.v
front/ras.v
front/fetch.v

# --- core ---
core/rat.v
core/free_list.v
core/rob.v
core/rs.v
core/ready_table.v
core/prf.v
core/lsq.v
core/cdb.v
core/memory.v

# --- top ---
top/cpu_top.v
