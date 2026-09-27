# RTL 源文件列表 —— 路径相对本文件所在目录 (verilog/)
# 顶层模块必须命名为 student_top (见 scripts/build.py 的 --top-module)
#
# 现状 (2026-09-24): student_top (AXI4-Lite 包层) 已落地, 官方 `make build` 可跑通。
# core/memory.v 保留在列表里供 TB 复用: student_top 不再例化它, Yosys 的
# hierarchy -top 会剪掉, Verilator 按可达性展开 ⇒ 不影响综合与仿真。
#
# 顺序: 叶子在前 (exec → front → core → top), 与 synth/cpu.ys 的读入顺序一致。

# --- exec (无参数) ---
exec/adder32.v
exec/mul.v
exec/div.v
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
core/axi_lite_master.v
core/mem_subsystem.v

# --- top ---
top/cpu_top.v
top/student_top.v
