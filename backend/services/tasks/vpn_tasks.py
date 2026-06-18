"""
Фоновые задачи VPN (Xray и др.).
Используются для асинхронного применения конфига на VPN-сервер после быстрого ответа create-client.
"""
import json
import logging
from datetime import datetime

from sqlalchemy.orm import joinedload

from core.database import SessionLocal
from core.config import settings
from models.server import Server
from models.subscription import Subscription
from services.xray_manager import XrayManager
from services.edge_enqueue import count_active_xray_sessions_for_server, enqueue_apply_xray_config
from services.celery_app import celery_app
from services.notification_service import notify_subscription_expired
from services.simple_vpn_entitlement import suspend_user_graniwg_access

logger = logging.getLogger(__name__)


@celery_app.task(bind=True, name="vpn.check_subscription_expiry")
def check_subscription_expiry_task(self):
    """
    Проверка истечения подписок (каждый час).
    Помечает истёкшие подписки и отправляет письмо об истечении.
    """
    try:
        db = SessionLocal()
        try:
            now = datetime.utcnow()
            expired = db.query(Subscription).options(
                joinedload(Subscription.user),
                joinedload(Subscription.plan),
            ).filter(
                Subscription.status == "active",
                Subscription.end_date <= now,
            ).all()
            sent = 0
            for sub in expired:
                sub.status = "expired"
                try:
                    suspend_user_graniwg_access(db, sub.user_id, reason='subscription_expired')
                except Exception as e:
                    logger.exception("check_subscription_expiry: suspend user_id=%s: %s", sub.user_id, e)
                if sub.user:
                    plan_name = sub.plan.name if sub.plan else "Подписка"
                    try:
                        if notify_subscription_expired(sub.user, plan_name):
                            sent += 1
                    except Exception as e:
                        logger.exception("check_subscription_expiry: уведомление для user_id=%s: %s", sub.user_id, e)
            db.commit()
            return {"status": "success", "expired": len(expired), "emails_sent": sent}
        finally:
            db.close()
    except Exception as e:
        logger.exception("check_subscription_expiry: %s", e)
        return {"status": "error", "error": str(e)}


@celery_app.task(bind=True, name="vpn.apply_xray_config")
def apply_xray_config_to_vpn(self, server_id: int, config_json: str):
    """
    Применяет конфигурацию Xray на VPN-сервер (запись файла + systemctl reload).
    Вызывается после того, как API уже вернул клиенту конфиг; клиент поднимает туннель,
    через 2–6 с конфиг применяется на сервере и трафик начинает идти.
    """
    try:
        db = SessionLocal()
        try:
            server = db.query(Server).filter(Server.id == server_id).first()
            if not server:
                logger.error("apply_xray_config_to_vpn: сервер id=%s не найден", server_id)
                return {"status": "error", "error": "server not found"}
            config = json.loads(config_json)
            db.refresh(server)
            xray_manager = XrayManager()
            config_revision = xray_manager._calc_config_revision(config)
            config_sha256 = xray_manager._calc_config_sha256(config)
            aid = enqueue_apply_xray_config(db, server, config)
            if aid:
                db.commit()
                xray_manager.set_last_apply_state(
                    server,
                    {
                        "status": "queued",
                        "ack_mode": "edge_assignment",
                        "apply_branch": "edge_from_celery_task",
                        "edge_assignment_id": aid,
                        "config_revision": config_revision,
                        "config_sha256": config_sha256,
                        "updated_at": datetime.utcnow().isoformat() + "Z",
                    },
                )
                logger.info(
                    "apply_xray_config_to_vpn: server_id=%s via=edge assignment_id=%s",
                    server_id,
                    aid,
                )
                return {
                    "status": "success",
                    "server_id": server_id,
                    "via": "edge",
                    "edge_assignment_id": aid,
                }
            active = count_active_xray_sessions_for_server(db, server_id)
            if active > 0:
                retry_sec = max(5, int(getattr(settings, "xray_apply_retry_delay_sec", 60) or 60))
                apply_xray_config_to_vpn.apply_async(
                    args=[server_id, config_json],
                    countdown=retry_sec,
                )
                logger.warning(
                    "apply_xray_config_to_vpn: deferred sync_ssh server_id=%s active_sessions=%s retry_sec=%s",
                    server_id,
                    active,
                    retry_sec,
                )
                return {
                    "status": "deferred",
                    "server_id": server_id,
                    "reason": "active_xray_sessions",
                    "active_sessions": active,
                    "retry_sec": retry_sec,
                }
            last_state = xray_manager.get_last_apply_state(server) or {}
            if (
                last_state.get("config_sha256") == config_sha256
                and str(last_state.get("status") or "") == "applied"
            ):
                logger.info(
                    "apply_xray_config_to_vpn: skip duplicate sha256 server_id=%s prefix=%s",
                    server_id,
                    (config_sha256 or "")[:16],
                )
                return {
                    "status": "success",
                    "server_id": server_id,
                    "skipped": "duplicate_sha256",
                }
            success = xray_manager.apply_config_to_server(server, config)
            xray_manager.set_last_apply_state(
                server,
                {
                    "status": "applied" if success else "failed",
                    "ack_mode": "sync_ssh" if success else "none",
                    "apply_branch": "sync_ssh_from_celery_task",
                    "config_revision": config_revision,
                    "config_sha256": config_sha256,
                    "updated_at": datetime.utcnow().isoformat() + "Z",
                },
            )
            return {"status": "success" if success else "error", "server_id": server_id}
        finally:
            db.close()
    except Exception as e:
        logger.exception("apply_xray_config_to_vpn: server_id=%s error=%s", server_id, e)
        return {"status": "error", "error": str(e)}
