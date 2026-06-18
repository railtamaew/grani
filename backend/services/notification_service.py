"""
Сервис отправки уведомлений пользователям (email + push).

Использование:
- notify_subscription_created_manually() — вызывается из админки при ручном создании подписки
- notify_payment_completed(payment) — вызывать при создании/обновлении Payment со status='completed'
- notify_payment_failed(payment, reason) — вызывать при status='failed' или 'cancelled'
"""
import logging
from typing import Dict, Optional

from services.email_service import (
    send_payment_success_email,
    send_payment_failed_email,
    send_subscription_activated_email,
    send_subscription_revoked_email,
    send_subscription_expiry_warning_email,
    send_subscription_expired_email,
    send_trial_ended_email,
    _display_plan,
    _pluralize_days,
)
from services.firebase_push_service import send_push_to_user

logger = logging.getLogger(__name__)


def _lang(user) -> str:
    code = (getattr(user, "preferred_language", None) or "en").lower()
    return "ru" if code == "ru" else "en"


def _tr(user, ru: str, en: str) -> str:
    return ru if _lang(user) == "ru" else en


def _push(
    user,
    title: str,
    body: str,
    event: str = "",
    *,
    vpn_stop_reason: Optional[str] = None,
) -> bool:
    """Безопасная отправка push — не бросает исключений.

    Если задан [vpn_stop_reason], в data добавляется grani_action=stop_vpn для
    событийного отключения VPN на клиенте (см. mobile EntitlementFcmReceiver).
    """
    try:
        data: Dict[str, str] = {}
        if event:
            data["event"] = event
        if vpn_stop_reason:
            data["grani_action"] = "stop_vpn"
            data["reason"] = vpn_stop_reason
        return send_push_to_user(user, title, body, data=data if data else None)
    except Exception as e:
        logger.warning("push для user_id=%s не отправлен: %s", getattr(user, "id", "?"), e)
        return False


def notify_payment_completed(payment, subscription=None) -> bool:
    if not payment or not getattr(payment, "user", None):
        return False
    user = payment.user
    email = user.email
    if not email:
        return False
    plan_name = payment.plan.name if payment.plan else "Подписка"
    amount = getattr(payment, "amount", 0) or 0
    currency = getattr(payment, "currency", None) or "RUB"
    end_date_str = ""
    if subscription is not None and getattr(subscription, "end_date", None):
        end_date_str = subscription.end_date.strftime("%d.%m.%Y")
    elif hasattr(user, "subscriptions") and user.subscriptions:
        active = next((s for s in user.subscriptions if s.status == "active"), None)
        if active and active.end_date:
            end_date_str = active.end_date.strftime("%d.%m.%Y")
    try:
        email_ok = send_payment_success_email(
            to_email=email,
            plan_name=plan_name,
            amount=float(amount),
            currency=currency,
            end_date_str=end_date_str or "—",
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_payment_completed email: %s", e)
        email_ok = False

    dp = _display_plan(plan_name)
    push_ok = _push(user, _tr(user, "Оплата получена", "Payment received"),
                    _tr(user, f"«{dp}» продлена до {end_date_str or '—'}", f"\"{dp}\" extended until {end_date_str or '—'}"),
                    event="payment_completed")
    logger.info(
        "notify_payment_completed user_id=%s payment_id=%s email_ok=%s push_ok=%s end_date=%s",
        getattr(user, "id", None),
        getattr(payment, "id", None),
        email_ok,
        push_ok,
        end_date_str or "—",
    )
    return email_ok or push_ok


def notify_payment_failed(payment, reason: str = "") -> bool:
    if not payment or not getattr(payment, "user", None):
        return False
    user = payment.user
    email = user.email
    if not email:
        return False
    plan_name = payment.plan.name if payment.plan else "Подписка"
    amount = getattr(payment, "amount", 0) or 0
    currency = getattr(payment, "currency", None) or "RUB"
    try:
        email_ok = send_payment_failed_email(
            to_email=email,
            plan_name=plan_name,
            amount=float(amount),
            currency=currency,
            reason=reason,
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_payment_failed email: %s", e)
        email_ok = False

    _push(user, _tr(user, "Платёж не прошёл", "Payment failed"),
          _tr(user, "Проверьте способ оплаты и попробуйте снова", "Check your payment method and try again"),
          event="payment_failed")
    return email_ok


def notify_subscription_revoked(user, plan_name: str) -> bool:
    if not user or not user.email:
        return False
    try:
        email_ok = send_subscription_revoked_email(
            to_email=user.email,
            plan_name=plan_name or "Подписка",
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_subscription_revoked email: %s", e)
        email_ok = False

    _push(
        user,
        _tr(user, "Подписка отменена", "Subscription cancelled"),
        _tr(user, "Доступ к VPN приостановлен. Оформите подписку заново", "VPN access paused. Subscribe again"),
        event="subscription_revoked",
        vpn_stop_reason="subscription_revoked",
    )
    return email_ok


def notify_subscription_created_manually(user, plan_name: str, end_date_str: str) -> bool:
    if not user or not user.email:
        return False
    try:
        email_ok = send_subscription_activated_email(
            to_email=user.email,
            plan_name=plan_name or "Подписка",
            end_date_str=end_date_str,
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_subscription_created_manually email: %s", e)
        email_ok = False

    dp = _display_plan(plan_name) if plan_name else "Подписка"
    _push(user, _tr(user, "Подписка активирована", "Subscription activated"),
          _tr(user, f"«{dp}» активна до {end_date_str}. Подключайтесь!", f"\"{dp}\" is active until {end_date_str}. Connect now!"),
          event="subscription_activated")
    return email_ok


def notify_trial_activated(user, duration_minutes: int) -> bool:
    if not user:
        return False
    minutes = max(1, int(duration_minutes or 0))
    if minutes % (24 * 60) == 0:
        days = minutes // (24 * 60)
        ru_duration = f"{days} дн."
        en_duration = f"{days} day(s)"
    elif minutes % 60 == 0:
        hours = minutes // 60
        ru_duration = f"{hours} ч."
        en_duration = f"{hours} hour(s)"
    else:
        ru_duration = f"{minutes} мин."
        en_duration = f"{minutes} min"

    _push(
        user,
        _tr(user, "Пробный доступ подключён", "Trial access enabled"),
        _tr(
            user,
            f"Вам подключён пробный доступ на {ru_duration}. Можно подключаться.",
            f"Trial access is enabled for {en_duration}. You can connect now.",
        ),
        event="trial_activated",
    )
    return True


def notify_subscription_expiry_warning(user, plan_name: str, end_date_str: str, days_left: int) -> bool:
    if not user or not user.email:
        return False
    try:
        email_ok = send_subscription_expiry_warning_email(
            to_email=user.email,
            plan_name=plan_name,
            end_date_str=end_date_str,
            days_left=days_left,
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_subscription_expiry_warning email: %s", e)
        email_ok = False

    dp = _display_plan(plan_name)
    days_str = _pluralize_days(days_left)
    _push(
          user,
          _tr(user, f"Подписка истекает через {days_str}", f"Subscription expires in {days_left} day(s)"),
          _tr(user, f"Продлите «{dp}» до {end_date_str}, чтобы не потерять доступ", f"Renew \"{dp}\" before {end_date_str} to keep access"),
          event="subscription_expiry_warning")
    return email_ok


def notify_subscription_expired(user, plan_name: str) -> bool:
    if not user or not user.email:
        return False
    try:
        email_ok = send_subscription_expired_email(
            to_email=user.email,
            plan_name=plan_name,
            language=_lang(user),
        )
    except Exception as e:
        logger.exception("notify_subscription_expired email: %s", e)
        email_ok = False

    push_ok = _push(
        user,
        _tr(user, "Подписка истекла", "Subscription expired"),
        _tr(user, "Продлите подписку в приложении GRANI", "Renew subscription in GRANI app"),
        event="subscription_expired",
        vpn_stop_reason="subscription_expired",
    )
    return email_ok or push_ok


def notify_trial_ended(user) -> bool:
    if not user or not user.email:
        return False
    try:
        email_ok = send_trial_ended_email(to_email=user.email, language=_lang(user))
    except Exception as e:
        logger.exception("notify_trial_ended email: %s", e)
        email_ok = False

    push_ok = _push(
        user,
        _tr(user, "Пробный период завершён", "Trial ended"),
        _tr(user, "Оформите подписку, чтобы продолжить пользоваться GRANI", "Subscribe to continue using GRANI"),
        event="trial_ended",
        vpn_stop_reason="trial_ended",
    )
    return email_ok or push_ok
