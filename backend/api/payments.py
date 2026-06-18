"""
API платежей. Google Play подписки, RTDN (Real-Time Developer Notifications),
обработка возвратов и voided purchases.
"""
import base64
import json
import logging
from datetime import datetime, timedelta
from typing import Optional, Tuple, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from sqlalchemy.orm import Session, joinedload

from core.config import settings
from core.database import get_db
from core.request_context import get_request_id
from core.cache import invalidate_user_cache
from services.auth_service import AuthService

router = APIRouter()
security = HTTPBearer(auto_error=True)
from models.payment import Payment
from models.subscription import Subscription, Plan
from models.user import User
from services.notification_service import notify_payment_completed, notify_subscription_revoked
from services.simple_vpn_entitlement import suspend_user_graniwg_access

logger = logging.getLogger(__name__)


class GooglePlayVerifyRequest(BaseModel):
    purchase_token: str
    product_id: str
    order_id: Optional[str] = None


class GooglePlayVerifyResponse(BaseModel):
    success: bool
    subscription_id: Optional[int] = None
    message: str


def _google_play_failure_reason(exc: Exception) -> str:
    """Краткая причина сбоя Publisher API для логов (без purchase_token)."""
    try:
        from googleapiclient.errors import HttpError

        if isinstance(exc, HttpError):
            raw = getattr(exc, "content", b"") or b""
            if isinstance(raw, bytes):
                snippet = raw.decode("utf-8", errors="replace")[:400]
            else:
                snippet = str(raw)[:400]
            return f"HttpError http_status={exc.resp.status} body_prefix={snippet!r}"
    except Exception:
        pass
    return f"{type(exc).__name__}: {str(exc)[:400]}"


def _verify_google_play_purchase(
    package_name: str, product_id: str, purchase_token: str
) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Верификация покупки через Google Play Android Publisher API.

    Returns:
        (data, None) при успехе, (None, reason) при ошибке; reason безопасен для логов.
    """
    sa_path = getattr(settings, "google_play_service_account", None)
    if not sa_path:
        logger.warning("google_play_service_account не настроен")
        return None, "service_account_path_missing"
    try:
        from google.oauth2 import service_account
        import googleapiclient.discovery

        credentials = service_account.Credentials.from_service_account_file(sa_path)
        service = googleapiclient.discovery.build("androidpublisher", "v3", credentials=credentials)
        response = (
            service.purchases()
            .subscriptions()
            .get(
                packageName=package_name,
                subscriptionId=product_id,
                token=purchase_token,
            )
            .execute()
        )
        return response, None
    except Exception as e:
        reason = _google_play_failure_reason(e)
        logger.warning("Google Play Publisher API error (product_id=%s): %s", product_id, reason)
        return None, reason


def _get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> User:
    return AuthService.get_current_user(credentials.credentials, db)


@router.post("/google-play/verify", response_model=GooglePlayVerifyResponse)
async def verify_google_play_purchase(
    body: GooglePlayVerifyRequest,
    user: User = Depends(_get_current_user),
    db: Session = Depends(get_db),
):
    """
    Верификация покупки подписки через Google Play.
    Клиент передаёт purchase_token и product_id после успешной покупки.
    """
    rid = get_request_id()
    logger.info(
        "[google-play-verify] start req_id=%s user_id=%s product_id=%s",
        rid,
        user.id,
        body.product_id,
    )

    package_name = getattr(settings, "google_play_package_name", "com.granivpn.mobile") or "com.granivpn.mobile"

    plan = db.query(Plan).filter(Plan.google_play_product_id == body.product_id).first()
    if not plan:
        logger.warning(
            "[google-play-verify] unknown_product req_id=%s user_id=%s product_id=%s",
            rid,
            user.id,
            body.product_id,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Продукт {body.product_id} не найден в тарифах",
        )

    gp_data, gp_fail_reason = _verify_google_play_purchase(package_name, body.product_id, body.purchase_token)
    if not gp_data:
        logger.warning(
            "[google-play-verify] publisher_no_data req_id=%s user_id=%s package=%s product_id=%s reason=%s",
            rid,
            user.id,
            package_name,
            body.product_id,
            gp_fail_reason or "unknown",
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Не удалось верифицировать покупку в Google Play",
        )

    # 1 = payment received, 2 = free trial (sandbox / introductory pricing)
    payment_state = gp_data.get("paymentState")
    if payment_state not in (1, 2):
        logger.warning(
            "[google-play-verify] bad_payment_state req_id=%s user_id=%s paymentState=%s product_id=%s",
            rid,
            user.id,
            payment_state,
            body.product_id,
        )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Покупка не оплачена (paymentState={payment_state})",
        )

    start_time_ms = gp_data.get("startTimeMillis") or gp_data.get("startTime")
    expiry_time_ms = gp_data.get("expiryTimeMillis") or gp_data.get("expiryTime")
    order_id = body.order_id or gp_data.get("orderId")

    if start_time_ms:
        start_date = datetime.utcfromtimestamp(int(start_time_ms) / 1000)
    else:
        start_date = datetime.utcnow()

    if expiry_time_ms:
        end_date = datetime.utcfromtimestamp(int(expiry_time_ms) / 1000)
    else:
        end_date = start_date + timedelta(days=plan.duration_days)

    existing = (
        db.query(Subscription)
        .filter(
            Subscription.user_id == user.id,
            Subscription.external_id == order_id,
            Subscription.source == "google_play",
        )
        .first()
    )
    if existing:
        logger.info(
            "[google-play-verify] dedupe req_id=%s user_id=%s subscription_id=%s",
            rid,
            user.id,
            existing.id,
        )
        return GooglePlayVerifyResponse(
            success=True,
            subscription_id=existing.id,
            message="Подписка уже активирована",
        )

    old_active = (
        db.query(Subscription)
        .filter(
            Subscription.user_id == user.id,
            Subscription.status == "active",
        )
        .first()
    )

    remaining_days = 0
    if old_active and old_active.end_date:
        delta = old_active.end_date - datetime.utcnow()
        remaining_days = max(0, delta.days)
        logger.info(
            "Upgrade: user=%s old_plan=%s remaining_days=%d new_plan=%s",
            user.id, old_active.plan_id, remaining_days, plan.id,
        )

    db.query(Subscription).filter(
        Subscription.user_id == user.id,
        Subscription.status == "active",
    ).update({"status": "expired"})

    if not expiry_time_ms and remaining_days > 0:
        end_date = end_date + timedelta(days=remaining_days)
        logger.info(
            "Upgrade: Google Play expiryTime отсутствует, добавлено %d дней к end_date=%s",
            remaining_days, end_date,
        )

    subscription = Subscription(
        user_id=user.id,
        plan_id=plan.id,
        status="active",
        start_date=start_date,
        end_date=end_date,
        source="google_play",
        external_id=order_id,
        purchase_token=body.purchase_token,
        auto_renew=True,
    )
    db.add(subscription)
    db.flush()

    payment = Payment(
        user_id=user.id,
        plan_id=plan.id,
        amount=plan.price,
        currency="USD",
        payment_method="google_play",
        payment_id=order_id,
        status="completed",
        payment_metadata=json.dumps({
            "product_id": body.product_id,
            "purchase_token": body.purchase_token,
        }),
    )
    db.add(payment)
    db.commit()
    invalidate_user_cache(user.id, include_session_prepare=False)
    db.refresh(subscription)
    db.refresh(payment)

    payment = db.query(Payment).options(
        joinedload(Payment.user),
        joinedload(Payment.plan),
    ).filter(Payment.id == payment.id).first()
    try:
        notify_payment_completed(payment, subscription=subscription)
    except Exception as e:
        logger.exception("notify_payment_completed: %s", e)

    logger.info(
        "[google-play-verify] ok req_id=%s user_id=%s subscription_id=%s plan_id=%s",
        rid,
        user.id,
        subscription.id,
        plan.id,
    )
    return GooglePlayVerifyResponse(
        success=True,
        subscription_id=subscription.id,
        message="Подписка активирована",
    )


# ---------------------------------------------------------------------------
# Google Play RTDN (Real-Time Developer Notifications)
# ---------------------------------------------------------------------------

# notificationType constants
_RTDN_RECOVERED = 1
_RTDN_RENEWED = 2
_RTDN_CANCELED = 3
_RTDN_PURCHASED = 4
_RTDN_ON_HOLD = 5
_RTDN_IN_GRACE_PERIOD = 6
_RTDN_RESTARTED = 7
_RTDN_PRICE_CHANGE_CONFIRMED = 8
_RTDN_DEFERRED = 9
_RTDN_PAUSED = 10
_RTDN_PAUSE_SCHEDULE_CHANGED = 11
_RTDN_REVOKED = 12
_RTDN_EXPIRED = 13


def _find_subscription_by_purchase_token(db: Session, purchase_token: str) -> Optional[Subscription]:
    """Найти подписку по purchase_token (ищем последнюю активную)."""
    return (
        db.query(Subscription)
        .filter(
            Subscription.purchase_token == purchase_token,
            Subscription.source == "google_play",
        )
        .order_by(Subscription.id.desc())
        .first()
    )


def _handle_revoked(db: Session, purchase_token: str, product_id: str):
    """Возврат средств — отозвать подписку и пометить платёж как refunded."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        logger.warning("RTDN REVOKED: подписка не найдена для token=%s", purchase_token[:20])
        return

    if sub.status == "revoked":
        logger.info("RTDN REVOKED: подписка id=%s уже отозвана", sub.id)
        return

    old_status = sub.status
    sub.status = "revoked"
    sub.auto_renew = False

    payment = (
        db.query(Payment)
        .filter(
            Payment.user_id == sub.user_id,
            Payment.payment_id == sub.external_id,
            Payment.status == "completed",
        )
        .first()
    )
    if payment:
        payment.status = "refunded"

    try:
        suspend_user_graniwg_access(db, sub.user_id, reason='subscription_revoked', hard_revoke=True)
    except Exception as e:
        logger.exception("RTDN REVOKED suspend user=%s: %s", sub.user_id, e)
    db.commit()
    invalidate_user_cache(sub.user_id)

    logger.info(
        "RTDN REVOKED: user=%s sub=%s %s->revoked payment=%s",
        sub.user_id, sub.id, old_status,
        payment.id if payment else "not_found",
    )

    sub = db.query(Subscription).options(
        joinedload(Subscription.user),
        joinedload(Subscription.plan),
    ).filter(Subscription.id == sub.id).first()

    try:
        plan_name = sub.plan.name if sub.plan else "Подписка"
        notify_subscription_revoked(sub.user, plan_name)
    except Exception as e:
        logger.exception("RTDN REVOKED notify: %s", e)


def _handle_canceled(db: Session, purchase_token: str, product_id: str):
    """Пользователь отменил автопродление."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        logger.warning("RTDN CANCELED: подписка не найдена для token=%s", purchase_token[:20])
        return

    sub.auto_renew = False
    db.commit()
    invalidate_user_cache(sub.user_id)
    logger.info("RTDN CANCELED: user=%s sub=%s auto_renew=False", sub.user_id, sub.id)


def _handle_renewed(db: Session, purchase_token: str, product_id: str):
    """Автопродление прошло — обновить end_date из Google Play."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        logger.warning("RTDN RENEWED: подписка не найдена для token=%s", purchase_token[:20])
        return

    package_name = getattr(settings, "google_play_package_name", "com.granivpn.mobile") or "com.granivpn.mobile"
    gp_data, gp_fail_reason = _verify_google_play_purchase(package_name, product_id, purchase_token)
    if gp_data:
        expiry_time_ms = gp_data.get("expiryTimeMillis") or gp_data.get("expiryTime")
        if expiry_time_ms:
            sub.end_date = datetime.utcfromtimestamp(int(expiry_time_ms) / 1000)
        sub.status = "active"
        sub.auto_renew = True
        db.commit()
        invalidate_user_cache(sub.user_id)
        logger.info("RTDN RENEWED: user=%s sub=%s new_end=%s", sub.user_id, sub.id, sub.end_date)
    else:
        logger.warning(
            "RTDN RENEWED: не удалось получить данные из GP для sub=%s reason=%s",
            sub.id,
            gp_fail_reason or "unknown",
        )


def _handle_expired(db: Session, purchase_token: str, product_id: str):
    """Подписка истекла."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        logger.warning("RTDN EXPIRED: подписка не найдена для token=%s", purchase_token[:20])
        return

    if sub.status in ("expired", "revoked"):
        return

    sub.status = "expired"
    sub.auto_renew = False
    try:
        suspend_user_graniwg_access(db, sub.user_id, reason='subscription_expired')
    except Exception as e:
        logger.exception("RTDN EXPIRED suspend user=%s: %s", sub.user_id, e)
    db.commit()
    invalidate_user_cache(sub.user_id)
    logger.info("RTDN EXPIRED: user=%s sub=%s", sub.user_id, sub.id)


def _handle_on_hold(db: Session, purchase_token: str, product_id: str):
    """Проблема с оплатой — подписка на удержании."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        return
    sub.auto_renew = False
    try:
        suspend_user_graniwg_access(db, sub.user_id, reason='subscription_on_hold')
    except Exception as e:
        logger.exception("RTDN ON_HOLD suspend user=%s: %s", sub.user_id, e)
    db.commit()
    invalidate_user_cache(sub.user_id)
    logger.info("RTDN ON_HOLD: user=%s sub=%s", sub.user_id, sub.id)


def _handle_recovered(db: Session, purchase_token: str, product_id: str):
    """Подписка восстановлена после проблемы с оплатой."""
    sub = _find_subscription_by_purchase_token(db, purchase_token)
    if not sub:
        return

    package_name = getattr(settings, "google_play_package_name", "com.granivpn.mobile") or "com.granivpn.mobile"
    gp_data, gp_fail_reason = _verify_google_play_purchase(package_name, product_id, purchase_token)
    if gp_data:
        expiry_time_ms = gp_data.get("expiryTimeMillis") or gp_data.get("expiryTime")
        if expiry_time_ms:
            sub.end_date = datetime.utcfromtimestamp(int(expiry_time_ms) / 1000)
        sub.status = "active"
        sub.auto_renew = True
        db.commit()
        invalidate_user_cache(sub.user_id)
        logger.info("RTDN RECOVERED: user=%s sub=%s restored to active", sub.user_id, sub.id)
    else:
        logger.warning(
            "RTDN RECOVERED: не удалось получить данные из GP для sub=%s reason=%s",
            sub.id,
            gp_fail_reason or "unknown",
        )


@router.post("/google-play/rtdn")
async def handle_google_play_rtdn(request: Request, db: Session = Depends(get_db)):
    """
    Webhook для Google Play Real-Time Developer Notifications.
    Google Cloud Pub/Sub отправляет POST с base64-encoded JSON.
    Настройка: Google Play Console → Monetize → Monetization setup → topic name.
    """
    try:
        body = await request.json()
    except Exception:
        logger.warning("RTDN: не удалось разобрать JSON")
        return {"ok": True}

    message = body.get("message", {})
    data_b64 = message.get("data", "")
    if not data_b64:
        logger.warning("RTDN: пустое поле data")
        return {"ok": True}

    try:
        notification = json.loads(base64.b64decode(data_b64))
    except Exception as e:
        logger.warning("RTDN: ошибка декодирования data: %s", e)
        return {"ok": True}

    logger.info("RTDN: получено уведомление: %s", json.dumps(notification, default=str)[:500])

    sub_notification = notification.get("subscriptionNotification")
    if not sub_notification:
        logger.info("RTDN: не subscriptionNotification, пропуск")
        return {"ok": True}

    notification_type = sub_notification.get("notificationType")
    purchase_token = sub_notification.get("purchaseToken", "")
    product_id = sub_notification.get("subscriptionId", "")

    if not purchase_token:
        logger.warning("RTDN: отсутствует purchaseToken")
        return {"ok": True}

    handlers = {
        _RTDN_RECOVERED: _handle_recovered,
        _RTDN_RENEWED: _handle_renewed,
        _RTDN_CANCELED: _handle_canceled,
        _RTDN_REVOKED: _handle_revoked,
        _RTDN_EXPIRED: _handle_expired,
        _RTDN_ON_HOLD: _handle_on_hold,
    }

    handler = handlers.get(notification_type)
    if handler:
        try:
            handler(db, purchase_token, product_id)
        except Exception as e:
            logger.exception("RTDN: ошибка обработки type=%s: %s", notification_type, e)
    else:
        logger.info("RTDN: необработанный тип=%s для product=%s", notification_type, product_id)

    return {"ok": True}


# ---------------------------------------------------------------------------
# Voided Purchases — периодическая проверка
# ---------------------------------------------------------------------------

def check_voided_purchases(db: Session):
    """
    Проверить Voided Purchases API Google Play.
    Вызывать периодически (cron/scheduler) для обнаружения чарджбеков и возвратов,
    которые могли не дойти через RTDN.
    """
    sa_path = getattr(settings, "google_play_service_account", None)
    if not sa_path:
        logger.info("check_voided_purchases: google_play_service_account не настроен, пропуск")
        return

    package_name = getattr(settings, "google_play_package_name", "com.granivpn.mobile") or "com.granivpn.mobile"

    try:
        from google.oauth2 import service_account
        import googleapiclient.discovery

        credentials = service_account.Credentials.from_service_account_file(sa_path)
        service = googleapiclient.discovery.build("androidpublisher", "v3", credentials=credentials)

        since_ms = int((datetime.utcnow() - timedelta(days=3)).timestamp() * 1000)
        response = (
            service.purchases()
            .voidedpurchases()
            .list(packageName=package_name, startTime=since_ms)
            .execute()
        )

        voided = response.get("voidedPurchases", [])
        if not voided:
            logger.info("check_voided_purchases: нет voided purchases за последние 3 дня")
            return

        logger.info("check_voided_purchases: найдено %d voided purchases", len(voided))

        for vp in voided:
            order_id = vp.get("orderId", "")
            purchase_token = vp.get("purchaseToken", "")
            voided_reason = vp.get("voidedReason", 0)  # 0=other, 1=remorse, 2=not_received, 3=defective, 4=accidental, 5=fraud, 6=friendly_fraud, 7=chargeback

            sub = None
            if purchase_token:
                sub = _find_subscription_by_purchase_token(db, purchase_token)
            if not sub and order_id:
                sub = db.query(Subscription).filter(
                    Subscription.external_id == order_id,
                    Subscription.source == "google_play",
                ).first()

            if not sub:
                logger.info("check_voided_purchases: подписка не найдена order=%s", order_id)
                continue

            if sub.status == "revoked":
                continue

            old_status = sub.status
            sub.status = "revoked"
            sub.auto_renew = False

            payment = db.query(Payment).filter(
                Payment.user_id == sub.user_id,
                Payment.payment_id == order_id,
                Payment.status == "completed",
            ).first()
            if payment:
                reason_label = {
                    0: "other", 1: "remorse", 2: "not_received",
                    3: "defective", 4: "accidental", 5: "fraud",
                    6: "friendly_fraud", 7: "chargeback",
                }.get(voided_reason, "unknown")
                payment.status = "refunded"
                meta = json.loads(payment.payment_metadata or "{}")
                meta["voided_reason"] = reason_label
                payment.payment_metadata = json.dumps(meta)

            try:
                suspend_user_graniwg_access(db, sub.user_id, reason='voided_purchase', hard_revoke=True)
            except Exception as e:
                logger.exception("check_voided_purchases suspend user=%s: %s", sub.user_id, e)
            db.commit()
            invalidate_user_cache(sub.user_id)

            logger.info(
                "check_voided_purchases: REVOKED user=%s sub=%s %s->revoked reason=%s",
                sub.user_id, sub.id, old_status, voided_reason,
            )

            sub = db.query(Subscription).options(
                joinedload(Subscription.user),
                joinedload(Subscription.plan),
            ).filter(Subscription.id == sub.id).first()
            try:
                plan_name = sub.plan.name if sub.plan else "Подписка"
                notify_subscription_revoked(sub.user, plan_name)
            except Exception as e:
                logger.exception("check_voided_purchases notify: %s", e)

    except Exception as e:
        logger.exception("check_voided_purchases: %s", e)
