"""
Celery-задачи для отправки уведомлений пользователям (email + push).
"""
import logging
from datetime import datetime, timedelta

from sqlalchemy.orm import joinedload

from core.database import SessionLocal
from domain.models.subscription import Subscription
from services.celery_app import celery_app
from domain.models.user import User

from services.notification_service import (
    notify_subscription_expiry_warning,
)
from services.trial_service import deactivate_trial

logger = logging.getLogger(__name__)

EXPIRY_WARNING_DAYS = [7, 3, 1]


@celery_app.task(bind=True, name='notifications.send_subscription_expiry_warning')
def send_subscription_expiry_warning_task(self):
    """
    Отправка уведомлений о скором истечении подписки (ежедневно в 9:00).
    Выбираются активные подписки, истекающие через 1, 3 или 7 дней.
    """
    try:
        db = SessionLocal()
        try:
            now = datetime.utcnow()
            sent = 0
            errors = 0

            for days in EXPIRY_WARNING_DAYS:
                target_date = (now + timedelta(days=days)).date()
                target_start = datetime.combine(target_date, datetime.min.time())
                target_end = datetime.combine(target_date, datetime.max.time())

                subs = (
                    db.query(Subscription)
                    .options(joinedload(Subscription.user), joinedload(Subscription.plan))
                    .filter(
                        Subscription.status == "active",
                        Subscription.end_date >= target_start,
                        Subscription.end_date <= target_end,
                    )
                    .all()
                )

                for sub in subs:
                    if not sub.user:
                        continue
                    plan_name = sub.plan.name if sub.plan else "Подписка"
                    end_str = sub.end_date.strftime("%d.%m.%Y") if sub.end_date else ""

                    try:
                        ok = notify_subscription_expiry_warning(
                            user=sub.user,
                            plan_name=plan_name,
                            end_date_str=end_str,
                            days_left=days,
                        )
                        if ok:
                            sent += 1
                        else:
                            errors += 1
                    except Exception as e:
                        logger.exception(
                            "send_subscription_expiry_warning: ошибка для user_id=%s: %s",
                            sub.user_id, e
                        )
                        errors += 1

            db.close()
            return {"status": "success", "sent": sent, "errors": errors}
        finally:
            db.close()
    except Exception as e:
        logger.exception("send_subscription_expiry_warning: %s", e)
        return {"status": "error", "error": str(e)}


@celery_app.task(bind=True, name='notifications.check_trial_expiry')
def check_trial_expiry_task(self):
    """
    Проверка истечения триалов (каждые 15 минут).
    Деактивирует истёкшие триалы и отправляет уведомление (email + push).
    """
    try:
        db = SessionLocal()
        try:
            now = datetime.utcnow()
            users = db.query(User).filter(User.trial_active == True).all()
            sent = 0
            deactivated = 0
            for user in users:
                if not user.trial_started_at or not user.trial_seconds_left:
                    continue
                duration = max(0, user.trial_seconds_left or 0)
                trial_end = user.trial_started_at + timedelta(seconds=duration)
                if trial_end > now:
                    continue
                if deactivate_trial(user.id, db, notify_user=True):
                    deactivated += 1
                    if getattr(user, "_trial_end_notification_ok", False):
                        sent += 1
            db.close()
            return {"status": "success", "deactivated": deactivated, "notifications_sent": sent}
        finally:
            db.close()
    except Exception as e:
        logger.exception("check_trial_expiry: %s", e)
        return {"status": "error", "error": str(e)}
