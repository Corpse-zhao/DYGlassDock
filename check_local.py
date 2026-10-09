#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地预检：在 CI 之前把「只在编译时才炸」的问题拦下来。
检查项都来自本技能库的血泪教训（§48 / §62 / §63 / §64）。"""
import os, re, sys

FAIL = []

def chk(cond, msg_ok, msg_bad):
    if cond:
        print("  ✅", msg_ok)
    else:
        print("  ❌", msg_bad)
        FAIL.append(msg_bad)

TWEAK = open("Tweak.x", encoding="utf-8").read()
CONTROL = open("control", encoding="utf-8").read()
PLIST = open("DYGlassDock.plist", encoding="utf-8").read()

print("--- 检查 1：control 架构字段 ---")
chk("iphoneos-arm64e" in CONTROL,
    "Architecture 含 iphoneos-arm64e（roothide）",
    "control 缺 iphoneos-arm64e，roothide Sileo 会拒装")

print("--- 检查 2：filter plist 指向抖音 ---")
chk("com.ss.iphone.ugc.Aweme" in PLIST,
    "filter 指向 com.ss.iphone.ugc.Aweme",
    "filter plist 未指向抖音主包")

print("--- 检查 3：%hook 只允许系统公共类 ---")
ALLOWED_HOOKS = {"AVPlayerItem", "AVURLAsset", "NSURLSession", "UIApplication",
                 "UIWindow", "UIView", "UIViewController"}
hooks = re.findall(r"^%hook\s+([A-Za-z_][A-Za-z0-9_]*)", TWEAK, re.M)
print("   hook 目标:", hooks or "(无)")
for h in hooks:
    chk(h in ALLOWED_HOOKS,
        f"%hook {h} 是系统公共类",
        f"%hook {h} 不在允许清单 —— 私有类不存在会被 Logos 静默丢弃（死代码）")

print("--- 检查 4：禁止 makeKeyAndVisible（防抢 key window 瘫痪设备，§48）---")
# ⚠️ §63.5：检查必须用「去掉注释后的源码」，否则注释里提到这个词也会误报
src4 = re.sub(r'//.*', '', TWEAK)
src4 = re.sub(r'/\*.*?\*/', '', src4, flags=re.S)
chk("makeKeyAndVisible" not in src4,
    "代码中未调用 makeKeyAndVisible（注释提及不算）",
    "出现 makeKeyAndVisible —— 自建窗口抢 key window 会导致整机点不动")

print("--- 检查 5：花括号配平（§66：嵌套块会让简单正则失效）---")
# 去掉字符串字面量与注释后计数
src = re.sub(r'//.*', '', TWEAK)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
o, c = src.count("{"), src.count("}")
chk(o == c, f"花括号配平 {{={o} }}={c}", f"花括号不配平 {{={o} }}={c}")
po, pc = src.count("("), src.count(")")
chk(po == pc, f"圆括号配平 (={po} )={pc}", f"圆括号不配平 (={po} )={pc}")

print("--- 检查 6：%end 与 %hook 数量一致 ---")
chk(TWEAK.count("%hook") == TWEAK.count("%end"),
    f"%hook={TWEAK.count('%hook')} %end={TWEAK.count('%end')}",
    f"%hook={TWEAK.count('%hook')} 与 %end={TWEAK.count('%end')} 不一致")

print("--- 检查 7：postinst 可执行位（§63.6：644 会倒在最后一步）---")
# ⚠️ §63.7：Windows 的 os.stat() 权限位不可信（NTFS 无 POSIX 位，一律显示 0666）。
#    真正生效的是 git 里记录的 mode，所以在 Windows 上改查 git index。
if sys.platform == "win32":
    import subprocess
    gi = subprocess.run(["git", "ls-files", "-s", "layout/DEBIAN/postinst"],
                        capture_output=True, text=True)
    out = (gi.stdout or "").strip()
    if out:
        mode_git = out.split()[0]
        chk(mode_git == "100755", f"git 记录 postinst mode={mode_git}",
            f"git 记录 postinst mode={mode_git}（应为 100755），"
            f"需 git update-index --chmod=+x")
    else:
        print("  ⏭️  尚未 git add（Windows stat 不可信），由推送环节保证 100755")
else:
    mode = os.stat("layout/DEBIAN/postinst").st_mode & 0o777
    chk(mode & 0o111, f"postinst 权限 {oct(mode)} 含执行位",
        f"postinst 权限 {oct(mode)} 缺执行位")

print("--- 检查 8：框架都声明在 Makefile ---")
mk = open("Makefile", encoding="utf-8").read()
for fw in ("UIKit", "Foundation", "AVFoundation", "Photos"):
    chk(fw in mk, f"Makefile 已链接 {fw}", f"Makefile 缺 {fw}")

print()
if FAIL:
    print(f"❌ 预检失败 {len(FAIL)} 项：")
    for f in FAIL:
        print("   -", f)
    sys.exit(1)
print("✅ 全部预检通过")
