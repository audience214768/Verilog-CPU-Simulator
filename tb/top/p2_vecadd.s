# p2: 向量加 a[i]=10i+1 @0x1000, b[i]=20i+2 @0x1040 → c[i]=a+b 求和
#     Σ(30i+3) = 30*28+24 = 864 (0x360) → ret 0x60
# 覆盖: store 写内存 → load 读回, mul, 双循环, sw/lw 偏移寻址
    .text
    .global _start
_start:
    li  s0, 0x1000
    li  s1, 0x1040
    li  t0, 0          # i
    li  t1, 8          # n
wloop:
    li  t2, 10
    mul t2, t2, t0
    addi t2, t2, 1
    sw  t2, 0(s0)
    li  t3, 20
    mul t3, t3, t0
    addi t3, t3, 2
    sw  t3, 0(s1)
    addi t0, t0, 1
    addi s0, s0, 4
    addi s1, s1, 4
    blt t0, t1, wloop
    li  s0, 0x1000
    li  s1, 0x1040
    li  t2, 0          # sum
    li  t0, 0
cloop:
    lw  t3, 0(s0)
    lw  t4, 0(s1)
    add t3, t3, t4
    add t2, t2, t3
    addi t0, t0, 1
    addi s0, s0, 4
    addi s1, s1, 4
    blt t0, t1, cloop
    mv  a0, t2
    ori x0, x0, 255
