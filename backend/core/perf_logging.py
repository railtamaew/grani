"""
Отдельный логгер для [perf] таймингов: можно отключить (setLevel CRITICAL),
направить в файл, не смешивать с основным приложением.
"""
from __future__ import annotations

import logging
import logging.handlers
import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from core.config import Settings

perf_logger = logging.getLogger("perf")


def setup_perf_logging(settings: "Settings") -> None:
    """Вызывать один раз после загрузки Settings (из main). propagate=False — нет дублей в root."""
    perf_logger.setLevel(logging.WARNING)
    perf_logger.propagate = False
    if perf_logger.handlers:
        return

    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    sh.setLevel(logging.WARNING)
    perf_logger.addHandler(sh)

    log_dir = os.path.dirname(settings.backend_log_file) or "."
    try:
        os.makedirs(log_dir, exist_ok=True)
    except OSError:
        pass
    perf_path = getattr(settings, "perf_log_file", None) or os.path.join(log_dir, "grani-perf.log")
    fh = logging.handlers.RotatingFileHandler(
        perf_path,
        maxBytes=max(1, int(settings.backend_log_max_bytes)),
        backupCount=max(0, int(settings.backend_log_backup_count)),
        encoding="utf-8",
    )
    fh.setFormatter(fmt)
    fh.setLevel(logging.WARNING)
    perf_logger.addHandler(fh)
