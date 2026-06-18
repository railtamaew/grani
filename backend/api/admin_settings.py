from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel, EmailStr
from typing import Optional, Dict, Any
from datetime import datetime

from core.database import get_db
from core.metrics import metrics_registry
from core.rbac import require_owner
from models.user import User, UserRole
from models.system_setting import SystemSetting
from services.auth_service import AuthService
from services.app_config_service import AppConfigService

router = APIRouter()

SETTINGS_FEATURE_FLAGS_KEY = "feature_flags_override"
SETTINGS_MIN_VERSIONS_KEY = "min_versions_override"
SETTINGS_ROLLOUT_POLICY_KEY = "rollout_policy_override"
SETTINGS_ROLLOUT_STATE_KEY = "rollout_policy_state"
ADMIN_ROLES = (UserRole.OWNER, UserRole.ADMIN, UserRole.SUPPORT, UserRole.READ_ONLY)

DEFAULT_ROLLOUT_POLICY: Dict[str, Any] = {
    "enabled": False,
    "current_percent": 100,
    "auto_rollback_enabled": True,
    "auto_promotion_enabled": True,
    "rollback_percent": 10,
    "promotion_steps": [10, 50, 100],
    "thresholds": {
        "false_connected_rate": 0.15,
        "probe_timeout_rate": 0.30,
        "min_connected_local_total": 20,
    },
}

class UpdateSettingsRequest(BaseModel):
    feature_flags: Optional[Dict[str, Any]] = None
    min_versions: Optional[Dict[str, Any]] = None


class UpdateRolloutPolicyRequest(BaseModel):
    policy: Dict[str, Any]

class CreateAdminRequest(BaseModel):
    email: EmailStr
    password: str
    role: UserRole

class UpdateAdminRequest(BaseModel):
    role: Optional[UserRole] = None
    is_active: Optional[bool] = None

def _get_setting(db: Session, key: str, default: Any) -> Any:
    setting = db.query(SystemSetting).filter(SystemSetting.key == key).first()
    if setting is None:
        return default
    return setting.value if setting.value is not None else default

def _set_setting(db: Session, key: str, value: Any) -> SystemSetting:
    setting = db.query(SystemSetting).filter(SystemSetting.key == key).first()
    if setting is None:
        setting = SystemSetting(key=key, value=value)
        db.add(setting)
    else:
        setting.value = value
    db.commit()
    db.refresh(setting)
    return setting


def _normalize_rollout_policy(raw: Any) -> Dict[str, Any]:
    policy = dict(DEFAULT_ROLLOUT_POLICY)
    if isinstance(raw, dict):
        policy.update({k: v for k, v in raw.items() if k in policy})
        if isinstance(raw.get("thresholds"), dict):
            merged = dict(DEFAULT_ROLLOUT_POLICY["thresholds"])
            merged.update(raw["thresholds"])
            policy["thresholds"] = merged
    return policy


def _should_auto_rollback(
    *,
    policy: Dict[str, Any],
    sli: Dict[str, Any],
    connected_local_total: int,
) -> Dict[str, Any]:
    if not policy.get("enabled", False):
        return {"rollback": False, "reasons": ["rollout_disabled"]}
    if not policy.get("auto_rollback_enabled", True):
        return {"rollback": False, "reasons": ["auto_rollback_disabled"]}

    thresholds = policy.get("thresholds") or {}
    min_sample = int(thresholds.get("min_connected_local_total", 20))
    if connected_local_total < min_sample:
        return {"rollback": False, "reasons": ["insufficient_sample_size"]}

    reasons = []
    false_connected_rate = sli.get("false_connected_rate")
    probe_timeout_rate = sli.get("probe_timeout_rate")

    fc_thr = thresholds.get("false_connected_rate")
    if isinstance(false_connected_rate, (int, float)) and isinstance(fc_thr, (int, float)):
        if false_connected_rate > fc_thr:
            reasons.append("false_connected_rate_above_threshold")

    pt_thr = thresholds.get("probe_timeout_rate")
    if isinstance(probe_timeout_rate, (int, float)) and isinstance(pt_thr, (int, float)):
        if probe_timeout_rate > pt_thr:
            reasons.append("probe_timeout_rate_above_threshold")

    return {"rollback": len(reasons) > 0, "reasons": reasons}


def _next_promotion_percent(policy: Dict[str, Any]) -> Optional[int]:
    steps = policy.get("promotion_steps")
    if not isinstance(steps, list):
        return None
    normalized = []
    for s in steps:
        if isinstance(s, int) and 0 <= s <= 100:
            normalized.append(s)
    if not normalized:
        return None
    normalized = sorted(set(normalized))
    current = int(policy.get("current_percent", 100))
    for step in normalized:
        if step > current:
            return step
    return None


def _is_promotion_eligible(
    *,
    policy: Dict[str, Any],
    sli: Dict[str, Any],
    connected_local_total: int,
) -> Dict[str, Any]:
    if not policy.get("enabled", False):
        return {"eligible": False, "reasons": ["rollout_disabled"]}
    if not policy.get("auto_promotion_enabled", True):
        return {"eligible": False, "reasons": ["auto_promotion_disabled"]}
    thresholds = policy.get("thresholds") or {}
    min_sample = int(thresholds.get("min_connected_local_total", 20))
    if connected_local_total < min_sample:
        return {"eligible": False, "reasons": ["insufficient_sample_size"]}
    false_connected_rate = sli.get("false_connected_rate")
    probe_timeout_rate = sli.get("probe_timeout_rate")
    if false_connected_rate is None or probe_timeout_rate is None:
        return {"eligible": False, "reasons": ["missing_sli_values"]}
    decision = _should_auto_rollback(
        policy=policy,
        sli=sli,
        connected_local_total=connected_local_total,
    )
    if decision.get("rollback"):
        return {"eligible": False, "reasons": decision.get("reasons", [])}
    return {"eligible": True, "reasons": ["healthy_sli_promote"]}

@router.get("/settings")
async def get_settings(
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Настройки системы (readonly)"""
    config_service = AppConfigService(db)
    base_config = config_service.get_app_config()

    feature_flags_override = _get_setting(db, SETTINGS_FEATURE_FLAGS_KEY, {})
    min_versions_override = _get_setting(db, SETTINGS_MIN_VERSIONS_KEY, {})

    return {
        "feature_flags": base_config.get("feature_flags", {}),
        "min_versions": base_config.get("min_versions", {}),
        "feature_flags_override": feature_flags_override,
        "min_versions_override": min_versions_override,
        "updated_at": base_config.get("updated_at")
    }


@router.get("/settings/rollout")
async def get_rollout_settings(
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db),
):
    _ = admin_user
    policy_raw = _get_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, DEFAULT_ROLLOUT_POLICY)
    state = _get_setting(db, SETTINGS_ROLLOUT_STATE_KEY, {})
    policy = _normalize_rollout_policy(policy_raw)
    m = metrics_registry.snapshot().get("vpn_connectivity", {})
    return {
        "policy": policy,
        "state": state if isinstance(state, dict) else {},
        "sli": (m.get("sli") or {}),
        "connected_local_total": m.get("connected_local_total", 0),
    }


@router.put("/settings/rollout")
async def update_rollout_settings(
    payload: UpdateRolloutPolicyRequest,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db),
):
    _ = admin_user
    policy = _normalize_rollout_policy(payload.policy)
    _set_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, policy)
    return {"ok": True, "policy": policy}


@router.post("/settings/rollout/evaluate")
async def evaluate_rollout_settings(
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db),
):
    _ = admin_user
    policy = _normalize_rollout_policy(
        _get_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, DEFAULT_ROLLOUT_POLICY)
    )
    snap = metrics_registry.snapshot().get("vpn_connectivity", {})
    sli = snap.get("sli") or {}
    connected_local_total = int(snap.get("connected_local_total") or 0)
    decision = _should_auto_rollback(
        policy=policy,
        sli=sli,
        connected_local_total=connected_local_total,
    )

    state = _get_setting(db, SETTINGS_ROLLOUT_STATE_KEY, {})
    if not isinstance(state, dict):
        state = {}
    result = {
        "rollback_applied": False,
        "promotion_applied": False,
        "reasons": decision.get("reasons", []),
        "target_percent": policy.get("current_percent", 100),
    }
    if decision.get("rollback"):
        rollback_percent = int(policy.get("rollback_percent", 10))
        feature_flags = _get_setting(db, SETTINGS_FEATURE_FLAGS_KEY, {})
        if not isinstance(feature_flags, dict):
            feature_flags = {}
        feature_flags["connect_flow_canary_percent"] = rollback_percent
        _set_setting(db, SETTINGS_FEATURE_FLAGS_KEY, feature_flags)

        policy["current_percent"] = rollback_percent
        _set_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, policy)
        result["rollback_applied"] = True
        result["target_percent"] = rollback_percent
    elif policy.get("enabled") and policy.get("auto_promotion_enabled", True):
        promo = _is_promotion_eligible(
            policy=policy,
            sli=sli,
            connected_local_total=connected_local_total,
        )
        next_percent = _next_promotion_percent(policy)
        if (
            promo.get("eligible")
            and next_percent is not None
            and next_percent != int(policy.get("current_percent", 100))
        ):
            feature_flags = _get_setting(db, SETTINGS_FEATURE_FLAGS_KEY, {})
            if not isinstance(feature_flags, dict):
                feature_flags = {}
            feature_flags["connect_flow_canary_percent"] = next_percent
            _set_setting(db, SETTINGS_FEATURE_FLAGS_KEY, feature_flags)
            policy["current_percent"] = next_percent
            _set_setting(db, SETTINGS_ROLLOUT_POLICY_KEY, policy)
            result["promotion_applied"] = True
            result["target_percent"] = next_percent
            result["reasons"] = promo.get("reasons", ["healthy_sli_promote"])

    state.update(
        {
            "last_evaluated_at": datetime.utcnow().isoformat() + "Z",
            "last_reasons": result["reasons"],
            "last_rollback_applied": result["rollback_applied"],
            "last_promotion_applied": result["promotion_applied"],
            "last_target_percent": result["target_percent"],
        }
    )
    _set_setting(db, SETTINGS_ROLLOUT_STATE_KEY, state)
    return {
        "ok": True,
        "policy": policy,
        "decision": result,
        "sli": sli,
        "connected_local_total": connected_local_total,
    }

@router.put("/settings")
async def update_settings(
    payload: UpdateSettingsRequest,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Обновление override-настроек"""
    if payload.feature_flags is not None:
        _set_setting(db, SETTINGS_FEATURE_FLAGS_KEY, payload.feature_flags)
    if payload.min_versions is not None:
        _set_setting(db, SETTINGS_MIN_VERSIONS_KEY, payload.min_versions)
    return {"message": "Настройки обновлены"}

@router.get("/settings/admins")
async def get_admins(
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Список администраторов (только Owner)"""
    admins = db.query(User).filter(
        User.role.in_([UserRole.OWNER, UserRole.ADMIN, UserRole.SUPPORT, UserRole.READ_ONLY])
    ).all()
    
    return [
        {
            "id": admin.id,
            "email": admin.email,
            "role": admin.role.value if admin.role else None,
            "is_active": admin.is_active,
            "last_login_at": admin.last_login_at.isoformat() if admin.last_login_at else None,
            "created_at": admin.created_at.isoformat() if admin.created_at else None
        }
        for admin in admins
    ]


@router.post("/settings/admins")
async def create_admin(
    payload: CreateAdminRequest,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Создание нового администратора. Если пользователь с таким email уже есть как обычный пользователь приложения — повышаем до админа."""
    existing = db.query(User).filter(User.email == payload.email.lower()).first()
    if existing:
        if existing.role in ADMIN_ROLES:
            raise HTTPException(
                status_code=400,
                detail="Пользователь с таким email уже является администратором"
            )
        # Обычный пользователь приложения — повышаем до админа
        existing.role = payload.role
        existing.password_hash = AuthService.hash_password(payload.password)
        existing.is_active = True
        existing.is_verified = True
        existing.auth_provider = "email"
        db.commit()
        db.refresh(existing)
        user = existing
    else:
        password_hash = AuthService.hash_password(payload.password)
        user = User(
            email=payload.email.lower(),
            password_hash=password_hash,
            role=payload.role,
            is_active=True,
            is_verified=True,
            auth_provider="email"
        )
        db.add(user)
        db.commit()
        db.refresh(user)

    return {
        "id": user.id,
        "email": user.email,
        "role": user.role.value if user.role else None,
        "is_active": user.is_active,
        "created_at": user.created_at.isoformat() if user.created_at else None
    }

@router.patch("/settings/admins/{admin_id}")
async def update_admin(
    admin_id: int,
    payload: UpdateAdminRequest,
    admin_user: User = Depends(require_owner),
    db: Session = Depends(get_db)
):
    """Изменение роли/активности администратора"""
    target = db.query(User).filter(User.id == admin_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="Администратор не найден")
    
    if payload.role is not None:
        target.role = payload.role
    if payload.is_active is not None:
        target.is_active = payload.is_active
    
    db.commit()
    db.refresh(target)
    
    return {
        "id": target.id,
        "email": target.email,
        "role": target.role.value if target.role else None,
        "is_active": target.is_active,
        "created_at": target.created_at.isoformat() if target.created_at else None
    }



