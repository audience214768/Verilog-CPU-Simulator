#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
合并 ASAP7 拆分标准单元库为单文件 liberty (供 yosys abc/stat/dfflibmap 使用).

原因:
  1) 本 yosys 构建未编译 write_liberty, 无法在 yosys 内导出合并库;
  2) abc / stat / dfflibmap 的 -liberty 只接受单文件, 而 ASAP7 将标准单元
     按类别拆成 5 个 .lib (SIMPLE 基本门 / INVBUF / AO / OA / SEQ 触发器);
  3) 全 CPU 综合需要 SEQ 的 DFF 与 AO/OA 复合门 (乘法器只需 SIMPLE).

用法:
  python3 synth/merge_liberty.py <输出.lib> <基底库> [附加库...]
  基底库的 library 头 (库名/单位/工艺条件/模板) 保留; 附加库取 cell 块,
  以及基底库中缺失的具名模板块 (lu_table_template/power_lut_template/
  operating_conditions/ff/latch 等, 按 (类型, 名字) 去重).
  单元名跨库不重复 (INV/BUF*、AO*、OA*、DFF*、其余在 SIMPLE), 脚本会校验.

  剔除无 timing 段的单元 (如 TIEHI/TIELO 常数源: function 为常量, 无时序表).
  这类单元经 yosys 解析延迟为 0, 使 abc 转换时断言崩溃
  ("Assertion failed: (Delay > 0), function Abc_SclProduceGenlibStr"),
  且综合映射也用不到它们.
"""
import sys
import re

TEMPLATE_TYPES = re.compile(
    r"^\s*(lu_table_template|power_lut_template|operating_conditions|technology|ff|ff_bank|latch|latch_posedge_precontrol)\s*\(([^)]*)\)\s*\{"
)


def split_lib(path):
    """返回 (库头文本, cell 块文本); cell 块去掉库收尾 '}'."""
    text = open(path, encoding="utf-8").read()
    body = text[text.index("library ("):]
    j = body.index("cell (")
    head, cells = body[:j], body[j:]
    cells = cells.rstrip()
    assert cells.endswith("}"), f"{path}: 不以 }} 结尾?"
    cells = cells[:cells.rfind("}")].rstrip()
    return head, cells


def find_block(text, i):
    """text[i] 为 '{', 返回匹配的整块 [i, end)."""
    depth = 0
    j = i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1], j + 1
        j += 1
    raise ValueError("括号不匹配")


def header_blocks(head):
    """库头中的具名顶层块: [(类型, 名字, 块体), ...]"""
    blocks = []
    lines = head.split("\n")
    i = 0
    while i < len(lines):
        m = TEMPLATE_TYPES.match(lines[i])
        if m:
            seg = "\n".join(lines[i:])
            j = seg.find("{")
            _, end = find_block(seg, j)
            body = seg[:end]  # 含声明行: 类型 (名字) { ... }
            blocks.append((m.group(1), m.group(2).strip(), body))
            i += body.count("\n") + 1
        else:
            i += 1
    return blocks


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out, base, *others = sys.argv[1:]

    # 单元名去重校验
    names = []
    for p in [base] + others:
        names += re.findall(r"cell \((\w+)", open(p, encoding="utf-8").read())
    dup = sorted({n for n in names if names.count(n) > 1})
    if dup:
        sys.exit(f"重复单元名: {dup}")

    base_head, base_cells = split_lib(base)
    have = {(t, n) for t, n, _ in header_blocks(base_head)}
    extra = []
    for p in others:
        head, _ = split_lib(p)
        for t, n, body in header_blocks(head):
            if (t, n) not in have:
                extra.append(body)
                have.add((t, n))

    parts = [base_head, "\n\n".join(extra), base_cells]
    for p in others:
        _, c = split_lib(p)
        parts.append(c)

    # 剔除无 timing 段的 cell 块 (TIEHI/TIELO 常数源单元), 否则 abc 崩溃
    merged_cells = "\n\n".join(x for x in parts if x)
    kept, dropped = [], []
    pos = 0
    for m in re.finditer(r"cell \((\w+)\) \{", merged_cells):
        if pos < m.start():
            kept.append(merged_cells[pos:m.start()])  # cell 间的空白
        body, end = find_block(merged_cells, m.end() - 1)
        cell = merged_cells[m.start():m.end() - 1] + body  # 声明行 + 块体
        if "timing ()" in cell:
            kept.append(cell)
        else:
            dropped.append(m.group(1))
        pos = end
    if pos < len(merged_cells):
        kept.append(merged_cells[pos:])
    if dropped:
        print(f"剔除无时序单元 {len(dropped)} 个: {dropped}")

    with open(out, "w", encoding="utf-8") as f:
        f.write("".join(kept).rstrip() + "\n}\n")
    print(f"合并完成: {len(names)} 个单元, 补充模板 {len(extra)}, 写入 {out}")


if __name__ == "__main__":
    main()
