"""
Загрузка переменных из backend/.env до импорта core.* (DATABASE_URL и прочее).

Путь по умолчанию: <backend>/.env рядом с каталогом scripts/.
Переопределение: GRANI_BACKEND_ENV_FILE=/opt/grani/backend/.env

Не перезаписывает уже заданные в окружении переменные (override=False).
"""
from __future__ import annotations

import os
import sys

_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def ensure_script_environment() -> None:
    if _BACKEND_ROOT not in sys.path:
        sys.path.insert(0, _BACKEND_ROOT)
    env_file = os.environ.get("GRANI_BACKEND_ENV_FILE")
    if env_file:
        env_file = os.path.abspath(os.path.expanduser(env_file))
    else:
        env_file = os.path.join(_BACKEND_ROOT, ".env")
    if not os.path.isfile(env_file):
        return
    try:
        from dotenv import load_dotenv

        load_dotenv(env_file, override=False)
    except ImportError:
        pass
