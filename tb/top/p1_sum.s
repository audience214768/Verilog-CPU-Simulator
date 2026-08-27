# p1: 0..99 累加 → 4950 (0x1356) → ret 0x56
# 覆盖: 分支循环 (blt), add/addi/mv; 无内存访问
    .text
    .global _start
_start:
    li  t0, 0          # i
    li  t1, 100        # n (i < 100 → 0..99)
    li  t2, 0          # sum
loop:
    add t2, t2, t0
    addi t0, t0, 1
    blt t0, t1, loop
    mv  a0, t2
    ori x0, x0, 255    # TERM marker
