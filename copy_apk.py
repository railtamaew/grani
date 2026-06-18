#!/usr/bin/env python3
import shutil
import os

src = '/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-debug.apk'
dst = '/opt/grani/granivpn-xray-fix.apk'

if os.path.exists(src):
    shutil.copy(src, dst)
    print(f"Copied {src} -> {dst}")
    print(f"Size: {os.path.getsize(dst)} bytes")
else:
    print(f"Source not found: {src}")
