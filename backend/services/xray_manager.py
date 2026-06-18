"""Re-export: canonical XrayManager lives in infrastructure.external."""
from infrastructure.external.xray_manager import (
    XrayManager,
    warm_xray_config_cache_for_active_servers,
)

__all__ = ["XrayManager", "warm_xray_config_cache_for_active_servers"]
