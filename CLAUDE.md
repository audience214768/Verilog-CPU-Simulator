## 尽可能的避免if 和 case而是使用“？”表达式，避免漏情况。但如果较为复杂用if和case保证清晰度是可以接受的。
## 使用verilog-2005版本，确保可以同时仿真、综合
## 乱序执行多发射CPU
## 可以参数化，比如多发射指令数、ROB、RS等数据结构的大小，具体到后端实现不需要参数化（比如加法器、乘法器的位数）
## 报告：架构设计探索，性能消融（不同参数下性能优化情况）
## 评测要求一律以 docs/description.md 为准 (该文件只能由用户手动修改; 计划/架构/分析文档随其更新):
##   面积 = Yosys+ABC+OpenSTA 综合到 ASAP7 7.5-track RVT TT 标准单元库 + FakeRAM 的 SRAM 估算面积
##     (sram_fakeram 的估算面积**计入**总面积; 禁止用寄存器组当内存);
##   IPC = Verilator 统计 = 动态指令数 / 运行周期数, 所有 testcases/perf_* 取**几何平均**;
##   频率 ≥300MHz 是**硬性前提** (400MHz +2 分, 500MHz +4 分); 外部 256MiB 统一内存 (冯·诺依曼);
##   三档要求"面积上限与最低 IPC 同时满足" (90/95/100 分):
##     (面积上限 µm², 最低 IPC) = (9000, 0.6000) / (18000, 0.8450) / (36000, 1.0985);
##     档位设计 "IPC ×1.3 ↔ 面积上限 ×2" 仅 2→3 档严格成立 (1→2 档 IPC 倍数是 1.4083);
##   IPC 测试点 = testcases/perf_* (submodule ACMClassCourse-2025/RISC-V-CPU-2026-Testcases);
##   内存: 外部 AXI4-Lite 从机 (0x00000000-0x0fffffff), 响应延迟 LATENCY 默认 **10 拍** (仅此一个口径);
##   ISA = RV32IM, 仅免除 CSR*/ECALL/EBREAK/FENCE/FENCE.I (**LB/LBU/LH/LHU 必须实现**);
##   顶层模块必须命名 student_top, reset **高有效** (初始化保持 5 拍);
##   终止 = 向 MMIO 0x80000000 做 32 位 store (WSTRB=4'hf), 退出值 = WDATA[31:0]
## 注意，需要实现乘法，采用2位booth编码+华莱士树
## 模块化目录: 
verilog/<域>/<模块>.v (top/front/core/exec), tb/<域>/tb_<模块>.v; 模块在域内平铺, 模块名=文件名
## 官方框架布局 (根目录 Makefile/scripts/ 属官方, 勿改):
##   verilog/filelist.f = RTL 源文件列表 (路径相对 verilog/), 新增/删除源文件必须同步;
##   config.mk 保持官方原样; 本机工具链路径写进 gitignore 的 config.local.mk,
##     用 make CONFIG=config.local.mk <target> 生效 (APPIMAGE 禁用以走 native 工具)
### 模块清单: 
top=cpu_top (现状) + student_top (官方要求的顶层, AXI4-Lite 端口, 待实现); front=fetch,decode,bht,ras;
core=rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory; exec=adder32,mul,alu,branch
### 参考: 
/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator
这是我用C++仿照verilog编写的CPU，已经通过了正确性测试，在编写时可以参考;并且其中含有测试数据的源程序.c以及汇编代码.dump和数据布局.data
## 模块名 = 文件名; testbench 模块名 = 文件名 (tb_<模块>)
## testbench 契约: 波形输出 sim/<域>/tb_<模块>.vcd; 失败打印 N TESTS FAILED 后调 $stop;
## 单元测试先进行小规模+极端情况测试，通过后再考虑大规模测试确保正确性。
## 成功打印 ALL TESTS PASSED 后调 $finish; 一律经 make -f Makefile.tb run/wave 运行 (内部 vvp -N, 失败退出码 1)
## 代码风格 (Verilog-2005, 仿真+综合一致)
- 缩进 4 空格; 运算符两边加空格 (仿 C++ 风格), 如 (ISSUE_WIDTH + 1) * PW - 1 : 0
- 命名: 端口/信号小写下划线 (f2i_valid, rob_head); parameter/localparam 大写下划线 (ISSUE_WIDTH, TERM_RAW);
  genvar 用 i/j/k; generate 块必须命名 (begin : slt); 模块名 = 文件名
- 宽度: 所有端口/信号显式声明向量宽度, 不用裸 1-bit 混用; 多槽打包信号按 [N*32-1:0] 定宽,
  槽内用位段 [s*PW +: PW] 存取; 拼接复制用 {N{1'b0}} 语法
- 表达式: 优先 ?: 嵌套避免漏情况; 较复杂处允许 if/case 保清晰; 位宽对齐后再比较, 避免隐式截断
- 时序: 状态仅写在 always @(posedge clk) 内, 同步低有效复位 rst_n; 组合逻辑一律 assign/?: (不写 always @*)
- 常数: 魔法数用 localparam 命名 (如 TERM_RAW = 32'h0FF06093)
- 注释: 模块头注释说明功能/握手/写优先级; 中文注释; 不写逐行流水账

- 需要记录架构探索过程和debug记录，并实时提交git

- 要求以docs/description.md为准，该文件只能由我手动修改，其他计划、架构、分析文档可以修改
