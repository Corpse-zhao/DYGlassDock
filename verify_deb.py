#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯 Python deb 解包验证（Windows 上没有 ar/lzma-cli 也能跑）"""
import io, os, sys, lzma, bz2, gzip, tarfile, tempfile

def read_ar(path):
    d = open(path, "rb").read()
    assert d[:8] == b"!<arch>\n", "不是 ar 归档"
    out, i = {}, 8
    while i + 60 <= len(d):
        hdr = d[i:i + 60]
        name = hdr[0:16].decode("latin-1").strip()
        size = int(hdr[48:58].decode("latin-1").strip())
        body = d[i + 60:i + 60 + size]
        out[name.rstrip("/")] = body
        i += 60 + size + (size % 2)
    return out

def open_tar(data):
    for fn in (lzma.decompress, gzip.decompress, bz2.decompress, lambda x: x):
        try:
            raw = fn(data)
            tf = tarfile.open(fileobj=io.BytesIO(raw))
            return tf
        except Exception:
            continue
    raise RuntimeError("无法解包 tar")

def main(path):
    print("=== 文件 ===")
    print(f"  {path}  {os.path.getsize(path):,} 字节")
    m = read_ar(path)
    print("\n=== ar 成员 ===")
    for k, v in m.items():
        print(f"  {k:<16} {len(v):>10,}")

    ok = True
    ct = open_tar(m[[k for k in m if k.startswith("control.tar")][0]])
    print("\n=== control ===")
    for n in ct.getnames():
        if n.lstrip("./") in ("control", "control"):
            print(ct.extractfile(n).read().decode())
    ctrl_txt = ""
    for n in ct.getnames():
        if n.lstrip("./") == "control":
            ctrl_txt = ct.extractfile(n).read().decode()

    print("=== 自检 ===")
    checks = [
        ("Architecture 含 iphoneos-arm64e", "iphoneos-arm64e" in ctrl_txt),
        ("是 roothide 产物（文件名 arm64e）", "arm64e" in os.path.basename(path)),
        ("Depends mobilesubstrate", "mobilesubstrate" in ctrl_txt),
    ]
    for label, good in checks:
        print(("  ✅ " if good else "  ❌ ") + label)
        ok = ok and good

    print("\n=== postinst 权限（§63.6）===")
    for ti in ct.getmembers():
        if "postinst" in ti.name:
            good = bool(ti.mode & 0o111)
            print(("  ✅ " if good else "  ❌ ") + f"{ti.name} mode={oct(ti.mode)}")
            ok = ok and good

    dt = open_tar(m[[k for k in m if k.startswith("data.tar")][0]])
    print("\n=== data.tar 载荷 ===")
    names = dt.getnames()
    for n in names:
        print("  ", n)
    dy = [n for n in names if n.endswith(".dylib")]
    pl = [n for n in names if n.endswith(".plist")]
    for n in dy:
        raw = dt.extractfile(n).read()
        magic = raw[:4]
        print(f"\n=== dylib 切片 ===")
        print(f"  {n}")
        print(f"  size={len(raw):,}  magic={magic.hex()}")
        slices = []
        if magic == b"\xca\xfe\xba\xbe":
            # FAT 头（大端）: nfat_arch @4, 每 20 字节一个 arch
            nfat = int.from_bytes(raw[4:8], "big")
            print(f"  FAT 二进制，含 {nfat} 个切片")
            for i in range(nfat):
                off = 8 + i * 20
                ct = int.from_bytes(raw[off:off + 4], "big")
                cs = int.from_bytes(raw[off + 4:off + 8], "big")
                sz = int.from_bytes(raw[off + 12:off + 16], "big")
                label = "arm64e" if (cs & 0x00FFFFFF) == 2 else "arm64"
                slices.append((label, hex(ct), hex(cs), sz))
                print(f"    [{i}] {label:<7} cputype={hex(ct)} cpusubtype={hex(cs)} size={sz:,}")
        else:
            ct = int.from_bytes(raw[4:8], "little")
            cs = int.from_bytes(raw[8:12], "little")
            label = "arm64e" if (cs & 0x00FFFFFF) == 2 else ("arm64" if ct == 0x0100000C else hex(ct))
            slices.append((label, hex(ct), hex(cs), len(raw)))
            print(f"  thin 切片: {label} cputype={hex(ct)} cpusubtype={hex(cs)}")
        # ⚠️ §64：arm64 与 arm64e 靠 cpusubtype 区分，不是 cputype
        labels = [s[0] for s in slices]
        good = "arm64e" in labels and "arm64" in labels
        print(("  ✅ " if good else "  ❌ ") + "arm64 + arm64e 双切片齐全")
        ok = ok and good
    for n in pl:
        raw = dt.extractfile(n).read()
        print(f"\n=== filter plist ===\n  {n}")
        print("  ", raw.decode("utf-8", "replace").strip()[:200])
        good = b"com.ss.iphone.ugc.Aweme" in raw
        print(("  ✅ " if good else "  ❌ ") + "filter 指向抖音")
        ok = ok and good

    print("\n" + ("✅ 验包全部通过" if ok else "❌ 验包存在问题"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
