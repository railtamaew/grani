#!/usr/bin/env python3
import shutil
import os

src = '/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk'
dst = '/opt/grani/granivpn-xray-shadow-fix.apk'

if os.path.exists(src):
    shutil.copy2(src, dst)
    size = os.path.getsize(dst)
    print(f"✅ Copied: {dst}")
    print(f"📏 Size: {size} bytes ({size/1024/1024:.1f} MB)")
else:
    print(f"❌ Source not found: {src}")
