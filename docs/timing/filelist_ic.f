# RTL 源文件列表 —— 路径相对本文件所在目录 (verilog/)
# 顶层模块必须命名为 student_top (见 scripts/build.py 的 --top-module)
#
# 现状 (2026-09-24): student_top (AXI4-Lite 包层) 已落地, 官方 `make build` 可跑通。
#
# **与 verilog/filelist.f 的唯一差异**: 本表**不收** core/memory.v。
# 那是仅供 TB 的固定 1 拍存储 (寄存器组), student_top 不例化它 —— 在 filelist.f 里
# 靠 hierarchy -top 剪掉; 本表直接不列, 消除"它没被剪干净、被当成内存计入面积"的风险。
# 官方 `make synth` 与 `tools/run.sh` 用本表时被测对象即纯 AXI 通路, 内存面积只来自
# sram_fakeram (icache / dcache 阵列)。
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
core/icache.v
core/dcache.v
core/mem_subsystem.v

# --- top ---
top/cpu_top.v
top/student_top.v
