from typing import Any, Dict, Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.orm import Session

from core.database import get_db
from models.system_setting import SystemSetting
from services.app_config_service import AppConfigService

router = APIRouter()

APP_UPDATE_POLICY_KEY = "app_update_policy"


class AppUpdatePolicyResponse(BaseModel):
    latest_version_code: int = 0
    minimum_supported_version_code: int = 0
    mode: str = "none"
    update_required: bool = False
    message: Optional[str] = None
    check_interval_hours: int = 12


def _get_setting(db: Session, key: str, default: Any) -> Any:
    setting = db.query(SystemSetting).filter(SystemSetting.key == key).first()
    if setting is None or setting.value is None:
        return default
    return setting.value


def _int_value(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _normalize_update_policy(raw: Any) -> Dict[str, Any]:
    policy: Dict[str, Any] = {
        "enabled": False,
        "latest_version_code": 0,
        "minimum_supported_version_code": 0,
        "mode": "none",
        "message": None,
        "check_interval_hours": 12,
    }
    if isinstance(raw, dict):
        policy.update(raw)

    latest = max(0, _int_value(policy.get("latest_version_code")))
    minimum = max(0, _int_value(policy.get("minimum_supported_version_code")))
    check_interval = _int_value(policy.get("check_interval_hours"), 12)
    mode = str(policy.get("mode") or "none").lower().strip()
    if mode not in {"none", "flexible", "immediate"}:
        mode = "none"
    if not bool(policy.get("enabled", False)):
        mode = "none"

    return {
        "latest_version_code": latest,
        "minimum_supported_version_code": minimum,
        "mode": mode,
        "message": policy.get("message"),
        "check_interval_hours": max(1, min(check_interval, 48)),
    }

@router.get("/app-config")
async def get_app_config(
    db: Session = Depends(get_db)
):
    """
    Публичный эндпоинт для получения конфигурации приложений
    Возвращает доступные серверы, протоколы, feature flags
    """
    config_service = AppConfigService(db)
    config = config_service.get_app_config()
    return config


@router.get("/app/update-policy", response_model=AppUpdatePolicyResponse)
async def get_app_update_policy(
    platform: str = "android",
    version_code: int = 0,
    db: Session = Depends(get_db),
) -> AppUpdatePolicyResponse:
    """
    Public lightweight policy for Google Play In-App Updates.

    By default this endpoint is inert. To enable it, set system_settings:
    key = app_update_policy
    value example =
      {
        "enabled": true,
        "latest_version_code": 24,
        "minimum_supported_version_code": 23,
        "mode": "flexible",
        "message": "A GRANI update is available"
      }
    """
    if platform.lower().strip() != "android":
        return AppUpdatePolicyResponse()

    raw_policy = _get_setting(db, APP_UPDATE_POLICY_KEY, {})
    policy = _normalize_update_policy(raw_policy)

    latest = policy["latest_version_code"]
    minimum = policy["minimum_supported_version_code"]
    mode = policy["mode"]

    update_required = False
    if version_code > 0:
        if minimum > 0 and version_code < minimum:
            update_required = True
            mode = "immediate"
        elif latest > 0 and version_code < latest and mode != "none":
            update_required = True
    elif mode != "none":
        update_required = True

    return AppUpdatePolicyResponse(
        latest_version_code=latest,
        minimum_supported_version_code=minimum,
        mode=mode if update_required else "none",
        update_required=update_required,
        message=policy["message"],
        check_interval_hours=policy["check_interval_hours"],
    )


