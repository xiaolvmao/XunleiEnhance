#!/usr/bin/env python3
"""
校验 Tweak.m 里注册的每个 hook 是否真实存在于目标二进制的符号表里。

symbols.json 由自写 Mach-O 解析器从 TDMVideo 的
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
TWEAK = os.path.join(ROOT, "Tweak.m")
SYMBOLS = os.path.join(HERE, "symbols.json")

HOOK_RE = re.compile(r"XE_HOOK\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_][\w:]*)\s*,")
SETTINGS_CLASSES_RE = re.compile(r"kXESettingsClassNames\[\]\s*=\s*\{(.*?)\};", re.S)

# 设置页入口挂的 6 个方法（运行时按类名动态安装，不在 XE_HOOK 表里）
SETTINGS_SELECTORS = [
    "tableView:numberOfRowsInSection:",
    "tableView:cellForRowAtIndexPath:",
    "tableView:didSelectRowAtIndexPath:",
    "tableView:heightForRowAtIndexPath:",
    "tableView:canEditRowAtIndexPath:",
    "tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:",
]


def parse_settings_classes(path):
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"//[^\n]*", "", src)
    out = []
    for block in SETTINGS_CLASSES_RE.findall(src):
        out.extend(re.findall(r'"([^"]+)"', block))
    return out


def parse_tweak(path):
    """返回 [(class, selector), ...]"""
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = src.replace("\\\n", " ")  # 展开续行
    src = re.sub(r"^\s*#define[^\n]*", "", src, flags=re.M)  # 去掉宏定义本身
    hooks = [(m.group(1), m.group(2)) for m in HOOK_RE.finditer(src)]
    for cls in parse_settings_classes(path):
        hooks.extend((cls, sel) for sel in SETTINGS_SELECTORS)
    return hooks


def main():
    strict = "--strict" in sys.argv
    sym = json.load(open(SYMBOLS, encoding="utf-8"))
    classes = sym["classes"]
    meta = sym["_meta"]

    hooks = parse_tweak(TWEAK)
    if not hooks:
        print("没有解析到任何 XE_HOOK 条目")
        return 1

    ok = miss = 0
    print("目标: %s %s (%s)\n" % (meta.get("app", "迅雷"), meta.get("version", "-"),
                                 meta.get("binary", "TDMVideo")))
    seen = set()
    for cls, sel in hooks:
        if (cls, sel) in seen:
            continue
        seen.add((cls, sel))
        info = classes.get(cls)
        if not info:
            print("  X 类不存在: %s" % cls)
            miss += 1
            continue
        methods = info["methods"]
        if sel in methods:
            print("  OK  %-45s %s" % (cls, sel))
            ok += 1
        else:
            near = [m for m in methods if m.split(":")[0] == sel.split(":")[0]]
            print("  NG  %-45s %s   类内相近方法: %s" % (cls, sel, ", ".join(near) or "无"))
            miss += 1

    print("\n通过 %d 项，异常 %d 项" % (ok, miss))
    return 1 if (strict and miss) else 0


if __name__ == "__main__":
    sys.exit(main())
