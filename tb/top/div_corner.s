# C1 角例程序 (G3): 逐对取 DIV/DIVU/REM/REMU 四条的结果累加进 a0。
# 官方 19 个 correctness 程序里 div/rem 只出现在算法除法与 course_put_result 的 % 253,
# **不含除零与 INT_MIN/-1 溢出** —— 本程序专补这两类 + 四象限符号 + 边界。
#
#   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -Wl,-Ttext=0 -o div_corner.elf div_corner.s
#   riscv64-unknown-elf-objcopy -O binary div_corner.elf div_corner.bin
#   python3 tb/top/bin2data.py div_corner.bin tb/top/div_corner.data
#   python3 tb/top/div_corner_expect.py tb/top/div_corner.s     # 打印 EXPECTED
#   make run PROGRAM=tb/top/div_corner.data EXPECTED=<上一步的值>
#
# 累加用 a0 = a0*31 + r 而非异或: 异或下**同一个错值出现偶数次会自己抵消**。
# 实测(RTL 变异): 把 div.v 的除零商从 32'hFFFF_FFFF 改成 0 ——
#   异或累加: 6 处改动两两抵消, 终值一字不变 ⇒ **不可判伪**;
#   本累加:   FAIL result=3572143610 expected=3557883290 ⇒ 判伪。
# 31 是奇数 ⇒ 31^k 在 mod 2^32 下可逆 ⇒ **任何一个结果错, 终值必不同**。
#
# 期望值由 tb/top/div_corner_expect.py 从下面这张 pairs 表按 RISC-V 语义独立算出
# (不取自仿真输出 —— 否则是自证)。

    .section .text
    .globl _start
_start:
    li   a0, 0                  # 结果累加器
    la   t0, pairs
    la   t1, pairs_end
1:
    lw   a1, 0(t0)              # 被除数
    lw   a2, 4(t0)              # 除数
    div  a3, a1, a2
    slli t3, a0, 5
    sub  a0, t3, a0             # a0 *= 31
    add  a0, a0, a3
    divu a3, a1, a2
    slli t3, a0, 5
    sub  a0, t3, a0
    add  a0, a0, a3
    rem  a3, a1, a2
    slli t3, a0, 5
    sub  a0, t3, a0
    add  a0, a0, a3
    remu a3, a1, a2
    slli t3, a0, 5
    sub  a0, t3, a0
    add  a0, a0, a3
    addi t0, t0, 8
    blt  t0, t1, 1b
    li   t2, 0x80000000         # MMIO 停机: 32 位 store
    sw   a0, 0(t2)
2:
    j    2b

    .align 2
pairs:                          # {被除数, 除数} —— 顺序即期望值的计算顺序
    .word 0x00000064, 0x00000007    #  100 / 7        普通正数
    .word 0x00000007, 0x00000064    #  7 / 100        商 0
    .word 0xFFFFFFF9, 0x00000002    #  -7 / 2         负数被除数
    .word 0x00000007, 0xFFFFFFFE    #  7 / -2         负数除数
    .word 0xFFFFFFF9, 0xFFFFFFFE    #  -7 / -2        双负
    .word 0xFFFFFFFF, 0x00000001    #  -1 / 1
    .word 0x00000001, 0xFFFFFFFF    #  1 / -1
    .word 0xFFFFFFFF, 0xFFFFFFFF    #  -1 / -1
    .word 0x00000064, 0x00000000    #  100 / 0        除零 (商全 1 / 余 = 被除数)
    .word 0x00000000, 0x00000000    #  0 / 0          除零
    .word 0xFFFFFFFF, 0x00000000    #  -1 / 0         除零
    .word 0x80000000, 0xFFFFFFFF    #  INT_MIN / -1   唯一溢出角例
    .word 0x80000000, 0x00000001    #  INT_MIN / 1
    .word 0x80000000, 0x00000002    #  INT_MIN / 2
    .word 0x80000000, 0x7FFFFFFF    #  INT_MIN / INT_MAX
    .word 0x80000000, 0x80000000    #  INT_MIN / INT_MIN
    .word 0x7FFFFFFF, 0xFFFFFFFF    #  INT_MAX / -1
    .word 0x7FFFFFFF, 0x80000000    #  INT_MAX / INT_MIN
    .word 0x00000000, 0x00000005    #  0 / 5
    .word 0x00000000, 0xFFFFFFFF    #  0 / -1
    .word 0x00000001, 0x80000000    #  1 / INT_MIN
    .word 0x12345678, 0x9ABCDEF0    #  无符号满位 / 有符号负
    .word 0x9ABCDEF0, 0x12345678    #  反向
    .word 0x0000000F, 0x00000010    #  15 / 16        边界: a < b
    .word 0x00000010, 0x00000010    #  16 / 16        边界: a == b
pairs_end:
