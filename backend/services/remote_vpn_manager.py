"""Re-export: canonical RemoteVPNManager lives in infrastructure.external."""
from infrastructure.external import remote_vpn_manager as _impl

RemoteVPNManager = _impl.RemoteVPNManager
SSH_MANAGER_AVAILABLE = _impl.SSH_MANAGER_AVAILABLE
RETRY_MANAGER_AVAILABLE = _impl.RETRY_MANAGER_AVAILABLE
SSHManager = _impl.SSHManager

__all__ = [
    "RemoteVPNManager",
    "SSH_MANAGER_AVAILABLE",
    "RETRY_MANAGER_AVAILABLE",
    "SSHManager",
]
