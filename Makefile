# ============================================================
# 仿真 Makefile (iverilog + vvp + surfer)
#
# 目录约定:
#   * RTL        : rtl/<子系统>/<模块>.v  (Verilog-2005, 可仿真可综合)
#   * testbench  : tb/<子系统>/tb_<模块>.v (模块名必须与文件名一致)
#   * 产物/波形   : sim/<子系统>/tb_<模块>.vvp / .vcd (镜像 tb 目录)
#   * 自动发现    : 新增 rtl/tb 文件无需修改本 Makefile
#   * 失败检测    : tb 失败路径调 $stop; 本 Makefile 以 "vvp -N" 运行,
#                   -N 使 $stop 相当于 $finish 且退出码为 1
#                   ($finish(n) 的参数只是诊断级别, 不改变退出码, 勿用)
#
# 目标:
#   make                    编译并运行全部 testbench
#   make run TB=exec/tb_x   只运行单个
#   make sim/exec/tb_x.vvp  仅编译单个
#   make wave TB=exec/tb_x  运行单个并打开 surfer 波形
#   make clean              删除 sim/
# ============================================================
SIM := sim
IV  ?= iverilog
VP  ?= vvp

SRCS := $(wildcard rtl/*.v) $(wildcard rtl/*/*.v)
TBS  := $(wildcard tb/*.v)  $(wildcard tb/*/*.v)
VVPS := $(patsubst tb/%.v,$(SIM)/%.vvp,$(TBS))

TB ?= exec/tb_adder32

.PHONY: all run wave clean synth

all: run

# 编译单个 testbench; -s 固定顶模块, 避免多个未实例化模块时选错根
$(SIM)/%.vvp: tb/%.v $(SRCS)
	@mkdir -p $(dir $@)
	$(IV) -g2005 -s $(basename $(notdir $@)) -o $@ $^

# 运行全部 (或单个: make run TB=exec/tb_x); vvp -N 使失败 tb 退出码为 1。
# $(origin TB) 区分用户显式传参 (command line) 与默认值, 否则 make 永远只跑默认单个
run: $(VVPS)
	@if test "$(origin TB)" = "command line"; then \
		$(VP) -N $(SIM)/$(TB).vvp; \
	else \
		for t in $(VVPS); do \
			echo "== $$t"; \
			$(VP) -N $$t || exit 1; \
		done; \
	fi

# 编译(如需) + 运行 + 打开波形
wave: $(VVPS)
	$(VP) -N $(SIM)/$(TB).vvp
	surfer $(SIM)/$(TB).vcd

clean:
	rm -rf $(SIM) synth/out

# ============================================================
# 综合 (YoSys + ASAP7 7nm 标准单元库, RVT+TT)
#   make synth        综合乘法器 mul → synth/out/mul_stat.txt + mul_net.v
#   make synth-cpu    全核综合       → synth/out/cpu_stat.txt + cpu_net.v
#   asap7_comb.lib: SIMPLE+INVBUF+AO+OA 四库合并 (abc 映射组合逻辑用;
#                    时序单元 DFF 由 dfflibmap 按 SEQ 库单独映射,
#                    见 synth/mul.ys / synth/cpu.ys 注释)
# ============================================================
YS      ?= yosys
SYNTH   := synth/out
NLDM    ?= /Users/audience/opt/asap7sc7p5t_27/LIB/NLDM
COMBLIB := $(SYNTH)/asap7_comb.lib

$(COMBLIB): synth/merge_liberty.py \
		$(NLDM)/asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib \
		$(NLDM)/asap7sc7p5t_INVBUF_RVT_TT_nldm_201020.lib \
		$(NLDM)/asap7sc7p5t_AO_RVT_TT_nldm_201020.lib \
		$(NLDM)/asap7sc7p5t_OA_RVT_TT_nldm_201020.lib
	@mkdir -p $(SYNTH)
	python3 synth/merge_liberty.py $@ $^

$(SYNTH)/mul_stat.txt: synth/mul.ys $(COMBLIB) rtl/exec/mul.v rtl/exec/adder32.v
	@mkdir -p $(SYNTH)
	$(YS) -ql $(SYNTH)/mul_synth.log synth/mul.ys
	grep -E "Chip area|Number of cells" $(SYNTH)/mul_synth.log > $@
	@cat $@

$(SYNTH)/cpu_stat.txt: synth/cpu.ys $(COMBLIB) \
		$(NLDM)/asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib \
		$(wildcard rtl/top/*.v rtl/front/*.v rtl/core/*.v rtl/exec/*.v)
	@mkdir -p $(SYNTH)
	$(YS) -ql $(SYNTH)/cpu_synth.log synth/cpu.ys
	grep -E "Chip area|Number of cells" $(SYNTH)/cpu_synth.log > $@
	@cat $@

synth: $(SYNTH)/mul_stat.txt
synth-cpu: $(SYNTH)/cpu_stat.txt
