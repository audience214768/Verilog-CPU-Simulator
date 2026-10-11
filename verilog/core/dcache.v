// L1 数据缓存 (组相联; 每路的 tag 与数据同条目放进一块 sram_fakeram) —— 骨架照抄 core/icache.v
// 对外只做三件事: ①查表(接受一条 load) ②命中就当拍+1交付 ③缺失就发一笔 AR (并按行填充)
//
// 【为什么 tag 也放 SRAM】与 icache 同因 (那里是 imem_valid/imem_hit 要同拍); 这里的额外好处是
//   多路相联**不需要多个读口**: 一条目 = DC_WAYS 路 × (DC_LINE_WORDS 字 + 1 个 tag 槽), 一拍读出
//   所有路的 tag, T+1 并行比较即可。DFF tag 阵列太贵: 2 KiB/32 B 行/64 组 × 22 位 = 1408 flop
//   ≈ 534 µm² (0.37908 µm²/flop, 异步复位), 与数据阵列本身 (18432 bit ≈ 774 µm²) 同量级。
//
// 【★ 交付端口只有一个源 —— 全设计最关键的一条不变量】
//   命中在 T+1 交付, AXI 回包在任意拍交付, 二者可能撞车。LSQ 只有一个完成口 (lsq.v:221),
//   一拍丢一个脉冲 = 那条 `issued_r` 永远为 1 = head 卡死 ⇒ **每拍恰好一个 ld_done_valid**。
//   做法**不是**去反压回包 (`rd_resp_ready` 保持硬接 1), 而是让**命中抢不到就不交**:
//     hit_valid = 命中判定 && !rsp_busy       (rsp_busy = 本拍有 load 回包)
//     miss_go   = !hit_valid && ...           (抢输的命中**降级**成缺失, 走 AXI 重取)
//   于是交付源恒为 {回包} ∪ {命中, 且回包不在} ⇒ 天然互斥。代价是撞车那一笔白读一次 SRAM +
//   多一趟 AXI 往返; 收益是一条不需要额外仲裁器就成立的不变量 (纯命中流/纯缺失流永不撞车)。
//
// 【★ 缺失推送的 1 格 skid = 复用查表寄存器本身 (不另加存储)】
//   上游 `ms_ready` 可能为低 (读 FIFO 满 / AXI 通道被占)。此时**保持** lk_*_r 并在后续拍重试,
//   同时置 lk_miss_r (SRAM 数据已失效, 不得再拿它比 tag)。这要求 `busy` 输出在**当拍**就抬高:
//     busy = lk_v_r && !hit_valid && !ms_fire_w
//   否则下一拍来的 load 会在 posedge 覆盖掉还没推出去的那个地址。
//   归纳: 查表结果存在 ⟺ 上一拍接受了 load; 而接受 ⇒ busy=0 ⇒ 不会 park ⇒ skid 必空; 反之
//   lk_v_r 被占住那拍 busy=1 ⇒ 不会有第二个缺失同时要寄存。AR 发射序 = 接受序 = 缺失序。
//
// 【★ MSHR 合并 —— 不加会把顺序流打回基线】单 MSHR 下, 填充期间对该行的每条 load 都会判缺失、
//   各发一笔 AR (32 B 行 = 每行 8 笔重复 AR; vvadd 那种顺序流必中)。故: 缺失且**行号与在填行相同**
//   ⇒ 不推 AR, 置 lk_wait_r 停住; 填充最后一字落地那拍**重放** (把 lk_addr_r 重新摆上 SRAM 地址口,
//   1 拍后再判定 ⇒ 这次命中)。行号不同的缺失照常推 AR, 行号存进 1 条排队寄存器 pf_* 稍后起填。
//   ★ pf_* 的清法有一条硬规矩: "本拍起填的正是排队那条" (`pf_start_w`) 时**不得**用本拍的新缺失覆盖
//   它 (那个缺失下一拍会自己重新排队)。留着它 ⇒ 填充结束后对**同一行**再起一次填充, 而那时该行已
//   驻留 ⇒ victim 落到另一路, 安装时的不变量 1 清理会静默作废另一路的**脏副本** (只清 valid/dirty,
//   不写回) ⇒ 该行吸收过的 store 永远到不了内存, 随后的重填读回旧值。
//
// 【★ 单端口 SRAM 的读写冲突】写 (填充安装 / store 命中就地更新) **绝对优先** (回包不可反压),
//   WB 捕获读次之 (它只有那一拍机会: 受害行下一拍就可能被填充覆盖), 被偷走的**查表读**一律
//   **重放** (写周期里 sram_fakeram 把 rdata 置 x ⇒ 该拍结果不可信): `rd_ok_r` 在**发起读那一拍**
//   采样 (`<= !sram_we_w && !wb_cap_w`), 未偷才允许判定, 被偷则置 lk_replay_r 重发同一地址
//   (第 6 节)。★ 不能像"无写回"版本那样把偷读判成缺失自纠正: 写回下误判缺失 = 读到陈旧内存
//   **且** 覆盖脏行 = 静默算错。重放只多 1 拍, 且写/捕获的优先权是绝对的 ⇒ 重放必收敛。上层另用
//   `busy` 里的 `fill_wr_w`/`fill_wr_r` 两项把"撞上填充分字写"的接受挡掉 (前者还是锥 ① 的正确性
//   前提, 见下), 省掉这次重放 (store 写不进门是不行的: SQ 只等这一拍就得给答复)。
//
// 【★ 安装写打一拍 + 写粒度 = 一整路 (锥 ①: 写口最后两跳的 3.55 ns 地板; §3.13)】
//   官方 ABC 流程 (无 -constr ⇒ 一根线的负载数就是它的延迟) 下, 写口最后两跳曾是
//   "25 级判决云 → sram_we_w (40 脚) → u_arr.addr* (每 bit 18 个宏脚 ≈ 90 fF)": 实测 1.1977 + 2.3445
//   = 3.55 ns = 282 MHz, 是 300 MHz 的结构性障碍 —— 而那个判决云本身只是把一次**写**的载荷摆上端口。
//   两件事必须**一起**做掉它 (只做后者是实测负结果 —— 打拍只换旁路输入, 端口负载一个没动):
//   ① **写粒度 32 → 一整路** (WG = WAY_W): 宏实例数 18 → 2 ⇒ 每根地址位 90 fF → 10 fF (见 WG 的论证);
//   ② **安装写从判决拍搬到下一拍**: 判决逻辑 (优先级 fill > rmw 与全部守卫) 一行不改, 判决拍立起
//      `fill_wr_r`, 落盘拍由 FF 直接驱动 u_arr 的 we/wmask/wdata/addr。
//   ★ **载荷必须捕获**: store 的 `st_valid` 虽保持到 absorb, 但 absorb 在判决拍就发 (SQ 队首不能多停)
//     ⇒ 落盘拍端口上站的是**下一条** store ⇒ 用活信号 = 把下一条按上一条的地址写进去且两条都被标
//     "已判" (静默丢 store + 污染无关行)。整路粒度下这条自动成立: 填充载荷是 `fill_buf_r` (整行缓冲)、
//     store 载荷**也**是 `fill_buf_r` (刀 O: 合成的 256 位数据并进同一个缓冲), 两者都是寄存器。
//   ★ **握手一律不动**: `st_absorb`/`st_bypass`/`sq_ticket_r` 取数拍全在原处 ⇒ AXI 可见性口径与
//     第 4 节那张表不变, 变的只是"写何时落到 SRAM"与随之的 valid/dirty/污染。
//   ③ **写口选择端交给寄存器 `rmw_v_r`** (刀 M, 2026-10-11): ②之后 we/addr/wmask/wdata 的**选择端**
//      仍取自 `fill_wr_r` —— 而这根网同时还喂 `busy` (头名路径的起点), 又扛着 576 位载荷 mux 的 288 个
//      选通脚。官方无缓冲流程下**一根网的负载数就是它的延迟** ⇒ 头名两级里 1.98 ns 的 ~86% 是这根网
//      的负载税 (§3.21 逐脚统计)。做法: 写相改由 `rmw_v_r` 独占选择端, 让"安装落盘"
//      与"RMW 写相"**结构上不同拍**。
//   ④ **刀 O (2026-10-11): 写载荷并进 `fill_buf_r` ⇒ 288 位载荷 mux 退成 32 位**。原设计两支载荷
//      各有自己的 288 位寄存器 (`fill_pay_w` ← `fill_buf_r` 与 `rmw_pay_r`), 而 `wdata_w` 的选通脚
//      (253/326) 是头名 (4.7579 ns, n=32) 的**纯负载税**。现在: RMW 合成的 256 位数据直接写回
//      `fill_buf_r` (第 ⑩ 节 fill 块的 always, 显式优先级"回包逐字 > RMW 合成"), tag 槽单立
//      `rmw_tag_r` (32 位, 非复位) ⇒ 两支载荷逐位等价于
//      `{rmw_v_r ? rmw_pay_r : fill_pay_w}` ≡ `{rmw_v_r ? rmw_tag_r : fill_pay_w[287:256], fill_buf_r}`,
//      但 mux 只剩 32 位。**删** `rmw_pay_r` (288 FF) 与 `rmw_pend_r` (1 FF) 及整套挂起逻辑。
//      ★ 前提是**窗口互斥**(否则回包与合成同拍抢 `fill_buf_r`): `rmw_rd_w` 加
//      `&& !fill_busy_r && !fill_start_w` —— 读相到落盘这 3 拍里不许有任何在飞填充 (下一拍就可能回包)
//      也不许有起填。三个起填源都含 `!rmw_hold_w`, 而窗口内 `rmw_hold_w` (= rd1_r || v_r) 恒 1 ⇒
//      窗口内既无在飞回包也无新起填, 与存储延迟无关 (LATENCY=1 的 TB 也成立) ⇒ `fill_wr_w` 在窗口内
//      恒 0, 旧刀 M 的判决点 `~fill_wr_w` 退化成 `1'b1`。
//      代价: 命中行的 store 吸收从此要等**在飞填充收尾** (≤ ~22 拍); 收益: 净删 ~256 FF + 288→32 位 mux。
//   ⑤ **刀 U (2026-10-11): 探针那一读就是读相**。④ 之后"命中的 store 还得占读口把整路取回来"其实是
//      **重复读**: 探针 (`stp_go_w`) 那一拍读的就是本笔 store 的组, `probe_hold_w` 保证那拍读口确实
//      是它的 (`rd_addr_w = probe_addr_w`) ⇒ 回包拍 `rdata_w` 上正是本笔 store 那一整路 —— tag 比较器
//      (`st_tm_now_w`) 本来就在信任这一条。做法: 读-改-写分两支, 回包那拍 (`rmw_now_w`) 直接合成,
//      读相 (`rmw_rd_w`) 只留给"答案来自锁存"那一支 ⇒ 吸收 3 拍 → 2 拍、每笔吸收少占读口 1 拍。
//      ★ 附带的**频率收益**: 旧 `rmw_rd_w` 的判决吃了本拍 rdata (`any_st_hit_w`/`st_vic_now_w`),
//      而它又去选 `rd_addr_w` 的 `st_addr` 支 ⇒ 宏自己的一拍闭环"读出 tag → 命中判定 → 占读口 →
//      地址" (census 头名族 4.5588, plan §3.30)。改后读相判决只认锁存 (`st_hit_lat_w`/
//      `st_vic_lat_now_w`), 回包支只写寄存器、不碰读口 ⇒ 该闭环在结构上不存在。
//   ★ 配套三处守卫 (缺一条都是静默算错, 逐条论证见各点注释):
//     ① `st_fill_same_w` 含落盘拍 (`fill_wr_r`): 漏了则同行 store 在落盘拍被判"旁路" —— 那一刻行还没
//        valid ⇒ 判不命中 ⇒ 数据只进内存, 而行随即被标 valid (此后命中读到旧值);
//     ② `vset` / 不变量 1 清理 / 探针锁存作废 / LRU 指针全部改由 `fill_vset_r` 在落盘拍触发 ——
//        行真进 SRAM 就是那一拍, valid 早置一拍就是"行还没拿到却自称有效";
//     ③ 落盘拍**不许**起新填充选中同一 (组,路) 或同一行 (`fill_vic_hit_w`): 前者同拍 vset 会赢过
//        "受害路清 valid" (always 块里清在前、置在后) ⇒ 新填充往一条刚被标 valid 的行里灌 tag/数据;
//        后者 = 对"这一拍才装上、检查都还没看见"的行再填一次 ⇒ 不变量 1 清理静默作废另一路副本。
//   ★ 填充的**字下标与数据都在回包拍攒进** `fill_buf_r` (整行缓冲): 安装写是"整路一次落", 落盘拍
//     不再需要认字下标 (旧写法靠 `fill_woff_r` 捕获, 因为落盘拍 `fill_cnt_r` 可能已被下一笔回包 +1)。
//   ★ 导出给上层的 `fill_busy` (污染判定用) **不延长**到落盘拍: 那一拍 `fill_busy_r`=0, 而
//     `sq_line_blk_f` 的"注定被吸收"豁免要求 busy=1 —— 延长会让**同拍起填的新行**漏判污染。
//   ★ 吞吐: 回包逐拍来 ⇒ 攒缓冲与落盘逐拍流水; 一次填充比旧版多 1 拍收尾 (末字晚一拍落盘),
//     但写口占用从"每字一篇 + tag 槽重复写 8 次"降到**整路一次** (8 拍 → 1 拍)。
//   ★ ④ 查表接受仍**必须**在末字回包拍 (`fill_wr_w`) 挡住 (见第 6 节 `busy`): 那一拍接受的 load
//     查到的正是"行还差最后一个字、valid 未置"的状态, 到落盘拍判出来的缺失已经过时 ⇒ 会去填一条
//     下一拍就驻留的行。旧版靠"末字回包拍就是安装写拍"顺带挡住 (那一刻读被偷 ⇒ 重放), 搬走写
//     之后这条副作用一起没了, 必须显式补回。
//
// 【★ 一致性: **写回** —— 缓存行是数据的唯一权威, 内存只是被写回的备份】见 mem_subsystem.v 第 4 节。
//   (上一版是"写直达 + 命中就地更新": store 数据同时进缓存行与内存。写回把 AXI 写流量从"每条
//    store 一笔"降到"每行换出 8 笔", 并把 SQ 条目的可见性从"B 回包"改成"写进缓存行"。)
//   只有一根线 (旧版的"提交 `inv_valid` 拦安装"已删 —— 写回下 store 的数据在吸收前哪儿都不去,
//   不与在飞填充抢同一个字, 拦安装纯多余; 其副作用是"提交撞上填充最后一拍"变成静默丢一次安装):
//     · 退休 (`st_valid` 口, 第 9 节): 队首那条 store 在本拍定去向 —— 命中就地把字节写进行并置脏
//       (`st_absorb`), 未命中就旁路给 AXI (`st_bypass`, 数据本来就在 SQ→写通道的路上)。
//   提交→退休之间那一段靠上层 `mem_subsystem.sq_merge_byte_f` 的字节合并链兜住: 交付一条 load 时
//   逐字节用 SQ 里更老的 store 覆盖 (写回下这一条更吃重 —— 未退休 store 的数据既不在内存也不在
//   行里, 只在 SQ)。**更新与"条目出队"的关系是单向安全的**:
//     · 若更新早于退休 → 合并链还在, 覆盖的是同一个值, 无害 (写回下条目还要等 ticket, 所以
//       "吸收那拍"与"出队那拍"通常差好几拍, 全部落在这一侧);
//     · 若合并先没而更新还没到 → **读到旧值, 静默算错**。故 `sq_ret_ok` 必须等 `st_absorb` 抬过
//       才成立 (mem_subsystem 的 sq_vis_w 含 sq_ab_r)。
//   ★ 与更早那一版 (idxinv: 退休清**整组**) 的区别: 清组会把同组其它行一起打掉 —— 一次 store 退休
//   就毁掉一整组 (64 B)。离线模型 (tools/dcache_sim.py) 实测这一项值 8.2% (geo 0.4997 → 0.5408)。
//   ★ 命中的是"最高编号的命中路" (hitway_f 的覆盖序); 同组不允许出现两个同 tag 的路 —— 由不变量 1
//   在**安装**那拍禁掉 (第 8 节)。
//
// 【★ 脏位 + 写回 (WB): 驱逐脏行时先读进缓冲, 再排水到写通道】
//   起填那拍发现受害路 `valid && dirty` ⇒ ①记下 `wbc_*`, 该路 valid/dirty 同拍清零; ②下一拍用
//   **读口**把整行读进 `wb_data_r` (那拍读口被占, 撞上的查表读靠 rd_ok_r=0 重放); ③再下一拍起
//   背靠背推 DC_LINE_WORDS 笔 `wb_req_*`, 推完转 `wb_hold_r` 等 B; ④B 收齐才松手。
//   ★ 捕获读与填充**不冲突**: 填充分第一笔写最早在第 DC_LINE_WORDS+LATENCY 拍, 而捕获读只占第 2 拍。
//   ★ 在线冲突 (各一个比较器, 比 [31:SPLIT]): 同一行的**填充**不起 (内存此刻可能还是旧值);
//     同一行的**旁路 store** 不发 (否则它的新字节会被旧行的 8 笔写回反超)。
//   ★ WB 缓冲只有 1 项: 要驱逐脏行而缓冲被占 ⇒ 本次填充停住 (等排水完, 罕见), 但**不丢** ——
//     记进 pf_* 排队那条 (fill_blk_w/fill_pend_w)。
//
// 【★ 写回引入的第三处"误判缺失 = 静默算错"】写回下内存可能落后于缓存行, 于是**任何**把
//   "本该命中"变成"去读内存"的路径都致命。除了上面那条"偷读必须重放"之外, 还有一处:
//   命中但交付口被 rsp_busy 占住时, 写直达版可以降级成缺失 (走 AXI 重取, 反正内存新鲜),
//   写回下不行 ⇒ 改成**重放** (第 6 节, 只花 2 拍, 比一趟 AXI 还便宜), 同时用 `!hit_raw_w`
//   把这条挡在 `ms_valid` 之外 (第 4 节)。两处必须成对改。
//
// 【★ 填充污染 (poison): 起填前/填充中只要有"尚未可见"的 store 落在**同一行**, 本次填充作废】
//   只查"安装那一拍 SQ 里有没有同行条目"**不够**: store 可能在最后一字落地前就退休出队, 而它之前
//   发出的那几笔 AR 读的是旧值 ⇒ 装进一行旧数据 (静默算错)。故用**粘滞**污染位: 填充期间任一拍
//   发现 fill_blk 命中本行 ⇒ 置位, 直到本次填充结束才清; 污染后不再写 SRAM、不置 valid。
//   安装那一拍若本拍有 store 提交到同一行, 也要抑制 (valid 置位输给失效)。
//   ★ 粒度 = **行**, 不是组 (旧版是 DC_SETS 位的组位图)。组粒度下"SQ 里任一条待落盘 store"
//     会废掉整个组 (32 组里每 2 KB/128 B 一个) 的填充 —— rsort 实测填充只装进 3.21/8 个字
//     (qsort 6.80), 20.5% 的周期处在"这次填充已经废了"的状态, 命中率被拖到 54.4%。行粒度把
//     误伤面缩到 1/32, 且判据本身没变宽: 危险窗口是"该行的 AR 早于该 store 落盘", 同行的
//     待可见条目才是真危险。
//   ★ 为什么覆盖"全部待可见条目"而不是只覆盖会旁路的那些 (计划里曾这么写): 一条 store 究竟
//     被吸收还是旁路, 要等它**退休那拍**看行在不在才定得下来, 事前无法判 —— 而"先装行、后
//     吸收"这一路本来就安全 (同拍结束的两窗口 + 合并链), 所以安全上界就是"同行有未可见条目"。
//     这个上界在实践中很紧: 条目一旦可见 (吸收进行 / 或已落盘) 就不再污染。
//
// 【★ 下一行预取 (M5; DC_PREFETCH = 0/1/2) —— 复用填充器, 只多一个"起填理由"】
//   动机 (§35.3 实测): 等存储的 79~89% 是 head load 等**自己那笔需求缺失的回包**, 往返恒 14 拍
//   (官方 LATENCY 10 + 4 拍握手), 推送时零排队 ⇒ 唯一的方向是**减少 head 遇到的缺失次数**。
//   触发键是**本次访问的行** (缺 L ⇒ 取 L+1), 与"下一笔缺失落在哪一行"无关。
//     =1: 需求缺失**真起填**那拍登记下一行; =2: 每次**命中交付**那拍登记下一行 (I-cache 现行做法)。
//   登记的下一行**不当拍起填**, 而是进 1 槽 `dpf_*` 排队, 由填充器空闲时消化 —— 需求永远优先。
// ★ **存在性检查是硬要求, 不是优化** (pf_present_w): 对**已驻留**的行再起一次填充 ⇒ victim 落到
//   另一路 ⇒ 安装时的不变量 1 清理会把那一路的**脏副本静默作废** (只清 valid/dirty, 不写回) ⇒
//   该行吸收过的 store 永远到不了内存, 之后的重填读回旧值 —— 与第三段头注释里那次事故同形。
//   今天"对已驻留行再起填"不会发生, 靠的是"pf_* 只由**缺失**的路写入"这条被动性质; 预取是
//   **主动**去找行, 而相邻行属**不同组**、各自独立被驱逐 ⇒ 撞上已驻留行是常态, 必须显式查。
//   查法与 store 口同一套 **tag 探针** (见下面【★ tag 探针】那一段): 不占拍, 但要等一个读口空槽; 等不到时
//   本次起填原地推迟 (`dpf_sel_w` 带 `pfc_same_w`) —— 只慢不错。检查与起填判定仍**同一拍**,
//   故不存在"查完到起填之间被别人装进来"的窗口 (那一拍引擎被 `!fill_busy_r && !pf_v_r && !dc_demand_w`
//   锁住; 探针锁定期间若真有人装了该行, `vset_w` 会把锁存的回答作废 ⇒ 重新查)。
// ★ 预取**不走** fill_pend_w 那条排队路 (那是需求的): 被挡住的预取直接丢弃 —— 预取晚一拍就没用,
//   不值得为它挤掉一次需求的排队机会。故 `dpf_v_r` 只影响"空闲时起哪一行", 不占任何正确性资源。
// ★ 起填口完全复用现成的填充器 (fill_base_new_w 多一个源) ⇒ 受害路/LRU/写回捕获/污染中止/
//   RMW 窗口/写回同行冲突**全部自动继承**。尤其污染中止是**必须**继承的: SQ 里有未可见 store 的
//   行, 预取读回的是旧值 —— 装进去就是静默算错 (§第 5 节)。
//
// 【★ tag 探针 —— 取代原来那份 DFF tag 镜像 (1408 flop)】
//   原设计为让 store 退休**当拍**答复而维护了一份 DC_WAYS*DC_SETS*TAG_W 的 tag 镜像, 它的动态写
//   (`tag_r[... +: TAG_W]`) 在官方 ABC 流程 (无 -constr ⇒ 只按字面量数优化) 下是最贵的宽扇出簇
//   之一。SRAM 里本来就存着同一份 tag, 只是同步读 ⇒ 缺的只是"提前一拍问"。探针就是这件事。
//   规则 (四条):
//     · **优先只在读口真空闲那拍发出** (`probe_slot_w`): 没有 load 会被接受 (`!lk_valid`) + 没有待判
//       的 load (`!(lk_v_r && !lk_wait_r)`, 含重放) + 没有别的读用户占口 (`!wb_cap_w && !rmw_rd_w`)
//       + 本拍无写 (写周期 sram_fakeram 把 rdata 置 x)。满足这些时这笔读**不偷任何人的口**,
//       于是 `rd_ok_r` 不必为它置 0 —— 少一次重放。(注意"组合环"不是这里的约束: `rd_ok_r` 是
//       寄存器, `lk_valid → probe 门 → rd_ok_r.D` 是一条合法的 Q→D 路径。真正不许碰的只有
//       `wb_cap_w`/`rmw_rd_w`/`sram_we_w`/`lk_replay_r` 那四种**不可重放**的读。)
//     · **等不到空槽就硬抢** (饿死计时, `probe_wait_r`): 被抢的那笔查表读由 `probe_steal_w` 置
//       `rd_ok_r=0` 走重放 (+2 拍) —— 只慢不错。阈值按用户能等多久给: 填充清理只等 2 拍 (它每次
//       填充只有一次机会), store 退休与预取等 8 拍 (SQ 队首在等, 但重放比再等便宜)。
//       不会自锁: 堵住探针的正是"load 流不断", 而 SQ 一旦积压就没人再发 load ⇒ 空槽必然出现。
//     · **结果锁存**: 探针数据下一拍才到 `rdata_w`, 故发起那拍锁下"比的是哪个 tag / 哪一组",
//       回包那拍把 DC_WAYS 个比较结果整条锁下 (`st_tm_r` / `fc_tm_r` / `pfc_present_r`)。中间若换了
//       地址, 锁存的那份因 `st_tag_r == st_tag_w` 等条件不成立而**不被采用** (不是错值, 是重查)。
//     · **锁存有效期**: `vset_w` (安装新行) 与 `fill_start_w` (清受害路 valid) 都可能改变"本行还在
//       不在", 故都在那些拍作废锁存; 预取存在性只在 `vset_w` 作废 (方向安全: 作废只会重查一次,
//       不会用陈旧回答 —— 陈旧回答只会让预取少发一次, 而存在性检查是**硬要求**)。
//   谁在用: ① store 退休 (第 9 节 `st_hit_g`); ② 填充安装的同组重复 tag 清理 (第 8 节);
//   ③ 预取存在性 (`pf_present_w`)。②能"每次填充只查一次"是因为填充在飞时同组的 valid/tag 冻结。
//   WB 捕获那条 (受害行 tag) **不发探针**: 它本来就要把受害行整行读进缓冲, tag 就在同一份回包
//   数据里 (`rdata_w` 的 tag 槽), 顺路取, 零额外读口。代价是 `wb_base_r` 的 tag 有**两拍未知窗口**
//   (`wb_tag_v_r`), 这期间同组一律当作"同一行" —— 方向保守 (多挡一次填充 / 多让一条 load 并入),
//   见 `fill_blk_w` / `lk_wb_wait_w` / `st_wb_same_w` 三处。
//
// 复位异步低有效 (与 axi_lite_master / icache / mem_subsystem 一致; ASAP7 库只有异步复位触发器)
module dcache #(
    parameter DC_SIZE       = 2048,     // 总容量 (字节; 0 = 旁路, 见 DC_OFF)
    parameter DC_LINE_WORDS = 8,        // 每行字数 (2 的幂)
    parameter DC_WAYS       = 1,        // 相联度 (2 的幂; 1/2/4… 均可)
    parameter DC_PREFETCH   = 0,        // 下一行预取: 0=关 1=需求缺失起填那拍预取下一行 2=每次命中交付那拍预取
    parameter LSQ_SIZE      = 16,       // 仅为 idx 宽度
    // 组数由上面三个参数推出; 必须是 parameter (而非 localparam) 才能出现在端口声明里。
    // * 向上取到 2 的幂: SRAM 的地址线宽按组数取, 非 2 的幂会让高位地址越界 ($fatal)。
    // * DC_SIZE=0 时夹到 1 (sram_fakeram 对 DEPTH=0 会 $fatal, $clog2(0) 在 Verilog-2005 里未定义)
    parameter SETS_RAW      = DC_SIZE / (4 * DC_LINE_WORDS * DC_WAYS),
    parameter DC_SETS       = (SETS_RAW < 1) ? 1 : (1 << $clog2(SETS_RAW))
) (
    input  clk,
    input  rst_n,

    // ---- 查表口 (上层: lk_valid = ld_accept = ld_start_valid && !dc_busy) ----
    input                                lk_valid,
    input  [31 : 0]                      lk_addr,
    input  [1 : 0]                       lk_width,
    input  [$clog2(LSQ_SIZE) - 1 : 0]    lk_idx,
    input                                rsp_busy,     // 本拍有 load 的 AXI 回包 (交付端口被占)

    // ---- 命中交付 (T+1; 与回包天然互斥, 上层直接 `done_valid = rsp_valid || hit_valid`) ----
    output                               hit_valid,
    output [31 : 0]                      hit_word,     // 该地址所在**整字** (未抽取/未零扩展)
    output [31 : 0]                      hit_addr,
    output [1 : 0]                       hit_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]    hit_idx,

    // ---- 缺失推送 (ms_valid 保持到 ms_ready; 上层在 ms_ready 那拍把 payload 压进 miss 队列) ----
    output                               ms_valid,
    output [31 : 0]                      ms_addr,      // load 的**原始字节地址** (AR 地址由上层对齐)
    output [1 : 0]                       ms_width,
    output [$clog2(LSQ_SIZE) - 1 : 0]    ms_idx,
    input                                ms_ready,

    // ---- 行填充 (由上层仲裁; 优先级 需求 load > 取指填充 > 本填充) ----
    output                               fill_req_valid,
    output [31 : 0]                      fill_req_addr,
    input                                fill_req_ready,
    input                                fill_rsp_valid,   // 与已发出的请求一一对应且同序; 不可反压
    input  [31 : 0]                      fill_rsp_data,

    // ---- store 一致性 ----
    // 只有一根线: st_* = 队首那条 store 的**退休**判定 —— 命中把该 store 的字节写进行 (写回),
    // 未命中就旁路给 AXI。提交那拍不再通知本模块 (旧版 inv_valid 拦安装一条已删): 写回下 store 的
    // 数据在吸收前**哪儿都不去**, 不会与在飞填充读回的内存值抢同一个字 ⇒ 拦安装纯属多余, 而它
    // 的副作用是把"提交恰好撞上填充最后一拍"变成**静默丢一次安装** (行不 valid、填充照常收尾),
    // 于是下一条 load 又缺失 —— 与 §9 的自杀环同形状。
    // ---- 填充污染 (行粒度): fill_line = 本拍"有效填充行", fill_blk 由上层按 SQ 未可见条目算 ----
    // 起填那拍 fill_line 给**新行** (fill_base_r 还没更新), 其余拍给在填行; 见第五条不变量。
    output [31 : 0]                      fill_line,
    input                                fill_blk,

    // ---- store 退休口 (payload 由 mem_subsystem 的 SQ 队首直接给出; 语义与论证见第 9 节) ----
    // st_valid 保持到 st_absorb/st_bypass **之一**抬起 (与 ms_valid/ms_ready 同款握手);
    // 二者互斥, 且可能全 0 (安装写 / WB 捕获读占着 SRAM 口 ⇒ 多等一拍, 队首不动)。
    input                                st_valid,
    input  [31 : 0]                      st_addr,
    input  [31 : 0]                      st_data,
    input  [1 : 0]                       st_width,
    output                               st_absorb,    // 命中 ⇒ 本拍已就地把该 store 的字节写进行 (置脏)
    output                               st_bypass,    // 未命中 ⇒ 本缓存不动 (数据另走 AXI)

    // ---- 写回口 (脏行被驱逐: 整行 DC_LINE_WORDS 笔背靠背写回; 写通道由上层与 SQ 旁路 store 仲裁) ----
    output                               wb_req_valid,
    output [31 : 0]                      wb_req_addr,
    output [31 : 0]                      wb_req_data,
    input                                wb_req_ready,
    input                                wb_resp_valid, // 本行某一笔写回收到 B

    // ---- 观测量 ----
    output                               busy,         // 查表寄存器被占 || 本拍有安装写 (load 不可接受)
    output                               fill_busy
);
    // 地址切分: [31:TAGHI] 行 tag | [TAGHI-1:SPLIT] 组号 | [SPLIT-1:2] 行内字偏移 | [1:0] 字节
    localparam DC_OFF   = (DC_SIZE == 0) ? 1'b1 : 1'b0;  // 旁路: 永不命中、永不起填
    localparam ONE_SET  = (DC_SETS < 2) ? 1'b1 : 1'b0;   // 只有 1 组 ⇒ 组号恒 0 (DEPTH=1 越界保护)
    localparam DC_IW    = (DC_SETS < 2) ? 1 : $clog2(DC_SETS);
    localparam OFF_W    = $clog2(DC_LINE_WORDS);
    localparam SPLIT    = 2 + OFF_W;
    localparam TAGHI    = SPLIT + DC_IW;
    localparam TAG_W    = 32 - TAGHI;
    localparam WAY_W    = 32 * DC_LINE_WORDS + 32;       // 一路的条目宽: 数据 + tag (tag 占最高 32 位槽)
    localparam EW       = DC_WAYS * WAY_W;
    localparam TAGOFF   = 32 * DC_LINE_WORDS + TAGHI;    // 条目里 tag 字段起始位 (= WAY_W − TAG_W, 顶对齐)
    // ★ 写粒度 = **一整路** (WG = WAY_W 位): 每路恰好 1 个 lane ⇒ 掩码位数 = 路数。
    //   用整路而不是更小的单位, 唯一的原因是**宏实例数**: sram_fakeram 把 WIDTH 拆成
    //   WIDTH/GRANULARITY 个宏 (scripts/fakeram.py), 而这些宏的 addr/we/wmask 输入脚由**同一根网**
    //   驱动 —— 官方 ABC 不缓冲也不 upsize ⇒ 一根网挂多少脚就是多少延时。综合网表上三段实测:
    //     8 位粒度 72 宏: 地址网 71 个宏脚 (≈355 pF), 两级吃掉 4.21 ns = c2 周期 6.02 ns 的 71%;
    //     32 位粒度 18 宏: 地址 mux 一级 2.3445 ns (= 18 脚 = 90 fF), 是头名的最后一级 (§3.13);
    //     整路粒度 2 宏: 地址位 10 fF。
    //   **面积几乎不变** (lane_area = depth*granularity*area_per_bit, 只按总位数计): 2×386.79 vs
    //   18×43.00 = 773.6 vs 774.0 µm²。代价 = clock_to_q 涨 0.001243254 × (288−32) = 0.318 ns,
    //   落在**读回**那一级 (交付/比较), 与写口负载无关。
    //   写只能整路写 (半路写会覆盖同组其余 32 位槽) ⇒ (a) 填充安装改**整行缓冲 + 一次落盘**
    //   (第 5b 节), 顺带把填充的写口占用 8 拍降到 1 拍、tag 槽从重复写 8 次降到 1 次;
    //   (b) store 吸收一律**读-改-写** (第 9 节), 原"整字 1 拍就地写"那条快路消失。
    //   perf 六例里 `sh` 静态 0 次, `sb` 只在 rsort 引用的那一个 memcpy 里出现 (动态 ≤0.5%),
    //   且现在整字也走读-改-写 ⇒ 预期 IPC −0~1%。
    localparam WG       = WAY_W;                         // 写粒度: 一整路 (8 字 + 1 个 tag 槽)
    localparam WMASK_W  = EW / WG;                       // = DC_WAYS (每路 1 个 lane)
    localparam FIW      = $clog2(DC_LINE_WORDS + 1);     // 填充字计数器位宽 (须能表示 DC_LINE_WORDS 本身)
    localparam BIW      = (DC_LINE_WORDS < 2) ? 1 : $clog2(DC_LINE_WORDS);  // WB 排水计数器位宽
    localparam WY_W     = (DC_WAYS > 1) ? $clog2(DC_WAYS) : 1;
    localparam LIW      = $clog2(LSQ_SIZE);

    integer gi;                                          // always 块里的位图循环
    genvar  gj;                                          // generate 循环

    // ==================== 1. 网表声明 ====================
    wire [EW - 1 : 0]        rdata_w;
    wire [31 : 0]            rd_addr_w;                  // 本拍摆上 SRAM 读口的地址
    wire [DC_IW - 1 : 0]     rd_set_w, q_set_w, new_set_w;
    wire [OFF_W - 1 : 0]     q_off_w;
    wire [TAG_W - 1 : 0]     rd_tag_w;
    wire [DC_WAYS - 1 : 0]   way_hit_g, set_valid_w;
    wire [WY_W - 1 : 0]      hit_way_w, victim_way_w;
    wire                     any_hit_w, hit_raw_w;
    wire [31 : 0]            hit_word_w, fill_base_new_w;
    wire                     miss_pending_w, coalesce_w, same_line_w;
    wire                     lk_same_fill_w, lk_wb_wait_w, lk_wait_src_w, lk_cacheable_w;
    wire                     ms_fire_w, fill_go_w, fill_pend_w, fill_start_w, fill_blk_w;
    wire                     fill_vic_hit_w;                       // 落盘拍: 新填充的受害路正是安装那一 (组,路)
    wire                     dc_demand_w;                          // ---- 第 5 节: 下一行预取 (M5) ----
    wire [31 : 0]            dc_fill_line_w;                       // (★ 必须单独一行: `wire a,b;` 两位都只 1 bit)
    wire                     pf_trig_w, pf_start_w, dpf_sel_w, dpf_start_w;
    wire [31 : 0]            pf_base_w;
    wire [DC_IW - 1 : 0]     pf_set_w;
    wire [TAG_W - 1 : 0]     pf_tag_w;
    wire                     fill_wr_w, fill_hs_w, fill_last_w, fill_poison_now_w, vset_w;
    wire                     fill_abort_w;
    wire                     byp_word_w, byp_raw_w, byp_valid_w;   // ---- 第 5b 节: M2 填充数据旁路 ----
    wire [FIW - 1 : 0]       fill_inflight_w;
    wire [WMASK_W - 1 : 0]   wmask_w;
    wire [EW - 1 : 0]        wdata_w;
    wire                     sram_we_w;                  // SRAM 写使能 = 安装 ∪ store 就地更新
    wire [DC_IW - 1 : 0]     st_set_w;                   // ---- 第 9 节: store 退休口 ----
    wire [TAG_W - 1 : 0]     st_tag_w;
    wire [OFF_W - 1 : 0]     st_word_w;
    wire [DC_WAYS - 1 : 0]   st_hit_g;
    wire [WY_W - 1 : 0]      st_way_w;
    wire                     any_st_hit_w, st_cacheable_w;   // ---- 第 5 节: 写回 ----
    wire                     wb_cap_w;                   // 本拍用读口把受害行整行捕获进缓冲
    wire                     wb_buf_busy_w;              // WB 数据缓冲被占 (新捕获无处放)
    wire                     wb_line_busy_w;             // 本行在飞 (捕获/排水/等 B): 内存可能还是旧值
    wire                     vic_v_w, vic_dirty_w;       // 受害路此刻有效? 脏?
    wire                     wb_last_push_w, wb_done_w;
    // ---- 第 9 节: store 命中吸收 (整路写粒度 ⇒ **一律**读-改-写, 整字与部分字同一条路) ----
    // ★ 刀 U (2026-10-11): 读-改-写分两支 —— `rmw_now_w` = 回包那拍 (探针那一读**就是**读相, 整路已在
    //   `rdata_w` 上, 直接合成); `rmw_rd_w` = 答案来自**锁存**那一支 (才需要单独占读口取整路)。
    wire                     rmw_rd_w, rmw_wr_w, rmw_hold_w, rmw_now_w;
    wire                     st_tm_lat_w, st_hit_lat_w, st_vic_lat_now_w;   // 只用锁存状态的命中判定 (无 rdata)
    wire [WY_W - 1 : 0]      st_way_lat_w;
    wire [DC_WAYS - 1 : 0]   st_hit_lat_g;
    wire [WMASK_W - 1 : 0]   rmw_wmask_w;
    wire [32 * DC_LINE_WORDS - 1 : 0] rmw_data_new_w;    // 回包八字的**数据**+ 只替换命中的那个 word 槽
    wire [31 : 0]            rmw_tag_old_w;              // 回包那一路的 tag 槽 (原样写回)
    wire [31 : 0]            rmw_merge_w;

    // ---- tag 探针 (定义在第 3 节): 这几根被更早的 `rd_addr_w` / 探针请求引用 ⇒ 前向声明放这里 ----
    wire                     probe_go_w;                 // 本拍有探针读要发出
    wire [31 : 0]            probe_addr_w;               // 探针读口地址 (只有组号有意义)
    wire                     st_tm_ok_w;                 // store 探针的答案可用且对的正是本拍这个地址
    wire                     pfc_same_w;                 // 预取存在性回答正是本拍排队的那条
    wire [TAG_W - 1 : 0]     fill_tag_w;                 // 本次填充行的 tag

    // ==================== 2. 顺序状态 ====================
    // 查表寄存器 (skid 就是它): 接受时写入, 结果被消化 (交付/推出) 才释放
    reg  [31 : 0]            lk_addr_r;
    reg  [1 : 0]             lk_width_r;
    reg  [LIW - 1 : 0]       lk_idx_r;
    reg                      lk_v_r;                     // 本拍有一个查表结果待解释
    reg                      lk_miss_r;                  // 该结果已判缺失并保持 (SRAM 数据已失效)
    reg                      lk_wait_r;                  // 该 load 已并入在填行, 等填充完成
    reg                      lk_replay_r;                // 本拍在读口上重放 lk_addr_r (下一拍才判定)
    reg  [31 : 0]            rd_addr_q;                  // 上一拍摆上读口的地址 (tag 比较的另一半)
    reg                      rd_ok_r;                    // 上一拍的读没被写 (安装/store) 偷走
    reg  [DC_WAYS * DC_SETS - 1 : 0] valid_r;            // 行有效位图
    // ---- tag 探针 (取代 DFF tag 镜像; 规则见头注释【★ tag 探针】) ----
    reg                      stp_act_r;                  // 本拍 rdata_w 上正是 store 探针读回的一行
    reg  [DC_WAYS - 1 : 0]   st_tm_r;                    // 锁存: 那些 tag 比较的逐路结果
    reg  [TAG_W - 1 : 0]     st_tag_r;                   // 锁存: 比的是哪个 tag
    reg  [DC_IW - 1 : 0]     st_set_r;                   // 锁存: 比的是哪一组
    reg                      st_tm_v_r;                  // 锁存有效 (被 vset_w/fill_start_w 作废)
    reg  [TAG_W - 1 : 0]     stp_tag_r;                  // 发起那拍锁下的 tag (回包那拍比较用它)
    reg  [DC_IW - 1 : 0]     stp_set_r;
    reg                      fcp_act_r;                  // 本拍 rdata_w 上正是填充清理探针
    reg  [DC_WAYS - 1 : 0]   fc_tm_r;                    // 锁存: 填充行 tag 的逐路比较结果
    reg                      fc_tm_v_r;                  // 锁存有效 (每次填充重置)
    reg  [3 : 0]             probe_wait_r;               // 探针请求已等了几拍 (到阈值就硬抢)
    reg                      pfp_act_r;                  // 本拍 rdata_w 上正是预取存在性探针
    reg  [31 : 0]            pfp_base_r;                 // 发起那拍锁下的待查行基址
    reg  [TAG_W - 1 : 0]     pfp_tag_r;
    reg  [DC_IW - 1 : 0]     pfp_set_r;
    reg                      pfc_v_r;                    // 存在性回答已锁存
    reg  [31 : 0]            pfc_base_r;                 // 锁存回答对应的行基址
    reg                      pfc_present_r;              // 那行当时在不在
    reg  [DC_IW - 1 : 0]     fill_set_r;
    reg  [31 : 0]            fill_base_r;
    reg  [FIW - 1 : 0]       fill_word_r;                // 下一笔要发 AR 的行内字下标
    reg  [FIW - 1 : 0]       fill_cnt_r;                 // 已回包的字数 (同序 ⇒ 即本笔的字 lane)
    reg  [WY_W - 1 : 0]      fill_way_r;                 // 本次填充装进哪一路
    reg                      fill_busy_r;
    reg                      fill_poison_r;              // 粘滞: 途中出现过未落盘的同组 store
    // ---- 锥① 步1 + cut F: 填充"安装写"打一拍; 整路写 ⇒ 载荷是**整行缓冲** (见头注释) ----
    reg                      fill_wr_r;                  // 落盘拍: 本拍由 u_arr 落下这一路的安装写
    reg                      fill_vset_r;                // 落盘拍: 本笔落完即置 valid (vset 打拍)
    reg  [32 * DC_LINE_WORDS - 1 : 0] fill_buf_r;        // 整行缓冲: 第 w 字在 [w*32 +: 32]
                                                         // ★ 整路写必须八字齐备 ⇒ 回包逐字攒在这里;
                                                         //   旧的"落盘拍捕获那一个字"只在 32 位粒度够用
    reg  [31 : 0]            pf_base_r;                  // 待填行 (填充忙时排队的 1 条)
    reg                      pf_v_r;
    // ---- 下一行预取 (M5): 1 槽排队 + 组合存在性查 (DC_PREFETCH=0 时整块被综合优化掉) ----
    reg                      dpf_v_r;                    // 排队着一条预取
    reg  [31 : 0]            dpf_base_r;                 // 预取行基址
    // ---- store 读-改-写 (第 9 节): 读相 → 合成 → 写相 (整字与部分字同一条路) ----
    reg                      rmw_rd1_r;                  // 读相后一拍: rdata_w 上正是命中路的整路原文
    reg                      rmw_v_r;                    // 整路已合成, 本拍落盘 (写口选择端 = 它)
    reg  [DC_IW - 1 : 0]     rmw_set_r;
    reg  [WY_W - 1 : 0]      rmw_way_r;
    reg  [OFF_W - 1 : 0]     rmw_woff_r;
    reg  [31 : 0]            rmw_tag_r;                  // 刀 O: 只剩 tag 槽分源 (数据 256 位并进 fill_buf_r)
    // ---- 写回: 脏位 + 一份行缓冲 (捕获 → 排水 → 等 B) ----
    reg  [DC_WAYS * DC_SETS - 1 : 0] dirty_r;            // 行脏位 (无复位: 一切读取都由 valid_r 门控)
    reg                      wbc_pend_r;                 // 起填那拍发现受害路脏 ⇒ 本拍把整行读进缓冲
    reg                      wbc_lat_r;                  // 捕获读的回包拍 (SRAM 同步读 ⇒ 比读口晚一拍)
    reg  [DC_IW - 1 : 0]     wbc_set_r;
    reg  [WY_W - 1 : 0]      wbc_way_r;
    reg  [31 : 0]            wb_base_r;                  // 在飞行 (或被捕获) 的行基址
    reg                      wb_tag_v_r;                 // wb_base_r 的 tag 字段已知 (受害行 tag 要等捕获读回包)
    reg                      wb_v_r;                     // 缓冲有整行数据, 还没推完
    reg  [BIW - 1 : 0]       wb_beat_r;                  // 下一笔要推的行内字下标
    reg  [32 * DC_LINE_WORDS - 1 : 0] wb_data_r;         // 整行快照 (8×32 = 256 flop)
    reg                      wb_hold_r;                  // 8 笔已推完, 等 B 全回
    reg  [FIW - 1 : 0]       wb_bcnt_r;                  // 已回的 B 数

    // ==================== 3. 查表地址与结果 ====================
    // 重放那一拍把 lk_addr_r 摆回去; 其余拍用上层给的候选地址 (本拍要接受的那条)。
    // ★ WB 捕获读**抢占**读口 (它只有这一拍机会): 被它偷走的查表读由 rd_ok_r=0 变成重放, 不判缺失。
    // ★ 部分字 store 的读-改-写读**次之** (只取组号, 地址低位的组内偏移无意义); 被它偷走的查表读
    //   同样靠 rd_ok_r=0 重放。它**必须让** WB 捕获读 —— 那笔读只有一次机会, 错过就是丢一条脏行。
    // ★ tag 探针排在最底, 但**抢的那次必须真的拿到口**: 走空槽 (`probe_slot_w`) 时本来就没人口用,
    //   排哪儿都等价; 硬抢 (`probe_steal_w`) 时正是有 load 要被接受的那拍 —— 于是它必须压过 `lk_addr`,
    //   而被压掉的那笔查表读由 `rd_ok_r=0` 走重放。`lk_replay_r` 那拍与四种不可重放的读都被
    //   `probe_hold_w` 挡在门外 ⇒ 与它们的先后无关。
    assign rd_addr_w = wb_cap_w ? wb_base_r
                     : (rmw_rd_w ? st_addr
                     : (lk_replay_r ? lk_addr_r
                     : (probe_go_w ? probe_addr_w : lk_addr)));
    assign rd_set_w  = ONE_SET ? {DC_IW{1'b0}} : rd_addr_w[TAGHI - 1 : SPLIT];
    assign q_set_w   = ONE_SET ? {DC_IW{1'b0}} : rd_addr_q[TAGHI - 1 : SPLIT];
    assign q_off_w   = rd_addr_q[SPLIT - 1 : 2];
    assign rd_tag_w  = rd_addr_q[TAGHI +: TAG_W];

    // ---- tag 探针: 三个用户共用一次读口 (机制见头注释【★ tag 探针】) ----
    // 要查 SRAM 里那份 tag 的只有三件事, 且都是"提前一拍问、下一拍才有答案":
    //   ① store 退休的命中判定  ② 填充安装时的"同组重复 tag"清理  ③ 预取存在性
    // ★ ② 能"每次填充只查一次就够"的依据: 一次填充在飞时同组的 valid/tag **冻结** —— 别的填充被
    //   `fill_busy_r` 挡住, store 吸收只动 dirty ⇒ 填充期间任何一拍查到的答案到安装那拍都还成立。
    wire                   stp_req_w = st_valid && !st_tm_ok_w && !stp_act_r;
    wire                   fcp_req_w = fill_busy_r && !fc_tm_v_r && !fcp_act_r;
    wire                   pfp_req_w = (DC_PREFETCH != 0) && dpf_v_r && !pfc_same_w && !pfp_act_r;
    wire                   probe_req_w = stp_req_w || fcp_req_w || pfp_req_w;
    // ★ 首选**真空闲**的槽: 这一拍没人会看读口的结果 ⇒ 探针不偷任何人的读 ⇒ `rd_ok_r` 不必为它置 0
    //   (省掉一次重放)。四项缺一不可, 少一项就是"偷"。
    // ★ 硬抢 (等不到空槽): 被抢的那笔查表读靠 `rd_ok_r=0` 走重放 (+2 拍), 只慢不错。抢也必须避开
    //   四种**不可重放**的读: WB 捕获 (只有一次机会) / 读-改-写取老字 / 写周期 (rdata=x) / 重放那一拍
    //   (FSM 在重放支不为它看 rd_ok_r ⇒ 被抢就是静默错值)。
    wire                   probe_hold_w = !lk_replay_r && !wb_cap_w && !rmw_rd_w && !sram_we_w;
    wire                   probe_slot_w = !lk_valid && !(lk_v_r && !lk_wait_r) && probe_hold_w;
    // 优先级: store 退休 (SQ 在等) > 填充清理 (不变量) > 预取 (机会性, 丢了不亏)。
    // 抢的阈值按"这个用户能等多久"给: 填充清理只等 2 拍 (它每次填充只有一次机会), 另两个等 8 拍。
    wire                   stp_go_w = stp_req_w && (probe_slot_w || (probe_wait_r[2] && probe_hold_w));
    wire                   fcp_go_w = fcp_req_w && !stp_go_w
                                   && (probe_slot_w || (probe_wait_r[1] && probe_hold_w));
    wire                   pfp_go_w = pfp_req_w && !stp_go_w && !fcp_go_w
                                   && (probe_slot_w || (probe_wait_r[2] && probe_hold_w));
    assign                 probe_go_w  = stp_go_w || fcp_go_w || pfp_go_w;
    // 这一次是"抢"的 ⇒ 下一拍那笔被顶掉的查表读必须重放 (只有走空槽那次才不偷)
    wire                   probe_steal_w = probe_go_w && !probe_slot_w;
    // 地址只有组号有意义 (读回来的是整行, tag 槽照读); 给 0 基址即可, 组号必须是真的。
    assign                 probe_addr_w = {{(32 - TAGHI){1'b0}},
                                           stp_go_w ? st_set_w : (fcp_go_w ? fill_set_r : pf_set_w),
                                           {SPLIT{1'b0}}};
    // ---- ① store 探针的结果 ----
    // 回包那拍的比较必须用**发起时锁下的** tag —— 这一拍 st_addr 可能已经换成下一条 store 了
    // (上一条在发起那拍走了旁路, sq_iss_p 当场前进)。
    wire [TAG_W - 1 : 0]   st_probe_tag_w = stp_act_r ? stp_tag_r : st_tag_w;
    wire [DC_WAYS - 1 : 0] st_tm_now_w;
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : stcmp
            assign st_tm_now_w[gj] = (rdata_w[gj * WAY_W + TAGOFF +: TAG_W] == st_probe_tag_w);
        end
    endgenerate
    // ★ 回包那拍必须再核一次"问的还是本拍这个地址吗": 发起那拍 `any_st_hit_w` 还是 0, 队首那条
    //   不可缓存 store 会**当场走旁路** ⇒ `sq_iss_p` 前进 ⇒ 本拍 `st_addr` 已经换了人。换了就
    //   不采用 (下一拍重发探针), 绝不把上一笔的答案安到下一笔头上。
    wire                   st_tm_same_w = (stp_set_r == st_set_w) && (stp_tag_r == st_tag_w);
    // 采用条件: 结果这拍刚到且地址没换, 或者锁存还在且**问的还是同一个地址**。
    wire                   st_tm_live_w = stp_act_r && st_tm_same_w;
    // ★ 刀 U: 后一项单立 (它**只含寄存器**, 无 rdata) —— 读相判决 (`rmw_rd_w`) 用它, 好让
    //   "rdata → 比较器 → 命中 → 占读口 → 地址" 这条一拍闭环在结构上不存在 (见第 9 节注释)。
    assign                 st_tm_lat_w = st_tm_v_r && (st_set_r == st_set_w) && (st_tag_r == st_tag_w);
    assign                 st_tm_ok_w = st_tm_live_w || st_tm_lat_w;
    // ★ 探针没答出来 (刚发出/刚换地址) 时**两条出路都不许抬** —— 否则"还没查就判缺失"会把一条
    //   本该吸收的 store 旁路到内存 (缓存行不置脏, 之后换出时把旧值写回去) = 静默算错。
    //   不可缓存的 (MMIO) 例外: 它本来就必上总线, 不需要 tag 比较。
    wire                   st_ready_w = st_tm_ok_w || !st_cacheable_w;
    wire [DC_WAYS - 1 : 0] st_tm_sel_w = st_tm_live_w ? st_tm_now_w : st_tm_r;
    // ---- ② 填充清理探针的结果 (比的是本次填充行的 tag, 那一组在填充期间冻结 ⇒ 不必锁地址) ----
    wire [DC_WAYS - 1 : 0] fc_tm_now_w;
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : fccmp
            assign fc_tm_now_w[gj] = (rdata_w[gj * WAY_W + TAGOFF +: TAG_W] == fill_tag_w);
        end
    endgenerate
    // ---- ③ 预取存在性探针的结果 ----
    wire [TAG_W - 1 : 0]   pf_probe_tag_w = pfp_act_r ? pfp_tag_r : pf_tag_w;
    wire [DC_IW - 1 : 0]   pf_probe_set_w = pfp_act_r ? pfp_set_r : pf_set_w;
    wire [DC_WAYS - 1 : 0] pfp_hit_w, pfp_val_w;
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : pfcmp
            assign pfp_hit_w[gj] = (rdata_w[gj * WAY_W + TAGOFF +: TAG_W] == pf_probe_tag_w);
            assign pfp_val_w[gj] = valid_r[gj * DC_SETS + pf_probe_set_w];
        end
    endgenerate
    assign                 pfc_same_w   = pfc_v_r && (pfc_base_r == dpf_base_r);
    wire                   pf_present_w = pfc_same_w && pfc_present_r;

    // 探针时序: 发起那拍锁"问的是什么", 回包那拍锁"答的是什么", 外加饿死计时。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stp_act_r <= 1'b0;  fcp_act_r <= 1'b0;  pfp_act_r <= 1'b0;
            st_tm_v_r <= 1'b0;  fc_tm_v_r <= 1'b0;  pfc_v_r   <= 1'b0;
            st_tm_r   <= {DC_WAYS{1'b0}};            fc_tm_r  <= {DC_WAYS{1'b0}};
            st_tag_r  <= {TAG_W{1'b0}};  st_set_r  <= {DC_IW{1'b0}};
            stp_tag_r <= {TAG_W{1'b0}};  stp_set_r <= {DC_IW{1'b0}};
            pfp_base_r <= 32'd0;  pfp_tag_r <= {TAG_W{1'b0}};  pfp_set_r <= {DC_IW{1'b0}};
            pfc_base_r <= 32'd0;  pfc_present_r <= 1'b0;
            probe_wait_r <= 4'd0;
        end else begin
            stp_act_r <= stp_go_w;
            fcp_act_r <= fcp_go_w;
            pfp_act_r <= pfp_go_w;
            if (stp_go_w) begin                 // 发起: 锁下"问的是哪个 tag / 哪一组"
                stp_tag_r <= st_tag_w;
                stp_set_r <= st_set_w;
            end
            if (pfp_go_w) begin
                pfp_base_r <= dpf_base_r;
                pfp_tag_r  <= pf_tag_w;
                pfp_set_r  <= pf_set_w;
            end
            if (st_tm_live_w) begin             // 回包且地址没换: 就是本拍 rdata_w 上那一行
                st_tm_r   <= st_tm_now_w;
                st_tag_r  <= stp_tag_r;
                st_set_r  <= stp_set_r;
                st_tm_v_r <= 1'b1;
            end
            if (fcp_act_r) begin
                fc_tm_r   <= fc_tm_now_w;
                fc_tm_v_r <= 1'b1;
            end
            if (pfp_act_r) begin
                pfc_base_r    <= pfp_base_r;
                pfc_present_r <= |(pfp_hit_w & pfp_val_w);
                pfc_v_r       <= 1'b1;
            end
            // ★ 锁存作废 —— 放在最后, 与上面几支同拍时以"作废"为准 (安装/驱逐都可能让"本行还在不在"
            //   变了, 陈旧回答一律不许用; 重查一次的代价远小于用错的代价)。
            //   · 三个用户全在 `fill_vset_r` 作废 (新行真的装进去了 —— 那是落盘拍, 见头注释锥 ①)。
            //   · `fill_start_w` 清受害路 valid: store / 填充清理两个锁存跟着作废; 预取那个**不**作废 ——
            //     它只会让"在"变"不在", 而陈旧回答仍偏"在" ⇒ 至多少发一次预取 (安全方向)。
            //   · `fill_start_w` 还要重置填充清理的那个: 上一次填充可能被污染中止 (没走到 vset_w),
            //     答案属于上一次填充, 不能给下一次用。
            //   · 作废口径 = **全局**: 任何填充事件都作废, 不比组号。作废得更多只会多查一次探针
            //     (`st_tm_ok_w`=0 ⇒ 本拍让路、下一拍重查), 不会让陈旧答案活下来 —— 方向保守。
            //     §3.17 曾在比较器里堵"回包恰落在安装拍": 那次探针读的是**安装前**的 tag 阵列 ⇒
            //     假"未命中" ⇒ store 被判旁路写内存, 而下一拍装上的行里仍是内存旧值 ⇒ 后来该行
            //     换出把旧值盖回 RAM = 静默算错 (qsort 退出值 1080)。**全局作废本来就覆盖这一次**
            //     (安装拍必有 vset/fill_start ⇒ 一律作废) ⇒ 那个比较器是多余的, 刀 L 删掉它
            //     (值 +1 个 5 位相等, 被怀疑是头名那片 237 脚云的来源; cutJ↔cutH 对照见 plan §3.20)。
            //     ~~只作废被碰到的那一组~~ 留痕: ~~"同组收窄省掉真无必要的作废"~~ 该因果已被
            //     [§44] §11.3 证伪 (作废不是 vvadd −10.9% 的成因, 真因是**预取存在性探针**),
            //     别再引用它解释 vvadd。
            if (vset_w || fill_vset_r || fill_start_w) st_tm_v_r <= 1'b0;
            // ★ 填充清理的锁存**只**在起填拍重置 (不跟 vset): 它的消费者是不变量 1 那次清理, 而
            //   清理挪到了**落盘拍** (锥 ①) —— 在判决拍就清等于把这次填充的清理一起清掉。
            //   失效面不变: 上一次填充若被污染中止 (没走到 vset), 下一次起填仍会重置它。
            if (fill_start_w) fc_tm_v_r <= 1'b0;
            if ((vset_w || fill_vset_r) && (fill_set_r == pfc_base_r[TAGHI - 1 : SPLIT])) pfc_v_r <= 1'b0;
            // 饿死计时: 有请求没人伺候就涨, 一发出就清零 (清零那拍若无请求也自然归零)
            if (probe_go_w || !probe_req_w) probe_wait_r <= 4'd0;
            else if (!probe_wait_r[3])      probe_wait_r <= probe_wait_r + 1'b1;
        end
    end

    // 每一路的 tag 与 valid 并行比较 (一拍读出所有路 —— 这就是 1 个读口能支持多路的原因)
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : waycmp
            wire [TAG_W - 1 : 0] wtag_w = rdata_w[gj * WAY_W + TAGOFF +: TAG_W];
            assign way_hit_g[gj] = (wtag_w == rd_tag_w) && valid_r[gj * DC_SETS + q_set_w];
        end
    endgenerate

    // 命中路编码: 任一相联度通用 (命中互斥 ⇒ 优先级无关, 只取"有命中"的那一路)
    function [WY_W - 1 : 0] hitway_f;
        input [DC_WAYS - 1 : 0] wh;
        integer hk;
        begin
            hitway_f = {WY_W{1'b0}};
            for (hk = 0; hk < DC_WAYS; hk = hk + 1)
                if (wh[hk]) hitway_f = hk[WY_W - 1 : 0];
        end
    endfunction
    assign hit_way_w = hitway_f(way_hit_g);

    // 宽度编码 (00=1 01=2 10=4 字节) → 字内 4 个字节的选通掩码 (与 mem_subsystem 的 wd_mask 同口径)
    function [3 : 0] wd_mask4;
        input [1 : 0] w;
        begin
            wd_mask4 = (w == 2'b10) ? 4'hf : (w == 2'b01) ? 4'h3 : 4'h1;
        end
    endfunction

    assign any_hit_w  = !DC_OFF && (|way_hit_g);
    // 命中判定: rd_addr_q 就是 T−1 拍摆上读口的那个地址 ⇒ rdata_w 与 tag/valid 必然同源
    assign hit_raw_w  = lk_v_r && !lk_miss_r && !lk_wait_r && !lk_replay_r && rd_ok_r && any_hit_w;
    assign hit_word_w = rdata_w[hit_way_w * WAY_W + q_off_w * 32 +: 32];

    // 交付源 = {命中判定} ∪ {M2 填充数据旁路}; 两者互斥 (byp_* 要 lk_wait_r, hit_raw_w 要 !lk_wait_r),
    // 且各自都被 !rsp_busy 挡一道 ⇒ 与 AXI 回包也互斥 ⇒ "每拍恰好一个 ld_done_valid" 仍然成立。
    assign hit_valid = (hit_raw_w && !rsp_busy) || byp_valid_w;
    assign hit_word  = byp_valid_w ? fill_rsp_data : hit_word_w;   // 旁路: 本拍回包的那个字就是它要的
    assign hit_addr  = byp_valid_w ? lk_addr_r     : rd_addr_q;
    assign hit_width = lk_width_r;                       // 两条路的 width/idx 同源 (都取自 lk_*_r)
    assign hit_idx   = lk_idx_r;

    // ==================== 4. 缺失推送 / 合并 / skid ====================
    // 抢输的命中落进 miss_pending (靠 AXI 重取)。★ `rd_ok_r` 这一项把"读被写偷走"挡在外面 ——
    //   那不是缺失, 是**重放** (第 6 节)。若放它进来, 上面那层 mem_subsystem 会跟着 ms_valid
    //   把这一笔压进 miss 队列并发 AR (它的 dc_ms_fire_w 只认 ms_valid && ms_ready), 而本模块
    //   并不清 lk_v_r ⇒ 同一笔 load 会**发两次 AR、回两个完成脉冲** ⇒ LSQ 的 idx 彻底错位。
    // ★ 只推**真缺失** (`!hit_raw_w`)。命中但交付口被占 (rsp_busy) **不是**缺失: 写回下让它走 AXI
    //   会读到"落后于脏行的内存值" (该行的新字节只存在于缓存里) ⇒ 静默算错。它必须重放 (第 6 节)。
    //   写直达下这条降级是安全的 (内存恒新鲜), 写回下必须改 —— 这是不变量 3 的第三处落点。
    assign miss_pending_w = lk_v_r && !lk_wait_r && !lk_replay_r && rd_ok_r && !hit_raw_w;
    assign same_line_w    = (lk_addr_r[31 : SPLIT] == fill_base_r[31 : SPLIT]);
    assign lk_same_fill_w = fill_busy_r && same_line_w;
    // ★ 写回在飞行的行 vs 另一条地址: `wb_base_r` 的 tag 有**两拍未知窗口** (受害行 tag 要等捕获读
    //   回包 —— 它不在镜像里了)。未知时只比组号 = 一律当作"同一行" ⇒ 方向保守 (多让一条 load 并入
    //   写回, 只慢不错)。反过来比错才是致命的: 漏判同行 ⇒ 该 load 去发 AR, 读回落后于脏行的内存值。
    assign lk_wb_wait_w   = wb_line_busy_w && (wb_tag_v_r ? (lk_addr_r[31 : SPLIT] == wb_base_r[31 : SPLIT])
                                                          : (lk_addr_r[TAGHI - 1 : SPLIT] == wb_base_r[TAGHI - 1 : SPLIT]));
    assign lk_cacheable_w = (lk_addr_r[31 : 28] == 4'h0);   // AXI 内存只到 0x0fffffff ⇒ 高位非 0 = MMIO
    // 该行正在填 / 正在写回 ⇒ 不重复发 AR, 等它结束再重放 (否则 32 B 行每行多 8 笔重复 AR, 顺序流必中)
    // ★ WB 那一项是写回特有的: 行刚被驱逐、脏数据还在缓冲里没落盘, 此刻发 AR 读回的是旧值。
    assign lk_wait_src_w  = lk_same_fill_w || lk_wb_wait_w;
    assign coalesce_w     = miss_pending_w && lk_wait_src_w && !DC_OFF;
    assign ms_fire_w      = miss_pending_w && !coalesce_w && ms_ready;

    assign ms_valid = miss_pending_w && !coalesce_w;
    assign ms_addr  = lk_addr_r;                         // 原始字节地址, 对齐由上层做
    assign ms_width = lk_width_r;
    assign ms_idx   = lk_idx_r;

    // ==================== 5. 填充器 (单 MSHR + 1 条排队) ====================
    // ---- 下一行预取 (M5; 详细论证见头注释) ----
    // dc_fill_line_w = **需求侧**要填的行 (排队那条优先), 不含预取项 ⇒ 与 fill_blk_w 无组合环;
    //   dc_demand_w 也刻意不含 fill_blk_w / rmw_hold_w (那两项要靠 fill_base_new_w 算) ⇒ 无环。
    assign dc_fill_line_w = (pf_v_r && !fill_busy_r) ? pf_base_r
                                                     : {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
    assign dc_demand_w    = miss_pending_w && !coalesce_w && !DC_OFF && lk_cacheable_w;
    // 触发: =1 需求缺失**真起填**那拍 (=2 用一次**命中交付**那拍) ⇒ 登记它的下一行
    assign pf_trig_w      = (DC_PREFETCH == 1) ? (fill_go_w || pf_start_w)
                          : ((DC_PREFETCH == 2) ? (hit_valid && lk_cacheable_w) : 1'b0);
    assign pf_base_w      = ((DC_PREFETCH == 1) ? dc_fill_line_w
                                                : {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}})
                          + (DC_LINE_WORDS * 4);
    // 存在性查: 待查行的组号/tag (探针的发起侧地址就是它) + 可缓存 (AXI 内存只到 0x0fffffff)
    assign pf_set_w = ONE_SET ? {DC_IW{1'b0}} : dpf_base_r[TAGHI - 1 : SPLIT];
    assign pf_tag_w = dpf_base_r[TAGHI +: TAG_W];
    // 起填条件: 排队有效 + **查过了** (`pfc_same_w`) + 目标确实不在 + 可缓存 + 引擎空闲 + 无需求在等。
    //   ★ `pfc_same_w` 不能省: 没查过时 pf_present_w 恒 0, 省了就成了"不查即起填" —— 而存在性检查
    //     是硬要求 (对已驻留行再起填会静默作废另一路的脏副本, 见头注释)。没查过就等下一拍。
    assign dpf_sel_w   = (DC_PREFETCH != 0) && dpf_v_r && pfc_same_w && !pf_present_w
                      && (dpf_base_r[31 : 28] == 4'h0)
                      && !fill_busy_r && !pf_v_r && !dc_demand_w;
    assign dpf_start_w = dpf_sel_w && !fill_blk_w && !rmw_hold_w && !fill_vic_hit_w;
    assign fill_base_new_w = dpf_sel_w ? dpf_base_r
                          : ((pf_v_r && !fill_busy_r) ? pf_base_r
                                                     : {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}});
    assign new_set_w       = ONE_SET ? {DC_IW{1'b0}} : fill_base_new_w[TAGHI - 1 : SPLIT];

    // ---- 写回状态 (捕获 → 排水 → 等 B); 三者的定义与"谁给谁让路"见头注释第五条 ----
    assign wb_cap_w       = wbc_pend_r;                  // 本拍用读口把受害行整行读进缓冲
    // wb_buf_busy_w 必须含 wb_hold_r: 新捕获在 wbc_lat_r 那拍会清零 wb_beat_r/wb_bcnt_r, 而这两个
    // 计数器正被"等 B"段共用 —— 中途清零 ⇒ wb_done_w 提前 ⇒ wb_line_busy_w 提前撤, 上一行的写拍
    // 还在 AXI 写 FIFO 里, 同一行随后的填充就会读回旧值 (dbg1 实测 230 次 cap-while-hold)。
    assign wb_buf_busy_w  = wbc_pend_r || wbc_lat_r || wb_v_r || wb_hold_r;  // 数据缓冲被占 (新捕获无处放; 含等 B 段)
    assign wb_line_busy_w = wbc_pend_r || wbc_lat_r || wb_v_r || wb_hold_r;  // 本行在飞
    assign wb_req_valid   = wb_v_r;
    assign wb_req_addr    = wb_base_r + {wb_beat_r, 2'b00};
    assign wb_req_data    = wb_data_r[wb_beat_r * 32 +: 32];
    assign wb_last_push_w = wb_req_valid && wb_req_ready && (wb_beat_r == DC_LINE_WORDS - 1);
    assign wb_done_w      = wb_resp_valid && (wb_bcnt_r == DC_LINE_WORDS - 1);

    // ---- 起填门控 (写回新增) ----
    assign vic_v_w     = valid_r[victim_way_w * DC_SETS + new_set_w];
    assign vic_dirty_w = dirty_r[victim_way_w * DC_SETS + new_set_w];
    // ★ 受害行的 tag **不在这里取** (原来查 tag 镜像) —— 它随 WB 捕获读的那份回包一起回来, 见第 8 节
    //   `wbc_lat_r` 那支。起填那拍把 `wb_base_r` 先写成"组号对、tag 待填", 用 `wb_tag_v_r` 标出未知窗口。
    // 起填被写回挡住的两种情况: ①同一行还在飞 (内存此刻可能还是旧值) ②要驱逐脏行但缓冲被占。
    // 被挡住时让"排队的那条"接住 (fill_pend_w), 不白丢一次填充机会 —— 当前这条 miss 的 AR 照发。
    // ③部分字 store 的读-改-写窗口 (rmw_hold_w): 此刻起填可能把**它正要改写的那一路**选作受害路,
    //   行一朝被清 valid, 那笔已经读出老字、还没来得及落盘的 store 就写进了一条无效行(静默丢数据)。
    //   被挡住的 miss 落进 fill_pend_w ⇒ 排队等窗口结束, 不丢。
    //   ★ 同行比较同样带 tag 未知窗口 (保守 = 只多挡): 起填若撞上未知窗口, 同组一律当同行, 推迟一拍
    //     —— 那一拍过后 tag 就到了 (受害行 tag 由捕获读回包给出)。
    assign fill_blk_w  = (wb_line_busy_w && (wb_tag_v_r ? (wb_base_r[31 : SPLIT] == fill_base_new_w[31 : SPLIT])
                                                        : (wb_base_r[TAGHI - 1 : SPLIT] == fill_base_new_w[TAGHI - 1 : SPLIT])))
                      || (wb_buf_busy_w && vic_v_w && vic_dirty_w);
    // ★ 落盘拍不许起的两种新填充 (`fill_vic_hit_w`) —— 都是"这一拍才装进去的行/槽, 检查看不见":
    //   ① 同 (组,路): 同拍 `fill_vset_r` 会把该槽 valid 置 1, 而 always 块里"起填清受害路"在前、
    //      "vset 置位"在后 ⇒ vset 赢 ⇒ 新填充往一条刚标 valid 的行里灌 tag/数据 (命中读到半行)。
    //   ② 同行 (同组**且同 tag**): 起填的存在性检查 (需求靠上一拍的 `any_hit_w`, 预取靠探针锁存)
    //      都看的是一拍前/本拍开头的 `valid_r` —— 而这一行的 valid **正在本拍拍末**才置 1
    //      ⇒ 漏看 ⇒ 对刚装上的行再填一次 ⇒ victim 落到另一路 ⇒ 它安装时的不变量 1 清理把那一份
    //      (可能已脏) 静默作废。必须比 **tag** 而不是只比路: 同组另一路无效时 victim 正好选那一路。
    //   同组异 tag 的行与本笔安装无关 ⇒ 照起 (不白让一拍)。让一拍的那条下一拍就命中, 不亏。
    assign fill_vic_hit_w = fill_wr_r && (fill_set_r == new_set_w)
                         && ((fill_way_r == victim_way_w) || (fill_tag_w == fill_base_new_w[TAGHI +: TAG_W]));
    assign fill_go_w   = dc_demand_w && !fill_busy_r && !pf_v_r && !fill_blk_w && !rmw_hold_w && !fill_vic_hit_w;
    assign fill_pend_w = miss_pending_w && !coalesce_w && !fill_go_w && !DC_OFF && lk_cacheable_w;
    assign pf_start_w   = pf_v_r && !fill_busy_r && !fill_blk_w && !rmw_hold_w && !fill_vic_hit_w;   // 本拍起填的正是排队那条
    // 三个起填理由 (互斥): 排队的那条需求 > 本拍的需求 > 预取 (预取只在无需求、无排队时才有 dpf_sel_w)
    assign fill_start_w = pf_start_w || fill_go_w || dpf_start_w;

    // ★ 被污染的填充不再发新 AR。污染后回包一定被丢弃 (见下面 fill_wr_w), 再发就是白占读通道
    //   —— A2 实测读通道占用已到 46~78%, 是三个读用户共享的瓶颈。实测污染率: towers 35% /
    //   qsort 48% / rsort 75% 的行首, 且 rsort 有 65% 是**填充途中**才污染 ⇒ 省下的是行尾那几笔。
    //   **已发出的**必须收完: 回包与 AR 一一对应, 漏收的会被下一次填充当成自己的响应 (字下标错位)。
    //   故收尾分两支: 正常 = 收满一行; 中止 = 已发数 == 已回数 (无在飞)。
    //   ★ 中止且无在飞时必须**当拍**收尾, 不能等回包 —— 否则 fill_last_w 永不置位、fill_busy_r
    //     恒 1, 该组再也起不了填充 (又是"脉冲当电平用", 与 Bug B 同形状)。
    assign fill_abort_w    = fill_busy_r && (fill_poison_r || fill_poison_now_w);
    assign fill_inflight_w = fill_word_r - fill_cnt_r;
    assign fill_req_valid = fill_busy_r && (fill_word_r != DC_LINE_WORDS) && !fill_abort_w;
    assign fill_req_addr  = fill_base_r + {{(30 - OFF_W){1'b0}}, fill_word_r[OFF_W - 1 : 0], 2'b00};
    assign fill_busy      = fill_busy_r;
    assign fill_hs_w      = fill_req_valid && fill_req_ready;
    assign fill_last_w    = fill_abort_w ? (fill_inflight_w == {FIW{1'b0}})
                                         : (fill_rsp_valid && (fill_cnt_r == DC_LINE_WORDS - 1));

    // ★ 污染: 填充期间任一拍发现"尚未可见 (未吸收且未落盘) 的 store"落在**本行** ⇒ 本次填充作废
    assign fill_poison_now_w = fill_busy_r && fill_blk;
    // 写绝对优先 (回包不可反压); 被污染的填充连写都不写 (回包照收, 见 fill_abort_w)
    // ★ 这一位是**判决**, 落盘在 `fill_wr_r` 那一拍 (锥 ①)。
    // ★ 整路写粒度下**一笔填充只有一次装写**: 八字回包逐字攒进 `fill_buf_r`, 到最后一字才整路落下
    //   (旧 32 位粒度是每字一篇、tag 槽重复写 8 次 ⇒ 写口占用 **8 拍 → 1 拍**)。
    //   ★ 判据必须仍取**回包口径**的 `fill_last_w` (内含 abort 那支), 不能图省事写成 `fill_cnt_r == 末`:
    //     abort 且已在飞清空时 last 为 1 而**没有回包**, 那样"last ⇒ 写"就会把没攒齐的半行冒充整行。
    assign fill_wr_w = fill_last_w && !fill_poison_r && !fill_poison_now_w;

    // ==================== 5b. 填充数据旁路 (M2) ====================
    // 并入在填行的那条 load 今天要**等整行安装完**才重放命中 (实测等 15.6~21.0 拍, 而一次填充
    // 只要 22 拍)。但回包是**按行内字序逐拍**来的, `fill_cnt_r` 就是本拍这个字的行内下标 ⇒
    // 第 W 拍回来的正是第 W 个字 ⇒ 等待者要的若正是这一个, 当拍就能交付, 不必等最后那个字。
    // ★ 交付判据 = `fill_wr_w` 的判据: 只交付"这一刻真会被写进行"的那个字。被污染的填充既不写
    //   SRAM 也不安装 (该行有未可见 store ⇒ 这些字节可能是旧值, 而合并链兜不住"store 已退役"
    //   的情形), 所以污染的字**一个都不许交付** —— 这一条与 fill_wr_w 同源, 不另立判据就不会漂。
    // ★ 只旁路**当拍回包的那一个字**: 早于等待者并入的字早已错过 (那时它还没进来), 只能走原路
    //   (等填充结束 → 重放 → 命中)。所以旁路是**纯加速**, 不改变任何一条 load 的交付义务。
    // ★★ **必须显式要求 lk_same_fill_w (= fill_busy_r && 整行 [31:SPLIT] 相同)** —— 只比行内字偏移
    //   是**错的**: lk_wait_r 有两个来源 (`lk_wait_src_w` = 等同行填充 | **等写回**), 等写回那条
    //   根本没有"在填的行就是我这一行"这回事, 别的行的填充只要字偏移撞上就会把**别人行的数据**
    //   交付出去。实测代价: perf_rsort 退出值 0→1 (rsort 写回密集, 撞上太正常)。
    //   教训: "等待者必然与填充同行"是没对着 RTL 核过的假设, 判据里必须自己带行身份。
    assign byp_word_w  = lk_same_fill_w && (fill_cnt_r == lk_addr_r[SPLIT - 1 : 2]);
    assign byp_raw_w   = lk_v_r && lk_wait_r && fill_rsp_valid && !fill_poison_r && !fill_poison_now_w
                      && byp_word_w;
    assign byp_valid_w = byp_raw_w && !rsp_busy;         // 抢不到交付口就退回原路 (填充照常收尾)
    // 掩码单位 = **1 lane = 一整路**: 掩码位号就是路号 (WMASK_W = DC_WAYS)。
    wire [WMASK_W - 1 : 0] b1_w = {{(WMASK_W - 1){1'b0}}, 1'b1};
    // ★ 填充安装: 只点亮本次填充那一路。载荷 = 整行缓冲 + **顶对齐的 tag 槽**
    //   (tag 槽是那个 32 位槽里最高的 TAG_W 位, 其余补 0 —— 与旧写法同构, 只是整路一起写)。
    //   下标与载荷全是寄存器 (`fill_way_r`/`fill_base_r`/`fill_buf_r`) ⇒ 宏口由 FF 直接驱动。
    wire [WAY_W - 1 : 0]   fill_pay_w   = {fill_base_r[31 : TAGHI], {(32 - TAG_W){1'b0}}, fill_buf_r};
    wire [WMASK_W - 1 : 0] fill_wmask_w = b1_w << fill_way_r;
    // store 就地更新 (一律读-改-写): 只覆盖命中路那一 lane。
    //   字节口径与 SQ/AXI 一致: 数据与掩码同左移 addr[1:0] 个字节 (mem_subsystem 的 wd_mask 同款);
    //   整字 store 必然对齐 (RV32I 口径) ⇒ 那 4 个字节落在同一 word 槽内。
    wire [3 : 0]           st_bmask_w   = wd_mask4(st_width) << st_addr[1 : 0];
    wire [31 : 0]          st_data_sh_w = st_data << {st_addr[1 : 0], 3'b000};
    // 老字在 rdata 上 (读相后一拍), 与该 store 的字节在**同一 word 槽**内按字节合并
    // ★ st_bmask_w 是**按字节**的 4 位选通 (与 SQ/AXI 同口径), 要展开成 32 位比特掩码才能与数据相与
    wire [31 : 0]          st_bmask_bits_w = {{8{st_bmask_w[3]}}, {8{st_bmask_w[2]}},
                                              {8{st_bmask_w[1]}}, {8{st_bmask_w[0]}}};
    // 整路载荷 = 回包里那一路的**原文**, 只把 store 命中的那个 word 槽换掉; tag 槽与其余 7 字原样带回
    //   (回包就是本路当时的全部内容 ⇒ 它们本来就是对的)。整字 store 也走这条: 那时
    //   `st_bmask_bits_w` 全 1 且移位为 0 ⇒ rmw_merge_w = st_data, 与"就地写整字"逐位等价。
    // ★ 刀 U: 位置分源 —— `rmw_now_w` 那拍整路就在 `rdata_w` 上, 位置取**本拍**的 st_way_w/st_word_w;
    //   读相那一支照旧取锁存的 `rmw_way_r`/`rmw_woff_r` (写相那拍 `rmw_now_w` 恒 0 ⇒ 两支不相撞)。
    wire [WY_W - 1 : 0]    rmw_way_sel_w  = rmw_now_w ? st_way_w  : rmw_way_r;
    wire [OFF_W - 1 : 0]   rmw_woff_sel_w = rmw_now_w ? st_word_w : rmw_woff_r;
    wire [WAY_W - 1 : 0]   rmw_pay_old_w = rdata_w[rmw_way_sel_w * WAY_W +: WAY_W];
    // ★ 老字是回包那一路的**子集** ⇒ 从 `rmw_pay_old_w` (288 位) 里选, 不从 `rdata_w` (576 位) 里选:
    //   同一个 mux 少一半输入 (两条写法逐位等价; 声明放前面是为了不引出隐式网)。
    wire [31 : 0]          rmw_old_w   = rmw_pay_old_w[rmw_woff_sel_w * 32 +: 32];
    assign rmw_merge_w = (rmw_old_w & ~st_bmask_bits_w) | (st_data_sh_w & st_bmask_bits_w);
    assign rmw_wmask_w = b1_w << rmw_way_sel_w;
    // ★ 刀 O: tag 槽**不进拼接** (它永不替换, 且与安装支分源) ⇒ 单立一根线给 `rmw_tag_r`,
    //   拼接只剩 8 个 word 槽 = 256 位 (原 9 槽 288 位)。
    assign rmw_tag_old_w = rmw_pay_old_w[DC_LINE_WORDS * 32 +: 32];
    generate
        for (gj = 0; gj < DC_LINE_WORDS; gj = gj + 1) begin : rmwsplice
            assign rmw_data_new_w[gj * 32 +: 32] =
                   (rmw_woff_sel_w == gj) ? rmw_merge_w : rmw_pay_old_w[gj * 32 +: 32];
        end
    endgenerate
    // SRAM 写口二选一: 安装 > store 读-改-写落盘。★ 刀 M/O 之后**两支不可能同拍** (见第 9 节
    //   `rmw_rd_w` 的窗口条件), 故选择端一律取寄存器 `rmw_v_r` (安装那支就是它的补) —— 与旧写法逐位等价,
    //   但把那 288 个载荷 mux 选通脚从 `fill_wr_r` (头名起点, 又挂在 `busy` 上) 整批搬走。
    // ★ **两组支路的 select 与载荷全部来自寄存器** (`fill_wr_r`/`fill_way_r`/`fill_set_r`/`fill_base_r`/
    //   `fill_buf_r` 与 `rmw_tag_r`/`rmw_way_r`/`rmw_set_r`) ⇒ 宏的 we/addr/wmask/wdata 四组脚全由 FF 驱动,
    //   §3.13 那两截 (40 脚 1.20 ns + 18 个宏脚 2.35 ns) 一起消失。唯一仍是活信号的 `rd_set_w` 只在无写时
    //   驱动读地址, 不进写口。
    assign sram_we_w = fill_wr_r || rmw_v_r;
    assign wmask_w   = rmw_v_r ? rmw_wmask_w : (fill_wr_r ? fill_wmask_w : {WMASK_W{1'b0}});
    // ★ 刀 O: 两支载荷**共用** `fill_buf_r` 的 256 位数据 (RMW 合成那拍直接写回它) ⇒ 载荷 mux 只剩
    //   末槽 32 位 tag (`rmw_tag_r` 来自回包那一路, `fill_pay_w[287:256]` 来自 fill_base_r)。
    //   逐位等价于旧的 `{rmw_v_r ? rmw_pay_r : fill_pay_w}` —— 旧 `rmw_pay_r` 的 8 个字槽本来就
    //   等于"回包原文只换命中字", 与写回同一个缓冲逐位同源。
    wire [WAY_W - 1 : 0] rmw_pay_w = {rmw_tag_r, fill_buf_r};
    assign wdata_w   = {DC_WAYS{rmw_v_r ? rmw_pay_w : fill_pay_w}};   // 每 lane 同一载荷, 掩码选 lane

    sram_fakeram #(
        .DEPTH             (DC_SETS),
        .WIDTH             (EW),
        .WRITE_GRANULARITY (WG)          // ★ 宏实例数 = EW/WG = DC_WAYS = 2 (见上面 WG 的论证)
    ) u_arr (
        .clk   (clk),
        .en    (1'b1),
        .we    (sram_we_w),
        .wmask (wmask_w),
        .addr  (rmw_v_r ? rmw_set_r
                        : (fill_wr_r ? fill_set_r : rd_set_w)),
        .wdata (wdata_w),
        .rdata (rdata_w)
    );

    // 受害者: 最低空路优先, 全满则用该组的替换指针 (DC_WAYS=1 时恒 0, 无指针;
    // 多路下 2 路是 LRU、>2 路退化成"最近安装路 +1"的轮转)
    function [WY_W - 1 : 0] victim_f;
        input [DC_WAYS - 1 : 0] sv;
        input [WY_W - 1 : 0]    rr;
        integer vk;
        begin
            victim_f = rr;
            for (vk = DC_WAYS - 1; vk >= 0; vk = vk - 1)   // 倒序 ⇒ 最低编号的空路最后写入, 即优先选它
                if (!sv[vk]) victim_f = vk[WY_W - 1 : 0];
        end
    endfunction
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : setv
            assign set_valid_w[gj] = valid_r[gj * DC_SETS + new_set_w];
        end
    endgenerate
    generate
        if (DC_WAYS == 1) begin : vic1
            assign victim_way_w = {WY_W{1'b0}};
        end else begin : vicN
            // 每组"下一个被替换的路号"。**命中也要翻转** (命中某路 ⇒ 受害者变成另一路):
            // 只认安装就等于**填充轮转 (FIFO)** —— 2 路下热点行每两次填充必被踢一次, 与它被
            // 命中多频繁无关。§十七 在 idxinv 下测不出差别 (组满占比 qsort 3.6% / rsort 2.9%,
            // 替换选择无从行使), 该节把"store 处理修好后必须重测"写成了欠账; 本节即那次重测。
            // 2 路下"命中路 +1"就是 LRU 路; rr_r 是早就存在的状态 ⇒ 零新增触发器、零新增口。
            // 同拍两次访问同组只认前一条 (两条都刚被用过, 谁当受害者都行) —— 罕见且无害。
            reg [DC_SETS * WY_W - 1 : 0] rr_r;           // 每组下一个被替换的路号 (仅多路才有)
            wire [WY_W - 1 : 0]          rr_w = rr_r[new_set_w * WY_W +: WY_W];
            assign victim_way_w = victim_f(set_valid_w, rr_w);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) rr_r <= {DC_SETS * WY_W{1'b0}};
                else if (fill_vset_r) rr_r[fill_set_r * WY_W +: WY_W] <= fill_way_r + 1'b1;
                else if (hit_raw_w)   rr_r[q_set_w    * WY_W +: WY_W] <= hit_way_w  + 1'b1;
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_busy_r   <= 1'b0;
            fill_set_r    <= {DC_IW{1'b0}};
            fill_base_r   <= 32'd0;
            fill_word_r   <= {FIW{1'b0}};
            fill_cnt_r    <= {FIW{1'b0}};
            fill_way_r    <= {WY_W{1'b0}};
            fill_poison_r <= 1'b0;
            fill_wr_r     <= 1'b0;
            fill_vset_r   <= 1'b0;
            pf_v_r        <= 1'b0;
            pf_base_r     <= 32'd0;
            dpf_v_r       <= 1'b0;
            dpf_base_r    <= 32'd0;
            wbc_pend_r    <= 1'b0;
            wbc_lat_r     <= 1'b0;
            wbc_set_r     <= {DC_IW{1'b0}};
            wbc_way_r     <= {WY_W{1'b0}};
            wb_base_r     <= 32'd0;
            wb_tag_v_r    <= 1'b0;
            wb_v_r        <= 1'b0;
            wb_beat_r     <= {BIW{1'b0}};
            wb_hold_r     <= 1'b0;
            wb_bcnt_r     <= {FIW{1'b0}};
        end else begin
            // ---- 锥① 步1 + cut F: 填充安装写打一拍; 整路写 ⇒ 载荷是**整行缓冲** ----
            // 打完这一拍, u_arr 的 we/addr/wmask/wdata 四组脚全由 FF 驱动 (见第 5b 节)。
            fill_wr_r    <= fill_wr_w;
            fill_vset_r  <= vset_w;
            // ---- 刀 O: store 读-改-写合成的 **256 位数据写回 `fill_buf_r`** (安装支与 RMW 支从此
            //      共用同一个整行缓冲 ⇒ 写载荷 mux 288 → 32 位)。写在回包那支**之前** = 显式优先级
            //      "回包逐字 > RMW 合成"; 两支实际由 `rmw_rd_w`/`rmw_now_w` 的窗口条件 (`!fill_busy_r &&
            //      !fill_start_w` + 窗口内 `rmw_hold_w` 恒 1) **互斥**, 不可能同拍 (见第 9 节注释)。
            //   ★ 刀 U: 合成拍有两个 —— `rmw_rd1_r` (读相那一支, 整路在 rdata 上) 与 `rmw_now_w` (回包那拍)。
            if (rmw_rd1_r || rmw_now_w) fill_buf_r <= rmw_data_new_w;
            // ---- WB 捕获 (起填后一拍占读口; SRAM 同步读 ⇒ 再下一拍数据才到手) ----
            wbc_lat_r <= wbc_pend_r;
            if (wbc_pend_r) wbc_pend_r <= 1'b0;
            if (wbc_lat_r) begin
                wb_v_r     <= 1'b1;
                wb_beat_r  <= {BIW{1'b0}};
                wb_bcnt_r  <= {FIW{1'b0}};
                wb_data_r  <= rdata_w[wbc_way_r * WAY_W +: 32 * DC_LINE_WORDS];
                // ★ 受害行的 tag 就在这份回包的 tag 槽里 —— 起填那拍还不知道, 这里补上。
                //   读口和组号都是现成的 (捕获读只按组寻址) ⇒ 这条路径零额外读口, 也不占拍。
                wb_base_r  <= {rdata_w[wbc_way_r * WAY_W + TAGOFF +: TAG_W], wbc_set_r, {SPLIT{1'b0}}};
                wb_tag_v_r <= 1'b1;
            end
            if (fill_start_w) begin
                fill_busy_r   <= 1'b1;
                fill_set_r    <= new_set_w;
                fill_base_r   <= fill_base_new_w;
                fill_word_r   <= {FIW{1'b0}};
                fill_cnt_r    <= {FIW{1'b0}};
                fill_way_r    <= victim_way_w;
                // 起填那拍 fill_base_r 还没更新 —— fill_line 输出此刻已指向**新行**, 污染按新行判
                fill_poison_r <= fill_blk;
                // 受害路脏 ⇒ 下一拍把整行读进 WB 缓冲 (该路 valid/dirty 同拍清零, 数据不丢)
                // ★ wb_base_r 必须是**受害行**的基址, 不是新填充行的: 捕获读只按组寻址, 给错行照样读
                //   到对的整行; 但排水那 8 笔的地址与 wb_line_busy_w 的同行比较都靠它 ⇒ 给成新行 =
                //   把旧行的数据写到新行的地址上 (静默算错)。
                //   ★ 受害行的 tag 此刻**还不知道** (它来自下一拍的捕获读回包, 见上面 wbc_lat_r 那支):
                //     这里先写"组号对、tag 置 0", `wb_tag_v_r=0` 标出未知窗口 —— 窗口内一切同行比较
                //     退化成只比组号 (保守: 多挡), 两拍后 tag 到位。
                if (vic_v_w && vic_dirty_w) begin
                    wbc_pend_r <= 1'b1;
                    wbc_set_r  <= new_set_w;
                    wbc_way_r  <= victim_way_w;
                    wb_base_r  <= {{TAG_W{1'b0}}, new_set_w, {SPLIT{1'b0}}};
                    wb_tag_v_r <= 1'b0;
                end
            end else if (fill_busy_r) begin
                if (fill_hs_w)         fill_word_r <= fill_word_r + 1'b1;   // 被 load 抢走就原地重试
                if (fill_rsp_valid)    fill_cnt_r  <= fill_cnt_r + 1'b1;
                // ★ 整行缓冲: 回包**逐字**攒, 下标用**当拍**的 fill_cnt_r (与 fill_rsp_data 同源)。
                //   末字那份也在落盘拍之前攒好 ⇒ 安装写那一刻八字齐备。
                //   挡 `== DC_LINE_WORDS`: abort 后残留的在飞回包会把 cnt 顶到 8, 不挡就是越界写。
                if (fill_rsp_valid && (fill_cnt_r != DC_LINE_WORDS))
                    fill_buf_r[fill_cnt_r * 32 +: 32] <= fill_rsp_data;
                if (fill_poison_now_w) fill_poison_r <= 1'b1;
                if (fill_last_w)       fill_busy_r <= 1'b0;
            end
            // ★ 同拍"起填"与"再排队"时不能盲目覆盖: 若起填的就是排队那条 (pf_start_w), 该排队项已被
            //   这次填充满足, 留着它 ⇒ 填充结束后会对**同一行**再起一次填充; 那时该行已驻留 ⇒ victim
            //   落到另一路, 安装时的不变量 1 清理会把另一路的**脏副本静默作废** (只清 valid/dirty, 不写回)
            //   ⇒ 该行吸收过的 store 永远到不了内存, 之后的重填读回旧值 (def_wr4 qsort 实测: 420 号元素
            //   变成 312 号的重复值)。丢掉的那个排队请求不亏: 它的 miss 仍在, 下一拍重新排队。
            if (fill_pend_w && !pf_start_w) begin                       // 覆盖 (1 条队列)
                pf_v_r    <= 1'b1;
                pf_base_r <= {lk_addr_r[31 : SPLIT], {SPLIT{1'b0}}};
            end else if (fill_start_w) begin
                pf_v_r    <= 1'b0;                                      // 排队的那条已起填
            end
            // ---- 下一行预取 (M5): 起填 / 登记 / 目标已被别人装进来就释放 ----
            // 三支互斥 (`dpf_sel_w` 与 `pf_trig_w` 同拍时以"已起填"为准 ⇒ 丢掉本次登记, 不亏:
            // 预取只是机会性的, 丢一条不影响任何正确性资源)。释放那支是为了不把唯一那槽永久锁死。
            if (dpf_start_w) begin
                dpf_v_r <= 1'b0;
            end else if (pf_trig_w) begin
                dpf_v_r    <= 1'b1;
                dpf_base_r <= pf_base_w;
            end else if (dpf_v_r && pf_present_w) begin
                dpf_v_r <= 1'b0;
            end
            // ---- WB 排水: 背靠背推 DC_LINE_WORDS 笔 (写通道上 WB 优先); 推完转 hold 等 B ----
            if (wb_last_push_w) begin
                wb_v_r    <= 1'b0;
                wb_hold_r <= 1'b1;
            end else if (wb_req_valid && wb_req_ready) begin
                wb_beat_r <= wb_beat_r + 1'b1;
            end
            if (wb_done_w) wb_hold_r <= 1'b0;      // 写在置位之后 ⇒ 同拍"收齐"赢
            if (wb_resp_valid && (wb_v_r || wb_hold_r)) wb_bcnt_r <= wb_bcnt_r + 1'b1;
        end
    end

    // ==================== 6. 查表寄存器 (skid) ====================
    // busy = 寄存器被占住无法接受新 load || 填充回包期内一律不接 || 本拍有安装写。
    //   · `(fill_busy_r && fill_rsp_valid)`: **整个回包相**都要挡接受。理由 = 合并窗口:
    //     一条 load 接受后**下一拍**才判缺失 (`lk_v_r` 一拍), 合并 (`coalesce_w`) 要求判定那拍
    //     `fill_busy_r` 仍为 1。回包期内接受的那些 load, 其判定落在 `fill_busy_r` 落下之后的不在
    //     少数 ⇒ 合并不成立 ⇒ 对**刚装上的行**再起一次填充, victim 落到另一路 ⇒ 那笔安装的
    //     不变量 1 清理把另一路 (可能已脏) 的副本静默作废 (丢 store)。
    //     ★★ 这里必须先记一笔**被证伪的读法**: 曾断言"只需挡**末字**那一个回包拍 (`fill_wr_w`),
    //        因为判定只晚一拍" —— 实测证伪: 只挡末字 + 落盘拍时 `perf_qsort` 退出值
    //        0→1257、`perf_rsort` 0→1, 两个独立负载同时挂; 挡满整个回包相则六例全过。
    //        ⇒ "接受→判定恰好晚一拍"这个读法不成立 (重放 `lk_replay_r`、被偷读 `rd_ok_r=0`、
    //        以及**排队需求** `pf_v_r` 那条路都会把判定推后, 与填充收尾赛跑)。
    //   ★ **这一条不是新加的约束, 是旧契约**: 旧 32 位粒度下 `fill_wr_w` = `fill_rsp_valid`
    //     (每个回包字都写、每拍都偷读口), 所以**整段回包相本来就在挡**。整路粒度把写口占用
    //     从 8 拍收到 1 拍, `fill_wr_w` 也随之只剩末字那拍 ⇒ 若不显式补回这一项, 窗口是被
    //     粒度改写**顺手放宽**的, 与本注释的上一条理由无关。
    //   · `fill_wr_r` (落盘拍): 本拍有安装写, 会偷走新读 ⇒ 无谓降级 (与旧口径同款)。
    assign busy = (lk_v_r && !hit_valid && !ms_fire_w) || (fill_busy_r && fill_rsp_valid) || fill_wr_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lk_addr_r   <= 32'd0;
            lk_width_r  <= 2'd0;
            lk_idx_r    <= {LIW{1'b0}};
            lk_v_r      <= 1'b0;
            lk_miss_r   <= 1'b0;
            lk_wait_r   <= 1'b0;
            lk_replay_r <= 1'b0;
        end else if (lk_valid && !busy) begin                       // 接受: 覆盖上一条已消化的结果
            lk_addr_r   <= lk_addr;
            lk_width_r  <= lk_width;
            lk_idx_r    <= lk_idx;
            lk_v_r      <= 1'b1;
            lk_miss_r   <= 1'b0;
            lk_wait_r   <= 1'b0;
            lk_replay_r <= 1'b0;
        end else if (lk_v_r) begin
            if (lk_replay_r) begin
                lk_replay_r <= 1'b0;                                // 重放读已发出, 下一拍用新 rd_addr_q 判定
            end else if (lk_wait_r) begin
                // ★ 退出条件必须是**电平** (lk_wait_src_w 落下), 只写 fill_last_w 会永久卡死:
                //   fill_last_w 是 1 拍脉冲, 而"并入"与"填充最后一拍"可以同拍发生
                //   (coalesce_w && fill_last_w)。那一拍只置了 lk_wait_r, posedge 后 fill_busy_r 已清、
                //   fill_last_w 再也不会为 1 ⇒ lk_wait_r 恒 1 ⇒ 这条 load 永不交付 ⇒ LSQ 的 issued_r
                //   位恒 1 ⇒ head 卡死, 全机冻结。实测 bulgarian: t=20765 同拍命中 [COAL-LAST],
                //   此后每拍 [WAITSTUCK] 直到 300000 拍上限。
                //   (锥 ① 之前这里还有一项 `lk_same_fill_w && fill_last_w` 的快路径, 省 1 拍:
                //   它那一拍 fill_busy_r 还是 1 ⇒ 当拍退出、下一拍发出重放读。安装写打了一拍之后
                //   那一拍正是**落盘拍** ⇒ 重放读会被它偷走 (rd_ok_r=0) 再白重放一次, 省不到拍还多绕一圈,
                //   故删掉 —— 只留电平项: 落盘拍的下一拍 (fill_wr_r 已过、行已 valid) 才发重放读。)
                // M2: 本拍回包的那个字正是这条 load 要的 ⇒ 当拍交付, 不等整行装完 (第 5b 节)。
                //   抢不到交付口 (rsp_busy) 时不在这里退出, 落到下面的电平退出条件上走原路 ——
                //   `hit_valid` 那一路已经把 lk_v_r 清掉了, 这里只补 wait/miss 两位。
                if (byp_valid_w) begin
                    lk_v_r    <= 1'b0;
                    lk_wait_r <= 1'b0;
                    lk_miss_r <= 1'b0;
                end else if (!lk_wait_src_w) begin
                    lk_wait_r <= 1'b0; lk_replay_r <= 1'b1;
                end
            end else if (!lk_miss_r && !rd_ok_r) begin
                // ★ 本拍的读被安装写/store 就地更新/WB 捕获读偷走 (sram_fakeram 在写周期把 rdata 置 x)
                //   ⇒ 重放同一地址, **不判缺失**: 写回下误判缺失 = 读陈旧内存 + 覆盖脏行 = 静默算错。
                //   只在"这一拍本是对这笔 load 的判定"时进 (`!lk_miss_r` 挡掉已 park 的那条: 它的
                //   rd_addr_q 早就不代表自己了, 重放只会白等两拍)。被偷的那笔 AR 绝不会发出去 ——
                //   miss_pending_w 里也带了 rd_ok_r。
                lk_replay_r <= 1'b1;
            end else if (hit_raw_w && !hit_valid) begin
                // ★ 命中但交付口被占 (rsp_busy): **重放**, 不许像写直达版那样降级成缺失 ——
                //   写回下按缺失走 AXI 读到的是落后于脏行的内存值 (该行的新字节只在缓存里),
                //   而此刻合并链可能已经不含那条 store ⇒ 静默算错。重放只花 2 拍, 还比一趟 AXI 便宜。
                //   (第 4 节 miss_pending_w 用 !hit_raw_w 把这条同时挡在 AR 之外, 两处必须成对改。)
                lk_replay_r <= 1'b1;
            end else if (hit_valid) begin
                lk_v_r <= 1'b0;                                     // 命中已交付
            end else if (coalesce_w) begin
                lk_wait_r <= 1'b1;                                  // 并入在填行
            end else if (ms_fire_w) begin
                lk_v_r <= 1'b0;                                     // 缺失已推出
            end else begin
                lk_miss_r <= 1'b1;                                  // park: 保持, 下一拍重试
            end
        end
    end

    // ==================== 7. 读口时序 (rd_ok_r 必须在发起读那一拍采样) ====================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_q <= 32'd0;
            rd_ok_r   <= 1'b0;
        end else begin
            rd_addr_q <= rd_addr_w;
            // 写的那拍 / WB 捕获读占口的那拍 / 读-改-写取老字的那拍 / **探针硬抢**的那拍, 都没有
            // "本次查表"的读 ⇒ 下一拍条目不可信 (被偷的查表读一律走重放, 不判缺失)。
            // ★ 探针那两项成对: 走**空槽** (probe_slot_w) 时它没偷任何人, 这一位必须留 1 —— 若也置 0,
            //   一个恰好在这拍被接受的 load 会白白重放两拍; 硬抢 (probe_steal_w) 时才置 0。
            rd_ok_r   <= !sram_we_w && !wb_cap_w && !rmw_rd_w && !probe_steal_w;
        end
    end

    // ==================== 8. 行有效位图 + 脏位图 + tag 镜像 ====================
    // fill_line = 本拍"有效填充行": 起填那拍 fill_base_r 还是上一条, 必须给**新行** —— 上层
    // sq_line_blk_f 拿它去比 SQ 条目, 给错行就会漏判污染 (或误判)。
    assign fill_line = fill_start_w ? fill_base_new_w : fill_base_r;
    assign fill_tag_w = fill_base_r[31 : TAGHI];
    // 最后一字落地才置位; 被污染的填充不置 (行没装全, 装了就是"半行冒充整行")
    //   ★ 整路写粒度下它与 `fill_wr_w` 是**同一个条件** —— 安装写那笔正好就是置 valid 的那笔 (旧 32 位
    //     粒度下两者不同: 写逐字来 8 次、置 valid 只在末字)。所以直接取它, 免得同一条件写两遍、
    //     日后改一处漏一处。(`fill_wr_r`/`fill_vset_r` 这两个寄存器因此同值, 由 `opt_merge` 合并。)
    assign vset_w = fill_wr_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= {(DC_WAYS * DC_SETS){1'b0}};
        end else begin
            // ★ 发起填充即清 valid —— 不清就是"旧数据冒充新 tag"的假命中。
            //   同拍清 dirty: 受害路的脏数据此刻已被记进 WB 捕获 (存不下就不起填, 见 fill_blk_w),
            //   没被捕获的必然是干净行 ⇒ 清掉不丢数据。
            if (fill_start_w) begin
                valid_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
                dirty_r[victim_way_w * DC_SETS + new_set_w] <= 1'b0;
            end
            // 中途置位会把半行当整行交付; 刚取回的行与内存一致 ⇒ 干净
            // ★ 判据是 `fill_vset_r` (落盘拍) 而不是判决拍的 `vset_w`: 行真装进去是那一拍 (锥 ①)。
            //   起填拍与落盘拍同拍时两者动的是不同槽 (起填口都带 `!fill_vic_hit_w`), 不打架。
            if (fill_vset_r) begin
                valid_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b1;
                dirty_r[fill_way_r * DC_SETS + fill_set_r] <= 1'b0;
            end
            // ★ 不变量 1: 同组任一时点最多一路持有某 tag —— 安装那拍把其它持有同一 tag 的路一并
            //   作废。重复 tag 在写回下是**静默算错** (脏副本被换出 / 陈旧副本被读出)。
            //   ★ 比较结果来自本次填充期间的一次 **tag 探针** (`fc_tm_r`, 见第 3 节): 一次填充在飞时
            //     同组的 valid/tag 是冻结的 (别的填充被 `fill_busy_r` 挡住, store 吸收只动 dirty) ⇒
            //     期间任何一拍查到的答案到安装这拍都还成立, 所以每次填充只查一次就够。
            //   ★ `fc_tm_v_r` 是必须的: 探针还没回时那一拍允许安装 (不能为它停安装 —— 回包不可反压),
            //     此时**跳过清理**。这个窗口只在"真有重复 tag"时才有意义, 而重复 tag 本身要靠
            //     "对已驻留行再起填"才产生, 那已被三个起填口各自的检查挡住 (需求口靠 `any_hit_w`,
            //     预取口靠 `pf_present_w`)。
            if (fill_vset_r && fc_tm_v_r)
                for (gi = 0; gi < DC_WAYS; gi = gi + 1)
                    if ((gi != fill_way_r) && valid_r[gi * DC_SETS + fill_set_r] && fc_tm_r[gi]) begin
                        valid_r[gi * DC_SETS + fill_set_r] <= 1'b0;
                        dirty_r[gi * DC_SETS + fill_set_r] <= 1'b0;
                    end
            // ★ store 就地写 ⇒ 该行与内存不一致, 换出时必须写回。放最后: 与上面几项撞同一槽时
            //   以"置脏"为准 —— 吸收进去的字节是真实的, 丢掉它就是静默算错。
            // ★ 位置必须取**捕获的** `rmw_way_r`/`rmw_set_r`, 不能取本拍的 `st_way_w`/`st_set_w`:
            //   吸收发生在读相之后第 2 拍 (锥 ①; 刀 M 后碰撞时第 3 拍 —— 捕获的必要性只增不减),
            //   这窗口里 tag 锁存可能已被同组的一次安装 (`fill_vset_r`)
            //   作废 ⇒ `st_tm_ok_w`=0 ⇒ `st_hit_g` 全 0 ⇒ `hitway_f` 给出**错的路号**, 脏位就落到
            //   另一条无关行上, 而真正被写的那条仍是干净 ⇒ 换出时静默丢弃 = 丢 store。
            //   (`st_absorb` 与 `rmw_wr_w` 同拍 ⇒ 这两个寄存器的值一定还是本笔读相锁下的那个。)
            if (st_absorb) dirty_r[rmw_way_r * DC_SETS + rmw_set_r] <= 1'b1;
        end
    end

    // ==================== 9. store 退休口 (写回: 命中就地把字节写进行, 未命中旁路) ====================
    // 语义: SQ 队首那条 store 要在**本拍**定下去向 (mem_subsystem 拿这里的回答当退休许可)。
    // 两条出路互斥, 恰好一条 (都不抬 = 让路一拍, 队首原地重试):
    //   · 命中 ⇒ st_absorb: 把该 store 的 1/2/4 个字节按 addr[1:0] 写进命中路, 并置脏。
    //     **整字 (sw) 1 拍**: 一个 lane 掩码就够 (第 3 节)。
    //     **部分字 (sb/sh) 读-改-写**: 32 位粒度下掩码只能整 lane 写, 必须先占读口把老字读回来,
    //     在 lane 内按字节合并 (rmw_merge_w) 再占写口落盘 —— 见下面"读-改-写"小节。
    //   · 未命中 ⇒ st_bypass: 本缓存没有该行, 数据照原样走 SQ→AXI 写通道 (DC_WA=0 不分配)。
    // 让路 (都不抬 ⇒ 队首多等一拍; 条目还在 SQ 里 ⇒ 合并链仍覆盖, 正确性不受影响):
    //   · 安装写占着 SRAM 口 (fill_wr_r —— 落盘拍, 见头注释锥 ①); · WB 捕获读占着读口 (wb_cap_w);
    //   · 本拍该路正被驱逐 (st_vic_now_w): 行马上就要没了, 写进去也是白写 ⇒ 下拍自然走旁路;
    //   · 同一行的写回还没推完 (st_wb_same_w): 写通道按序, 必须排在旧行那 8 笔之后, 否则被反超。
    assign st_set_w  = ONE_SET ? {DC_IW{1'b0}} : st_addr[TAGHI - 1 : SPLIT];
    assign st_tag_w  = st_addr[TAGHI +: TAG_W];
    assign st_word_w = st_addr[SPLIT - 1 : 2];
    assign st_cacheable_w = (st_addr[31 : 28] == 4'h0);   // MMIO (>=0x10000000) 永不吸收, 必上总线
    // 命中判定 = {探针拿到的"逐路 tag 是否相等"} ∧ {本拍该路的 valid}。前一半来自锁存 (第 3 节),
    // 后一半必须**本拍现取** —— valid 是唯一允许随时变的状态, 探针那拍和现在之间它可能已清零。
    // `st_tm_ok_w` 是"这个答案还代表本拍问的那个地址吗": 不是就判定不成立 ⇒ 本拍让路, 下一拍重试
    // (stp_req_w 会重新发探针)。让路只发生在探针刚发出/刚换地址那几拍, 队首原地重试, 不丢条目。
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : sthit
            assign st_hit_g[gj] = st_tm_ok_w && valid_r[gj * DC_SETS + st_set_w] && st_tm_sel_w[gj];
        end
    endgenerate
    assign st_way_w     = hitway_f(st_hit_g);
    assign any_st_hit_w = |st_hit_g;
    wire   st_vic_now_w = fill_start_w && (st_set_w == new_set_w) && (st_way_w == victim_way_w);
    // ★ 刀 U: 上面那一组的**锁存版** —— 把 `st_tm_ok_w`/`st_tm_sel_w` 里的"本拍回包"项去掉,
    //   整组只含寄存器 (`st_tm_v_r/st_tm_r/st_set_r/st_tag_r/valid_r`)。读相判决 (`rmw_rd_w`) 与
    //   它的驱逐检查用它 ⇒ `rdata_w` 到 `rd_addr_w` 之间再无组合通路。
    generate
        for (gj = 0; gj < DC_WAYS; gj = gj + 1) begin : sthitlat
            assign st_hit_lat_g[gj] = st_tm_lat_w && valid_r[gj * DC_SETS + st_set_w] && st_tm_r[gj];
        end
    endgenerate
    assign st_hit_lat_w     = |st_hit_lat_g;
    assign st_way_lat_w     = hitway_f(st_hit_lat_g);
    assign st_vic_lat_now_w = fill_start_w && (st_set_w == new_set_w) && (st_way_lat_w == victim_way_w);
    // tag 未知窗口内只比组号 (保守: 只多让路一拍, 队首原地重试) —— 见 lk_wb_wait_w 同款论证。
    wire   st_wb_same_w = wb_buf_busy_w && (wb_tag_v_r ? (wb_base_r[31 : SPLIT] == st_addr[31 : SPLIT])
                                                      : (wb_base_r[TAGHI - 1 : SPLIT] == st_addr[TAGHI - 1 : SPLIT]));
    // ★ 同一行**正有填充在飞**。只认 register 出来的 fill_busy_r, 不认本拍起填 —— 起填与否本身
    //   取决于 fill_blk, 而 fill_blk (mem_subsystem 的毒化判定) 又取决于本判定, 认了就成组合环。
    //   在飞的填充必然已经过了起填那一拍, 靠它就够。
    //   ★ **必须含落盘拍 `fill_wr_r`** (锥 ①): 那一拍行还没装上 (valid 在它结束时才置), 少了这一项
    //     同行 store 就被判"旁路" ⇒ 数据绕过缓存进内存, 而下一拍装上来的行里仍是内存旧值 ⇒ 静默算错。
    //     含了之后它在落盘拍只是"让路一拍", 下一拍行已 valid ⇒ 自然命中吸收 (字节进缓存行)。
    wire   st_fill_same_w = (fill_busy_r || fill_wr_r) && (fill_base_r[31 : SPLIT] == st_addr[31 : SPLIT]);
    // ---- store 命中吸收**一律**读-改-写: 读相(占读口取整路) → 合成 → 写相(占写口落盘, 与 st_absorb 同拍) ----
    // 整路写粒度下没有比"一整路"更小的写单位 ⇒ 整字 (sw) 与部分字 (sb/sh) 走**同一条**路;
    //   代价是整字 store 由 1 拍变 2 拍 (多占读口 1 拍), 收益在别处 (填充安装 8 拍 → 1 拍、宏口负载 ÷9)。
    // 读相条件与旧的整字那条同款, 另加 `!st_fill_same_w`: 本行有填充在飞时, 它安装那拍的不变量 1
    //   清理会把**另一路**的同 tag 行作废 (只清 valid/dirty, 不写回) —— 读-改-写要 3 拍, 干脆等填充
    //   收尾 (miss 仍在 ⇒ 队列里的条目下拍重试; 也会自然走旁路)。实际对 hit 而言这一项恒真无约束 ——
    //   填充在飞时本行 valid 已清 ⇒ any_st_hit_w=0。
    // 窗口内禁起填 (rmw_hold_w, 第 5 节): 起填把受害路清 valid —— 万一正是本路, 已合成的整路就
    //   落进一条无效行了。★ rmw_hold_w **不含** rmw_rd_w, 否则 fill_go → fill_start → st_vic_now →
    //   rmw_rd 成组合环; 读相那一拍由 `!st_vic_now_w` 自己挡 (同拍起填驱逐本路 ⇒ 本次不发起)。
    // ★ 刀 O 新增 `!fill_busy_r && !fill_start_w`: 读相到落盘这 3 拍里 `fill_buf_r` 归 RMW 独占
    //   (合成的 256 位要写回它) ⇒ 窗口内不许有在飞填充 (下一拍就可能回包写它) 也不许有起填。
    //   三个起填源全含 `!rmw_hold_w`, 而窗口内 `rmw_hold_w` 恒 1 ⇒ 起填只在**读相那一拍**是唯一
    //   空隙 ⇒ 用 `!fill_start_w` 堵上 (与 `!st_vic_now_w` 同一个理由: 同拍起填会驱逐本路)。
    // ★ 刀 U (2026-10-11): 读-改-写分两支 ——
    //     · `rmw_now_w` = **本拍回包**那一支: 整路已在 `rdata_w` 上 ⇒ 直接合成、下一拍落盘;
    //     · `rmw_rd_w`  = **答案来自锁存**那一支: 才需要单独占读口把整路取回来 (旧的三拍路)。
    //   ~~旧写法只有一支 `rmw_rd_w = st_valid && any_st_hit_w && ...`~~ —— 它的判决用了本拍 rdata 上的
    //   比较结果 (`any_st_hit_w` / `st_vic_now_w`), 而它又去选 `rd_addr_w` 的 `st_addr` 支 ⇒
    //   宏自己的一拍闭环"读出 tag → 命中判定 → 占读口 → 地址" (census 头名族 4.5588, plan §3.30)。
    //   现在读相判决只认锁存 (`st_hit_lat_w` / `st_vic_lat_now_w`), 本拍回包整支交给 `rmw_now_w`
    //   (它只写寄存器, 不碰读口) ⇒ `rdata_w` 到 `rd_addr_w` 之间再无组合通路。
    assign rmw_rd_w     = st_valid && st_hit_lat_w && st_cacheable_w && !st_tm_live_w
                       && !rmw_rd1_r && !rmw_v_r && !fill_wr_r && !wb_cap_w
                       && !fill_busy_r && !fill_start_w
                       && !st_vic_lat_now_w && !st_fill_same_w;
    // ★ 回包那拍命中 ⇒ **探针那一读就是读相**: `probe_hold_w` 已把 wb 捕获/RMW/重放/写周期全挡在探针外,
    //   故 `stp_go_w` 那拍读口确实是探针的、`rd_addr_w = probe_addr_w` (组号 = 本笔 store 的组) ⇒
    //   下一拍 `rdata_w` 上**就是本笔 store 那一整路** (tag 比较器本来就在信任这一条)。既然整路已在手,
    //   就不必再占读口读一遍 ⇒ 吸收 3 拍 → 2 拍, 且每笔吸收少占读口 1 拍。
    //   两支天然互斥: 探针只在 `!st_tm_ok_w` 时发, 而 `st_tm_lat_w` 要在**回包那一拍**才可能为 1
    //   (发起拍它必为 0); 再加 `!st_tm_live_w` 显式隔开。窗口保护 (刀 O 口径): 本拍 `!fill_busy_r && !fill_start_w` +
    //   下一拍 `rmw_v_r` ∈ `rmw_hold_w` ⇒ `fill_buf_r` 仍归 RMW 独占 (本拍合成写它、下一拍落盘读它)。
    assign rmw_now_w    = st_valid && any_st_hit_w && st_cacheable_w && st_tm_live_w
                       && !rmw_rd1_r && !rmw_v_r && !fill_wr_r && !wb_cap_w
                       && !fill_busy_r && !fill_start_w
                       && !st_vic_now_w && !st_fill_same_w;
    // ★ 写相**不再让路** (刀 M): `rmw_v_r` 只会在"下一拍没有安装落盘"时置位, 故写相与安装
    //   **结构上不同拍**, 写口四组选择端可以整个交给这根 FF。
    //   ★ 刀 O 之后连"下一拍有没有安装"都不必现算了: 读相被 `!fill_busy_r && !fill_start_w` 挡住
    //   ⇒ 窗口内 `fill_busy_r` 恒 0 (起填源全含 `!rmw_hold_w`, 窗口内 hold 恒 1) ⇒ 回包不可能到达
    //   ⇒ `fill_wr_w` 在窗口内恒 0 ⇒ 旧刀 M 的判决点 `~fill_wr_w` 退化成 `1'b1`, `rmw_pend_r` 整支删掉。
    assign rmw_wr_w     = rmw_v_r;                        // 写相: 整路已在寄存器里, 本拍落盘
    assign rmw_hold_w   = rmw_rd1_r || rmw_v_r;
    assign st_absorb    = rmw_wr_w;
    // ★ 非缓存 / 未命中都走这一条。`!st_cacheable_w` 显式进门: 万一 MMIO 行被吸收, 终止 store
    //   就永远上不了总线 (从机等不到它) ⇒ 死机。让路项与吸收那边同款, 两条合起来恒有解。
    // ★ **同行填充在飞时例外** (判"都不发" = 停一拍重试): 那一拍判旁路 = 该行永远装不上 —— 条目
    //   留在 SQ 里 (sq_pend_w) 毒死这次填充 ⇒ 行不安装 ⇒ 下一轮再缺失 ⇒ 再旁路, **自我否定环**。
    //   rsort 实测: 起填 16474 次只装上 2568 次 (15.6%), 中止拍 99.97% 是同行未落地 store。
    //   等它落地不额外花 AR (填充本来就在飞), 落地后本行 valid ⇒ 自然命中吸收。
    assign st_bypass    = st_valid && st_ready_w
                       && (!st_cacheable_w || (!any_st_hit_w && !st_fill_same_w))
                       && !st_wb_same_w;

    // ★ `rmw_tag_r` 刻意**不复位** (与 `dirty_r` 同款): 它只在 `rmw_v_r` 那一拍被读, 而 `rmw_v_r`
    //   有复位 ⇒ 复位期间端口上的 x 不会被用 (宏在 we=0 时也不看 wdata); 它的写与 `rmw_v_r` 的
    //   置位**同沿** (见下面 always), 所以 `rmw_v_r`=1 的每一拍 `rmw_tag_r` 都已是本笔的 tag。
    //   ★ 合成的 **256 位数据**写回 `fill_buf_r` (刀 O) —— 那在 fill 块的 always 里 (同一 reg 不能
    //   两个 always 块写), 条件 = `rmw_rd1_r || rmw_now_w` (两个合成拍), 优先级"回包逐字 > RMW 合成"。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rmw_rd1_r  <= 1'b0;
            rmw_v_r    <= 1'b0;
            rmw_set_r  <= {DC_IW{1'b0}};
            rmw_way_r  <= {WY_W{1'b0}};
            rmw_woff_r <= {OFF_W{1'b0}};
        end else begin
            if (rmw_now_w) begin                      // ★ 刀 U: 本拍回包 ⇒ 整路就在 rdata_w 上, 直接合成
                rmw_set_r  <= st_set_w;               //   (位置也取本拍这三个活信号 —— 它们与 rdata 同源同行)
                rmw_way_r  <= st_way_w;
                rmw_woff_r <= st_word_w;
                rmw_tag_r  <= rmw_tag_old_w;
                rmw_v_r    <= 1'b1;                    // 下一拍落盘 (选择端 = 它); 窗口内无安装在飞
            end else if (rmw_rd_w) begin              // 读相已发出: 记下位置 (整路下一拍到 rdata 上)
                rmw_rd1_r  <= 1'b1;
                rmw_set_r  <= st_set_w;
                rmw_way_r  <= st_way_w;
                rmw_woff_r <= st_word_w;
            end else if (rmw_rd1_r) begin              // 整路在 rdata_w 上 ⇒ 本拍换掉命中的那个 word 槽
                rmw_rd1_r  <= 1'b0;
                rmw_tag_r  <= rmw_tag_old_w;
                rmw_v_r    <= 1'b1;                    // 下一拍落盘 (选择端 = 它); 窗口内无安装在飞
            end
            if (rmw_wr_w) rmw_v_r <= 1'b0;             // 已落盘 (同拍 st_absorb), 窗口结束
        end
    end

endmodule
