## 尽可能的避免if 和 case而是使用“？”表达式，避免漏情况。但如果较为复杂用if和case保证清晰度是可以接受的。
## 使用verilog-2005版本，确保可以同时仿真、综合
## 乱序执行多发射CPU
## 可以参数化，比如多发射指令数、ROB、RS等数据结构的大小，具体到后端实现不需要参数化（比如加法器、乘法器的位数）
## 报告：架构设计探索，性能消融（不同参数下性能优化情况）
## 用YoSys+ASP7工艺库综合面积，要求单发射情况下面积在1500-2000um2，性能和面积翻倍比例在1.3x。
## 注意，需要实现乘法，采用2位booth编码+华莱士树
## 模块化目录: 
rtl/<域>/<模块>.v (top/front/core/exec), tb/<域>/tb_<模块>.v; 模块在域内平铺, 模块名=文件名
### 模块清单: 
top=cpu_top; front=fetch,decode,bht,ras;
core=rat,free_list,rob,rs,ready_table,prf,lsq,cdb,memory; exec=adder32,mul,alu,branch
### 参考: 
/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator
## 模块名 = 文件名; testbench 模块名 = 文件名 (tb_<模块>)
## testbench 契约: 波形输出 sim/<域>/tb_<模块>.vcd; 失败打印 N TESTS FAILED 后调 $stop;
## 成功打印 ALL TESTS PASSED 后调 $finish; 一律经 make run/wave 运行 (内部 vvp -N, 失败退出码 1)
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
