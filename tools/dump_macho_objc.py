#!/usr/bin/env python3
"""
从 iOS 可执行文件里导出 ObjC 类 / 方法（含类型编码），输出 symbols.json。

    python3 tools/dump_macho_objc.py Payload/TDMVideo.app/TDMVideo [输出路径] [--all]

要点（macOS 15 / Xcode 16 之后编译的二进制基本都是这个格式）：
  L1  __DATA_CONST,__objc_classlist → class_t
  L2  class_t + 0x20 → class_ro_t（指针走 chained fixups 编码，需要自己解码）
  L3  class_ro_t + 0x00 flags / +0x18 name / +0x20 baseMethodList
  L4  method_list_t：entsizeAndFlags 高位置 1 表示 relative method list（entsize 12）
      每个条目 3 个 int32 相对偏移：name / types / imp
  L5  name 的偏移指向的是 __objc_selrefs 里的槽位，槽位里才是指向
      __objc_methname 的 chained pointer —— 必须再解一次，否则拿到的是乱码；
      types 的偏移则直接落在 __objc_methtype 上。

不依赖任何第三方库。
"""
import json
import re
import struct
import sys

VALID_SEL = re.compile(r"^[A-Za-z_.][A-Za-z0-9_:+.~$]*$")


class MachO:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        data = self.data
        magic = struct.unpack(">I", data[:4])[0]
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            raise SystemExit("这是 fat 二进制，请先用 lipo/thin 拆出 arm64 切片")
        if struct.unpack("<I", data[:4])[0] != 0xFEEDFACF:
            raise SystemExit("不是 64 位 Mach-O")

        self.segs = []
        self.sections = {}
        self.chained = None
        ncmds = struct.unpack("<I", data[16:20])[0]
        p = 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack("<II", data[p:p + 8])
            if cmd == 0x19:  # LC_SEGMENT_64
                name = data[p + 8:p + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", data[p + 24:p + 56])
                nsects = struct.unpack("<I", data[p + 64:p + 68])[0]
                self.segs.append((name, vmaddr, vmsize, fileoff, filesize))
                sp = p + 72
                for _ in range(nsects):
                    sect = data[sp:sp + 16].rstrip(b"\0").decode()
                    seg = data[sp + 16:sp + 32].rstrip(b"\0").decode()
                    addr, size, offset = struct.unpack("<QQI", data[sp + 32:sp + 52])
                    self.sections[seg + "," + sect] = (addr, size, offset)
                    sp += 80
            elif cmd == 0x80000034:  # LC_DYLD_CHAINED_FIXUPS
                self.chained = struct.unpack("<II", data[p + 8:p + 16])
            p += sz

        self.image_base = self.segs[1][1] if self.segs[0][0] == "__PAGEZERO" else self.segs[0][1]

    # ── 地址 → 文件偏移
    def off(self, vm):
        for _n, vmaddr, vmsize, fileoff, filesize in self.segs:
            if vmaddr <= vm < vmaddr + vmsize:
                d = vm - vmaddr
                return fileoff + d if d < filesize else None
        return None

    def read(self, vm, n):
        o = self.off(vm)
        return None if o is None else self.data[o:o + n]

    def u32(self, vm):
        b = self.read(vm, 4)
        return None if not b or len(b) < 4 else struct.unpack("<I", b)[0]

    # ── chained fixup 解码（DYLD_CHAINED_PTR_64）
    def ptr(self, vm):
        o = self.off(vm)
        if o is None:
            return None
        raw = struct.unpack("<Q", self.data[o:o + 8])[0]
        if raw == 0:
            return None
        if raw >> 63:  # bind，指向导入符号
            return None
        target = raw & 0xFFFFFFFFF
        high8 = (raw >> 36) & 0xFF
        return (high8 << 56) | target if high8 else self.image_base + target

    def cstr(self, vm, limit=256):
        o = self.off(vm) if vm else None
        if o is None:
            return None
        e = self.data.find(b"\0", o, o + limit)
        if e < 0:
            return None
        try:
            return self.data[o:e].decode("utf-8")
        except UnicodeDecodeError:
            return None


def dump_methods(m, ro):
    ml = m.ptr(ro + 0x20)
    out = {}
    if not ml:
        return out
    ef = m.u32(ml)
    cnt = m.u32(ml + 4)
    if ef is None or cnt is None or cnt > 8000:
        return out
    relative = (ef & 0xFFFF8000) == 0x80000000
    esz = (ef & 0x0000FFFC) or (12 if relative else 24)
    for k in range(cnt):
        e = ml + 8 + k * esz
        if relative:
            no = m.u32(e)
            to = m.u32(e + 4)
            if no is None:
                continue
            d = struct.unpack("<i", struct.pack("<I", no))[0]
            name = m.cstr(e + d)
            if name is None or not VALID_SEL.match(name):
                slot = m.ptr(e + d)          # selref 槽位 → 真正的字符串
                name = m.cstr(slot) if slot else None
            t = struct.unpack("<i", struct.pack("<I", to))[0] if to is not None else 0
            types = m.cstr(e + 4 + t)
        else:
            np_ = m.ptr(e)
            tp = m.ptr(e + 8)
            name = m.cstr(np_) if np_ else None
            types = m.cstr(tp) if tp else None
        if name and VALID_SEL.match(name):
            out[name] = types
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    out_path = "symbols.json"
    only_used = "--all" not in sys.argv
    for a in sys.argv[2:]:
        if not a.startswith("--"):
            out_path = a

    m = MachO(path)
    list_addr, list_size, _ = m.sections["__DATA_CONST,__objc_classlist"]

    used = None
    if only_used:
        # 只导出 Tweak.m 里 XE_HOOK 用到的类，体积小、便于入库
        import os
        tweak = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Tweak.m")
        if os.path.exists(tweak):
            src = open(tweak, encoding="utf-8").read()
            src = re.sub(r"^\s*#define[^\n]*", "", src, flags=re.M)
            used = set(re.findall(r"XE_HOOK\(\s*([A-Za-z_]\w*)\s*,", src))

    classes = {}
    for i in range(list_size // 8):
        cls = m.ptr(list_addr + i * 8)
        if not cls:
            continue
        data = m.ptr(cls + 0x20)
        if not data:
            continue
        ro = data & 0x00007FFFFFFFFFF8
        name_ptr = m.ptr(ro + 0x18)
        name = m.cstr(name_ptr) if name_ptr else None
        if not name or not VALID_SEL.match(name):
            continue
        if used is not None and name not in used:
            continue

        sup_name = None
        sup = m.ptr(cls + 0x08)
        if sup:
            d2 = m.ptr(sup + 0x20)
            if d2:
                ro2 = d2 & 0x00007FFFFFFFFFF8
                np2 = m.ptr(ro2 + 0x18)
                sup_name = m.cstr(np2) if np2 else None

        classes[name] = {"super": sup_name, "methods": dump_methods(m, ro)}

    result = {
        "_meta": {
            "binary": path.split("/")[-1],
            "source": "__objc_classlist 静态解析",
            "classCount": len(classes),
        },
        "classes": classes,
    }
    if used:
        missing = used - set(classes)
        if missing:
            print("警告：这些类没找到 -> %s" % ", ".join(sorted(missing)))
    json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("导出 %d 个类 -> %s" % (len(classes), out_path))


if __name__ == "__main__":
    main()
