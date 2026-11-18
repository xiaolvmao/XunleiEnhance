#!/usr/bin/env python3
"""
校验 Tweak.xm 中的每个 %hook / 方法是否真实存在于目标二进制的符号表里。

symbols.json 由 IDA / 自写 Mach-O 解析器从 TDMVideo 的
__objc_classlist → class_ro_t → baseMethodList 中导出（见 README）。

用法：
    python3 tools/verify_hooks.py            # 校验
    python3 tools/verify_hooks.py --strict   # 发现不一致则返回非 0
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TWEAK = os.path.join(ROOT, "Tweak.xm")
SYMBOLS = os.path.join(HERE, "symbols.json")


def parse_tweak(path):
    """返回 {class: [selector, ...]}，selector 已转换为 ObjC 形态。"""
    src = open(path, encoding="utf-8").read()
    # 去掉注释，避免误匹配
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)

    hooks = {}
    for block in re.finditer(r"%hook\s+([A-Za-z_]\w*)(.*?)%end", src, re.S):
        cls, body = block.group(1), block.group(2)
        # 把多行方法声明压成一行，便于匹配
        flat = re.sub(r"\s*\n\s*", " ", body)
        sels = []
        for m in re.finditer(r"[-+]\s*\(([^()]*)\)\s*([^{]*?)\{", flat):
            decl = re.sub(r"\s+", " ", m.group(2)).strip()
            parts = re.findall(r"([A-Za-z_]\w*)\s*:\s*\(", decl)
            if parts:
                sels.append("".join(p + ":" for p in parts))
            elif decl:
                sels.append(decl)
        hooks.setdefault(cls, []).extend(sels)
    return hooks


def main():
    strict = "--strict" in sys.argv
    sym = json.load(open(SYMBOLS, encoding="utf-8"))
    classes = sym["classes"]

    # Swift 类在 ObjC 运行时里的名字：_TtC<moduleLen><module><classLen><class>
    swizzled = dict(classes)
    for name, info in classes.items():
        if "." in name:
            mod, cls = name.split(".", 1)
            swizzled["_TtC%d%s%d%s" % (len(mod), mod, len(cls), cls)] = info

    hooks = parse_tweak(TWEAK)
    ok = miss = 0
    print("目标: %s %s (%s)\n" % (sym["_meta"]["app"], sym["_meta"]["version"],
                                  sym["_meta"]["binary"]))
    for cls, sels in hooks.items():
        info = swizzled.get(cls)
        if not info:
            print("  ✗ 类不存在: %s" % cls)
            miss += len(sels) or 1
            continue
        methods = info["methods"]
        for sel in sels:
            if sel.startswith("xe_"):
                print("  + %s %s   (插件自建方法)" % (cls, sel))
                continue
            if sel in methods:
                print("  ✓ %s %s" % (cls, sel))
                ok += 1
            else:
                print("  ✗ %s %s   (类中存在相近方法: %s)" % (
                    cls, sel,
                    ", ".join([m for m in methods if m.split(":")[0] == sel.split(":")[0]]) or "无"))
                miss += 1

    print("\n通过 %d 项，异常 %d 项" % (ok, miss))
    if strict and miss:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
