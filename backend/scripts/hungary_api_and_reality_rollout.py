#!/usr/bin/env python3
"""
Полный rollout для HU-BUD-01 (api.granilink.com + REALITY на 2053):

  1. migrate_hungary_reality_port_to_2053 — БД
  2. patch_hungary_xray_reality_port — Xray config по SSH
  3. deploy_api_proxy_hungary — nginx + certbot по SSH

  python3 backend/scripts/hungary_api_and_reality_rollout.py

Требует: backend/.env с DATABASE_URL, SSH-ключ в servers.ssh_key_content для 45.12.132.94.
"""
from __future__ import annotations

import os
import subprocess
import sys

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)
from script_env import ensure_script_environment

ensure_script_environment()

BACKEND = os.path.abspath(os.path.join(SCRIPTS, ".."))


def run(name: str, path: str) -> int:
    print(f"\n{'='*60}\n▶ {name}\n{'='*60}")
    env = os.environ.copy()
    env.setdefault("PYTHONPATH", BACKEND)
    r = subprocess.run(
        [sys.executable, path],
        cwd=BACKEND,
        env=env,
    )
    return r.returncode


def main() -> int:
    steps = [
        ("Миграция БД (xray_port)", os.path.join(SCRIPTS, "migrate_hungary_reality_port_to_2053.py")),
        ("Патч Xray REALITY 443→2053", os.path.join(SCRIPTS, "patch_hungary_xray_reality_port.py")),
        ("Деплой nginx API proxy", os.path.join(SCRIPTS, "deploy_api_proxy_hungary.py")),
    ]
    for label, script in steps:
        if not os.path.isfile(script):
            print(f"❌ Нет файла: {script}")
            return 1
        code = run(label, script)
        if code != 0:
            print(f"❌ Остановка: {label} завершился с кодом {code}")
            return code
    print("\n✅ Rollout завершён")
    return 0


if __name__ == "__main__":
    sys.exit(main())
