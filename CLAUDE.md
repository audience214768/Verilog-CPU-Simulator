## 要求一律以 docs/description.md 为准 (该文件只能由用户手动修改; 计划/架构/分析文档随其更新)
##   IPC 测试点 = testcases/perf_* (submodule ACMClassCourse-2025/RISC-V-CPU-2026-Testcases);
##   内存: 外部 AXI4-Lite 从机 (0x00000000-0x0fffffff), 响应延迟 LATENCY 默认 **10 拍** (仅此一个口径);
##   ISA = RV32IM, 仅免除 CSR*/ECALL/EBREAK/FENCE/FENCE.I (**LB/LBU/LH/LHU 必须实现**);
##   顶层模块必须命名 student_top, reset **高有效** (初始化保持 5 拍);
##   终止 = 向 MMIO 0x80000000 做 32 位 store (WSTRB=4'hf), 退出值 = WDATA[31:0]
## 模块化目录: 
verilog/<域>/<模块>.v (top/front/core/exec), tb/<域>/tb_<模块>.v; 模块在域内平铺, 模块名=文件名
## 官方框架布局 (根目录 Makefile/scripts/ 属官方, 勿改):
##   verilog/filelist.f = RTL 源文件列表 (路径相对 verilog/), 新增/删除源文件必须同步;
##   config.mk 保持官方原样; 本机工具链路径写进 gitignore 的 config.local.mk,
##     用 make CONFIG=config.local.mk <target> 生效 (APPIMAGE 禁用以走 native 工具)
##   make synth (面积/频率口径, 需 OpenSTA) 本机跑不通 → **一律优先走远端 ssh 主机 pc**:
##     tools/remote_synth.py pc <id> [run.sh 参数...]  (推源码→远端起→只捞回小产物; 一次 18 min)
##     本机 OrbStack 容器 cpu2026:local 只在远端不可达时当退路 (容器内 config.mk 全默认;
##     ASAP7 在 /opt/asap7/lib, 是 r28; 宿主那套是 r27, 数字不可混用);
##     用法/踩坑/镜像配方见 tools/README.md 的 remote_synth.py 一节
### 模块清单: 
top=student_top (官方顶层: AXI4-Lite 端口, 例化下面两个) + cpu_top (乱序流水线, 存储接口已外露为端口);
front=fetch,decode,bht,ras;
core=rat,free_list,rob,rs,ready_table,prf,lsq,cdb,axi_lite_master (纯 AXI 协议), icache, dcache,
mem_subsystem (取指预取窗口 + load 适配 + 已提交 store 队列; 内含 I/D 两个 cache 与三路 AR 仲裁),
memory (仅 TB 用的固定 1 拍存储, student_top 不再例化);
exec=adder32,mul,alu,branch,div
### cpu_top ↔ 存储的握手契约 (新写存储器/换存储必须照此实现, 细节见各文件头注释):
- `imem_addr` = **本拍要向存储请求的批地址** (需求, 不是"上一拍发过的"); 存储必须在下一拍把**上一拍地址**
  的数据摆上 `inst_data`, 并用 `imem_valid` 说明"这拍 inst_data 属于它"; `imem_hit` = 本拍 imem_addr 上的
  地址**已可取** (固定 1 拍存储恒 1) —— fetch 用它判断能否把请求提前到下一批, 变长延迟存储必须真实实现
- `ld_busy==0` 是**必须当场兑现**的承诺 (LSQ 收到即置 issued) ⇒ 反悔即全机死锁; 每个被接受的 load
  恰好回一个 `ld_done_valid` (rresp 不门控); `ld_done_data` 只做**零扩展**, 符号扩展在 lsq.v 内
- `sw_valid` 是提交级 1 拍脉冲; 已提交 store 必须在队列里留到 **B 已握手 且 该 B 之前发出的 load 都已回**
### 参考: 
/Users/audience/program/PPCA/RISC-V-Tomasulo-CPU-Simulator
这是我用C++仿照verilog编写的CPU，已经通过了正确性测试，在编写时可以参考;并且其中含有测试数据的源程序.c以及汇编代码.dump和数据布局.data
## 模块名 = 文件名; testbench 模块名 = 文件名 (tb_<模块>)
## testbench 契约: 波形输出 sim/<域>/tb_<模块>.vcd; 失败打印 N TESTS FAILED 后调 $stop;
## 单元测试先进行小规模+极端情况测试，通过后再考虑大规模测试确保正确性。
## 成功打印 ALL TESTS PASSED 后调 $finish; 一律经 make -f Makefile.tb run/wave 运行 (内部 vvp -N, 失败退出码 1)
  ASAP7 r28 库里**没有**同步复位触发器, 同步复位会被拆成软逻辑, 更贵 (见 docs/area_budget.md §2 注)
- 常数: 魔法数用 localparam 命名 (如 TERM_RAW = 32'h0FF06093)
- 注释: 模块头注释说明功能/握手/写优先级; 中文注释; 不写逐行流水账

- 需要记录架构探索过程和debug记录，并实时提交git

- 要求以docs/description.md为准，该文件只能由我手动修改，其他计划、架构、分析文档可以修改
arch文档用于整理项目架构，
plan文档用于记录下一步计划，整体计划以及过往记录和经验（包括成功和失败），但注意过往记录应该简单不应该干扰之后的计划，不计划做的东西或者已经实现、完成的东西不应该还大量占据计划文档。不在该文档用途的内容不应该进入文档
文档应该实时修正
只在必要时进行综合，或者放在后台，避免浪费太多时间用于等待

注意性能测试和正确性测试的参数不同，特别是周期上限的设置