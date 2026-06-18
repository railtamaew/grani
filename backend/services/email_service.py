"""
Email templates and delivery helpers for GRANI.
"""
import logging
from html import escape
from typing import Optional, Sequence, Tuple

from core.config import settings

logger = logging.getLogger(__name__)

_APP_URL = "https://play.google.com/store/apps/details?id=com.granivpn.mobile"
_SUPPORT_EMAIL = "support@granilink.com"
_PRIVACY_URL = "https://granilink.com/privacy"

_PLAN_DISPLAY_NAMES_RU = {
    "Месячная": "Premium на месяц",
    "Полугодовая": "Premium на 6 месяцев",
    "Годовая": "Premium на год",
    "Trial": "Пробный период",
    "Подписка": "Подписка",
}

_PLAN_DISPLAY_NAMES_EN = {
    "Месячная": "Monthly Premium",
    "Полугодовая": "6-month Premium",
    "Годовая": "Annual Premium",
    "Trial": "Trial",
    "Подписка": "Subscription",
}

_KIND_COLORS = {
    "info": {
        "accent": "#FF7A00",
        "accent_soft": "#FFF3E8",
        "badge_bg": "#FFF8F0",
        "badge_text": "#B85A00",
        "badge_border": "#FFE1BE",
    },
    "success": {
        "accent": "#FF8A1F",
        "accent_soft": "#FFF1E4",
        "badge_bg": "#F4FFF9",
        "badge_text": "#247853",
        "badge_border": "#D8F5E6",
    },
    "warning": {
        "accent": "#E99237",
        "accent_soft": "#FFF5E8",
        "badge_bg": "#FFF7ED",
        "badge_text": "#A85D11",
        "badge_border": "#FFE1BA",
    },
    "danger": {
        "accent": "#E46E61",
        "accent_soft": "#FFF0EE",
        "badge_bg": "#FFF4F2",
        "badge_text": "#B94B42",
        "badge_border": "#F6D4D0",
    },
}


def _normalize_language(language: Optional[str]) -> str:
    lang = (language or "").strip().lower()
    return "ru" if lang == "ru" else "en"


def _is_ru(language: Optional[str]) -> bool:
    return _normalize_language(language) == "ru"


def _h(value: object) -> str:
    return escape("" if value is None else str(value), quote=True)


def _display_plan(plan_name: str, language: str = "ru") -> str:
    names = _PLAN_DISPLAY_NAMES_RU if _is_ru(language) else _PLAN_DISPLAY_NAMES_EN
    return names.get(plan_name, plan_name)


def _pluralize_days(n: int) -> str:
    abs_n = abs(n)
    if 11 <= abs_n % 100 <= 19:
        return f"{n} дней"
    mod10 = abs_n % 10
    if mod10 == 1:
        return f"{n} день"
    if 2 <= mod10 <= 4:
        return f"{n} дня"
    return f"{n} дней"


def _days_label(days_left: int, language: str) -> str:
    return _pluralize_days(days_left) if _is_ru(language) else f"{days_left} day(s)"


def _amount_display(amount: float, currency: str) -> str:
    currency = (currency or "RUB").upper()
    if currency == "RUB":
        return f"{amount:.0f} ₽"
    return f"{amount:.0f} {currency}"


def _rights(language: str) -> str:
    return "© 2026 GRANI. Все права защищены." if _is_ru(language) else "© 2026 GRANI. All rights reserved."


def _hello(language: str) -> str:
    return "Здравствуйте!" if _is_ru(language) else "Hello!"


def _support_line(language: str) -> str:
    if _is_ru(language):
        return f'Если возник вопрос, напишите нам: <a href="mailto:{_SUPPORT_EMAIL}" style="color:#192F3F;text-decoration:underline;">{_SUPPORT_EMAIL}</a>.'
    return f'If you have a question, contact us: <a href="mailto:{_SUPPORT_EMAIL}" style="color:#192F3F;text-decoration:underline;">{_SUPPORT_EMAIL}</a>.'


def _status_badge(label: str, kind: str) -> str:
    colors = _KIND_COLORS.get(kind, _KIND_COLORS["info"])
    return (
        '<div style="text-align:center;margin:0 0 18px;">'
        f'<span style="display:inline-block;padding:7px 13px;border-radius:999px;'
        f'font-size:12px;line-height:16px;font-weight:700;letter-spacing:.02em;'
        f'color:{colors["badge_text"]};background:{colors["badge_bg"]};'
        f'border:1px solid {colors["badge_border"]};">{_h(label)}</span>'
        '</div>'
    )


def _cta_button(label: str, url: str = _APP_URL) -> str:
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
        'style="margin:28px 0 8px;"><tr><td align="center">'
        f'<a href="{_h(url)}" style="display:inline-block;padding:14px 26px;'
        'border-radius:999px;background:#192F3F;color:#FFFFFF;font-size:15px;'
        'font-weight:700;line-height:20px;text-decoration:none;'
        'box-shadow:0 18px 36px rgba(25,47,63,.18);">'
        f'{_h(label)}</a>'
        '</td></tr></table>'
    )


def _detail_card(rows: Sequence[Tuple[str, str]]) -> str:
    body = []
    for index, (label, value) in enumerate(rows):
        border = "" if index == len(rows) - 1 else "border-bottom:1px solid #E8EEF3;"
        body.append(
            f'<tr><td style="padding:13px 0;{border}color:#6F7F8E;'
            'font-size:13px;line-height:18px;">'
            f'{_h(label)}</td>'
            f'<td align="right" style="padding:13px 0;{border}color:#192F3F;'
            'font-size:14px;line-height:18px;font-weight:700;">'
            f'{_h(value)}</td></tr>'
        )
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
        'style="margin:22px 0;border-radius:22px;background:#F8FAFC;'
        'border:1px solid #E3EBF2;padding:0 20px;">'
        f'{"".join(body)}'
        '</table>'
    )


def _notice_card(text: str, kind: str = "info") -> str:
    colors = _KIND_COLORS.get(kind, _KIND_COLORS["info"])
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
        f'style="margin:20px 0;border-radius:20px;background:{colors["accent_soft"]};'
        f'border:1px solid {colors["badge_border"]};"><tr><td style="padding:16px 18px;'
        f'font-size:14px;line-height:21px;color:#192F3F;">{text}</td></tr></table>'
    )


def _code_block(verification_code: str) -> str:
    code = "".join(ch for ch in str(verification_code) if ch.strip()) or str(verification_code)
    digits = "".join(
        '<span style="display:inline-block;min-width:34px;margin:0 3px;padding:10px 0;'
        'border-radius:14px;background:#FFFFFF;border:1px solid #E4ECF3;'
        'box-shadow:0 10px 24px rgba(25,47,63,.08);color:#192F3F;'
        'font-size:28px;line-height:30px;font-weight:800;text-align:center;">'
        f'{_h(ch)}</span>'
        for ch in code
    )
    return (
        '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
        'style="margin:24px 0;border-radius:26px;background:#F8FAFC;'
        'border:1px solid #E3EBF2;box-shadow:inset 0 1px 0 rgba(255,255,255,.9);">'
        '<tr><td align="center" style="padding:24px 12px;">'
        f'{digits}'
        '</td></tr></table>'
    )


def _email_base_html(
    title: str,
    lead: str,
    content_html: str,
    *,
    language: str = "en",
    kind: str = "info",
    badge: Optional[str] = None,
    preheader: Optional[str] = None,
) -> str:
    lang = _normalize_language(language)
    colors = _KIND_COLORS.get(kind, _KIND_COLORS["info"])
    preheader_text = preheader or lead
    privacy_label = "Политика конфиденциальности" if _is_ru(lang) else "Privacy Policy"
    support_label = "Поддержка" if _is_ru(lang) else "Support"
    badge_html = _status_badge(badge, kind) if badge else ""

    return f"""<!DOCTYPE html>
<html lang="{lang}">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{_h(title)}</title>
</head>
<body style="margin:0;padding:0;background:#F7F9FA;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
  <div style="display:none;overflow:hidden;line-height:1px;opacity:0;max-height:0;max-width:0;color:#F7F9FA;">
    {_h(preheader_text)}
  </div>
  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F7F9FA;">
    <tr>
      <td align="center" style="padding:28px 14px 34px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:600px;">
          <tr>
            <td style="padding:0 0 14px;text-align:center;">
              <div style="display:inline-block;padding:13px 20px;border-radius:999px;background:#FFFFFF;border:1px solid #E5ECF2;box-shadow:0 18px 46px rgba(25,47,63,.08);">
                <span style="font-family:Arial,Helvetica,sans-serif;font-size:18px;line-height:20px;font-weight:800;letter-spacing:.14em;color:#192F3F;">GRANI</span>
              </div>
            </td>
          </tr>
          <tr>
            <td style="border-radius:30px;background:#FFFFFF;border:1px solid #E5ECF2;box-shadow:0 24px 60px rgba(25,47,63,.10);overflow:hidden;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
                <tr>
                  <td style="padding:32px 30px 28px;font-family:Arial,Helvetica,sans-serif;">
                    {badge_html}
                    <h1 style="margin:0 0 12px;color:#192F3F;font-size:28px;line-height:34px;font-weight:800;text-align:center;letter-spacing:0;">{_h(title)}</h1>
                    <p style="margin:0 auto 24px;max-width:440px;color:#5F6F7E;font-size:15px;line-height:23px;text-align:center;">{_h(lead)}</p>
                    {content_html}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td align="center" style="padding:22px 18px 0;font-family:Arial,Helvetica,sans-serif;color:#8090A0;font-size:12px;line-height:18px;">
              <div style="margin-bottom:8px;">{_h(_rights(lang))}</div>
              <a href="mailto:{_SUPPORT_EMAIL}" style="color:#607080;text-decoration:underline;">{support_label}</a>
              <span style="color:#C6D0D9;padding:0 8px;">•</span>
              <a href="{_PRIVACY_URL}" style="color:#607080;text-decoration:underline;">{privacy_label}</a>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""


def create_verification_email_text(verification_code: str, email: str, language: str = "en") -> str:
    lang = _normalize_language(language)
    if _is_ru(lang):
        return f"""Здравствуйте!

Код входа в GRANI:

{verification_code}

Код действителен 10 минут.

Если вы не запрашивали этот код, просто проигнорируйте письмо.

{_rights(lang)}
"""
    return f"""Hello!

Your GRANI sign-in code:

{verification_code}

The code is valid for 10 minutes.

If you did not request this code, please ignore this email.

{_rights(lang)}
"""


def create_verification_email_html(verification_code: str, email: str, language: str = "en") -> str:
    lang = _normalize_language(language)
    if _is_ru(lang):
        title = "Код подтверждения"
        lead = "Введите этот код в приложении GRANI, чтобы завершить вход."
        badge = "Вход в аккаунт"
        rows = [
            ("Аккаунт", email),
            ("Действителен", "10 минут"),
        ]
        note = "Если вы не запрашивали этот код, письмо можно просто проигнорировать."
    else:
        title = "Verification code"
        lead = "Enter this code in the GRANI app to complete sign-in."
        badge = "Account sign-in"
        rows = [
            ("Account", email),
            ("Valid for", "10 minutes"),
        ]
        note = "If you did not request this code, you can safely ignore this email."

    content = (
        _code_block(verification_code)
        + _detail_card(rows)
        + _notice_card(_h(note), "info")
    )
    return _email_base_html(title, lead, content, language=lang, kind="info", badge=badge)


def send_verification_email(
    to_email: str,
    verification_code: str,
    language: str = "en",
    from_email: Optional[str] = None,
    from_name: Optional[str] = None,
) -> bool:
    logger.info("[email_service] Начало отправки email на %s", to_email)

    import os
    import sys

    backend_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if backend_root not in sys.path:
        sys.path.insert(0, backend_root)

    try:
        from aws_ses_service import send_verification_email_ses
        logger.debug("[email_service] aws_ses_service успешно импортирован")
    except ImportError as e:
        logger.error("[email_service] Не удалось импортировать aws_ses_service: %s", e, exc_info=True)
        return False

    use_aws_ses = getattr(settings, "use_aws_ses", False)
    has_aws_keys = (
        hasattr(settings, "aws_access_key_id") and settings.aws_access_key_id
        and hasattr(settings, "aws_secret_access_key") and settings.aws_secret_access_key
    )

    logger.info("[email_service] use_aws_ses=%s, has_aws_keys=%s", use_aws_ses, bool(has_aws_keys))

    if use_aws_ses or has_aws_keys:
        try:
            result = send_verification_email_ses(
                to_email=to_email,
                verification_code=verification_code,
                language=_normalize_language(language),
                from_email=from_email,
                from_name=from_name,
            )
            if result:
                logger.info("[email_service] Email успешно отправлен на %s", to_email)
            else:
                logger.error("[email_service] Не удалось отправить email на %s", to_email)
            return result
        except Exception as e:
            logger.error("[email_service] Исключение при отправке email на %s: %s", to_email, e, exc_info=True)
            return False

    logger.error("[email_service] SMTP отправка не реализована. Используйте AWS SES/Postbox.")
    return False


def _send_raw_email(to_email: str, subject: str, text_body: str, html_body: str) -> bool:
    """Отправка произвольного письма через SES/Postbox."""
    import os
    import sys

    backend_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if backend_root not in sys.path:
        sys.path.insert(0, backend_root)
    try:
        from aws_ses_service import send_raw_email_ses
    except ImportError:
        logger.error("[email_service] Не удалось импортировать aws_ses_service")
        return False

    use_aws_ses = getattr(settings, "use_aws_ses", False)
    has_aws_keys = (
        hasattr(settings, "aws_access_key_id") and settings.aws_access_key_id
        and hasattr(settings, "aws_secret_access_key") and settings.aws_secret_access_key
    )
    if not (use_aws_ses or has_aws_keys):
        logger.error("[email_service] SES/Postbox не настроен для отправки писем")
        return False
    return send_raw_email_ses(to_email=to_email, subject=subject, text_body=text_body, html_body=html_body)


def _build_subscription_expiry_warning_email(
    to_email: str,
    plan_name: str,
    end_date_str: str,
    days_left: int,
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    days = _days_label(days_left, lang)
    if _is_ru(lang):
        subject = f"Подписка GRANI истекает через {days}"
        title = "Подписка скоро истечет"
        lead = f"До окончания доступа осталось {days}. Продлите подписку, чтобы VPN работал без пауз."
        text = f"""Здравствуйте!

Ваша подписка «{dp}» истекает {end_date_str}. До окончания доступа осталось {days}.

Продлите подписку, чтобы продолжить пользоваться VPN без перерывов.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Тариф", dp),
            ("Дата окончания", end_date_str),
            ("Осталось", days),
        ]) + _cta_button("Продлить подписку")
        badge = "Требуется внимание"
    else:
        subject = f"Your GRANI subscription expires in {days}"
        title = "Subscription expires soon"
        lead = f"{days} left before your VPN access expires. Renew to keep the connection available."
        text = f"""Hello!

Your subscription "{dp}" expires on {end_date_str}. {days} left.

Renew your subscription to continue using VPN without interruptions.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Plan", dp),
            ("End date", end_date_str),
            ("Time left", days),
        ]) + _cta_button("Renew subscription")
        badge = "Attention needed"
    html = _email_base_html(title, lead, content, language=lang, kind="warning", badge=badge)
    return subject, text, html


def send_subscription_expiry_warning_email(
    to_email: str,
    plan_name: str,
    end_date_str: str,
    days_left: int,
    language: str = "en",
) -> bool:
    return _send_raw_email(
        to_email,
        *_build_subscription_expiry_warning_email(to_email, plan_name, end_date_str, days_left, language),
    )


def _build_subscription_expired_email(
    to_email: str,
    plan_name: str,
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    if _is_ru(lang):
        subject = "Подписка GRANI истекла"
        title = "Подписка истекла"
        lead = "Доступ к VPN приостановлен. Продлите подписку, чтобы снова подключиться."
        text = f"""Здравствуйте!

Ваша подписка «{dp}» истекла.

Продлите подписку, чтобы снова пользоваться VPN.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([("Тариф", dp), ("Статус", "Истекла")]) + _cta_button("Продлить подписку")
        badge = "Доступ приостановлен"
    else:
        subject = "Your GRANI subscription has expired"
        title = "Subscription expired"
        lead = "VPN access is paused. Renew your subscription to connect again."
        text = f"""Hello!

Your subscription "{dp}" has expired.

Renew your subscription to continue using VPN.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([("Plan", dp), ("Status", "Expired")]) + _cta_button("Renew subscription")
        badge = "Access paused"
    html = _email_base_html(title, lead, content, language=lang, kind="danger", badge=badge)
    return subject, text, html


def send_subscription_expired_email(
    to_email: str,
    plan_name: str,
    language: str = "en",
) -> bool:
    return _send_raw_email(to_email, *_build_subscription_expired_email(to_email, plan_name, language))


def _build_trial_ended_email(to_email: str, language: str = "en") -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    if _is_ru(lang):
        subject = "Пробный период GRANI завершен"
        title = "Пробный период завершен"
        lead = "Пробный доступ завершился. Оформите подписку, чтобы продолжить пользоваться VPN."
        text = f"""Здравствуйте!

Ваш пробный период GRANI завершился.

Оформите подписку, чтобы продолжить пользоваться VPN без ограничений.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Аккаунт", to_email),
            ("Статус", "Тест завершен"),
        ]) + _cta_button("Оформить подписку")
        badge = "Trial"
    else:
        subject = "Your GRANI trial has ended"
        title = "Trial ended"
        lead = "Your trial access has ended. Subscribe to continue using VPN."
        text = f"""Hello!

Your GRANI trial has ended.

Subscribe to continue using VPN without limits.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Account", to_email),
            ("Status", "Trial ended"),
        ]) + _cta_button("Subscribe")
        badge = "Trial"
    html = _email_base_html(title, lead, content, language=lang, kind="warning", badge=badge)
    return subject, text, html


def send_trial_ended_email(to_email: str, language: str = "en") -> bool:
    return _send_raw_email(to_email, *_build_trial_ended_email(to_email, language))


def _build_subscription_activated_email(
    to_email: str,
    plan_name: str,
    end_date_str: str,
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    if _is_ru(lang):
        subject = "Подписка GRANI активирована"
        title = "Подписка активна"
        lead = "Доступ к VPN включен. Можно подключаться к защищенному каналу."
        text = f"""Здравствуйте!

Ваша подписка «{dp}» активна до {end_date_str}.

Подключайтесь и пользуйтесь VPN без ограничений.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Тариф", dp),
            ("Активна до", end_date_str),
            ("Статус", "Активна"),
        ]) + _cta_button("Открыть GRANI")
        badge = "Доступ включен"
    else:
        subject = "Your GRANI subscription is active"
        title = "Subscription active"
        lead = "VPN access is enabled. You can connect to the protected channel."
        text = f"""Hello!

Your subscription "{dp}" is active until {end_date_str}.

Connect and use VPN without limits.

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Plan", dp),
            ("Active until", end_date_str),
            ("Status", "Active"),
        ]) + _cta_button("Open GRANI")
        badge = "Access enabled"
    html = _email_base_html(title, lead, content, language=lang, kind="success", badge=badge)
    return subject, text, html


def send_subscription_activated_email(
    to_email: str,
    plan_name: str,
    end_date_str: str,
    language: str = "en",
) -> bool:
    return _send_raw_email(
        to_email,
        *_build_subscription_activated_email(to_email, plan_name, end_date_str, language),
    )


def _build_payment_success_email(
    to_email: str,
    plan_name: str,
    amount: float,
    currency: str,
    end_date_str: str,
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    amount_str = _amount_display(amount, currency)
    if _is_ru(lang):
        subject = "Оплата получена - GRANI"
        title = "Оплата получена"
        lead = "Спасибо за оплату. Подписка продлена, доступ к VPN активен."
        text = f"""Здравствуйте!

Спасибо за оплату. Подписка «{dp}» продлена до {end_date_str}.

Сумма: {amount_str}

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Тариф", dp),
            ("Сумма", amount_str),
            ("Продлена до", end_date_str),
        ]) + _cta_button("Открыть GRANI")
        badge = "Платеж подтвержден"
    else:
        subject = "Payment received - GRANI"
        title = "Payment received"
        lead = "Thank you for your payment. Your subscription is extended and VPN access is active."
        text = f"""Hello!

Thank you for your payment. Your subscription "{dp}" is extended until {end_date_str}.

Amount: {amount_str}

{_APP_URL}

{_rights(lang)}
"""
        content = _detail_card([
            ("Plan", dp),
            ("Amount", amount_str),
            ("Extended until", end_date_str),
        ]) + _cta_button("Open GRANI")
        badge = "Payment confirmed"
    html = _email_base_html(title, lead, content, language=lang, kind="success", badge=badge)
    return subject, text, html


def send_payment_success_email(
    to_email: str,
    plan_name: str,
    amount: float,
    currency: str,
    end_date_str: str,
    language: str = "en",
) -> bool:
    return _send_raw_email(
        to_email,
        *_build_payment_success_email(to_email, plan_name, amount, currency, end_date_str, language),
    )


def _build_subscription_revoked_email(
    to_email: str,
    plan_name: str,
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    if _is_ru(lang):
        subject = "Подписка GRANI отменена"
        title = "Подписка отменена"
        lead = "Доступ к VPN приостановлен после возврата средств через Google Play."
        text = f"""Здравствуйте!

Ваша подписка «{dp}» была отменена в связи с возвратом средств через Google Play.

Доступ к VPN приостановлен. Если это произошло по ошибке, вы можете оформить подписку заново.

{_APP_URL}

Если у вас есть вопросы, напишите нам: {_SUPPORT_EMAIL}

{_rights(lang)}
"""
        content = (
            _detail_card([("Тариф", dp), ("Статус", "Отменена")])
            + _notice_card("Если это произошло по ошибке, оформите подписку заново или напишите в поддержку.", "warning")
            + _cta_button("Оформить подписку")
            + f'<p style="margin:18px 0 0;color:#5F6F7E;font-size:13px;line-height:20px;text-align:center;">{_support_line(lang)}</p>'
        )
        badge = "Доступ приостановлен"
    else:
        subject = "GRANI subscription cancelled"
        title = "Subscription cancelled"
        lead = "VPN access is paused after a Google Play refund."
        text = f"""Hello!

Your subscription "{dp}" was cancelled due to a Google Play refund.

VPN access is paused. If this happened by mistake, you can subscribe again.

{_APP_URL}

If you have any questions, contact us: {_SUPPORT_EMAIL}

{_rights(lang)}
"""
        content = (
            _detail_card([("Plan", dp), ("Status", "Cancelled")])
            + _notice_card("If this happened by mistake, subscribe again or contact support.", "warning")
            + _cta_button("Subscribe again")
            + f'<p style="margin:18px 0 0;color:#5F6F7E;font-size:13px;line-height:20px;text-align:center;">{_support_line(lang)}</p>'
        )
        badge = "Access paused"
    html = _email_base_html(title, lead, content, language=lang, kind="warning", badge=badge)
    return subject, text, html


def send_subscription_revoked_email(
    to_email: str,
    plan_name: str,
    language: str = "en",
) -> bool:
    return _send_raw_email(to_email, *_build_subscription_revoked_email(to_email, plan_name, language))


def _build_payment_failed_email(
    to_email: str,
    plan_name: str,
    amount: float,
    currency: str,
    reason: str = "",
    language: str = "en",
) -> Tuple[str, str, str]:
    lang = _normalize_language(language)
    dp = _display_plan(plan_name, lang)
    amount_str = _amount_display(amount, currency)
    reason = reason or ""
    if _is_ru(lang):
        subject = "Платеж не прошел - GRANI"
        title = "Платеж не прошел"
        lead = "Проверьте способ оплаты и попробуйте снова. Доступ не будет продлен, пока платеж не пройдет."
        reason_line = f"\nПричина: {reason}" if reason else ""
        text = f"""Здравствуйте!

К сожалению, платеж за подписку «{dp}» ({amount_str}) не прошел.{reason_line}

Проверьте способ оплаты и попробуйте снова.

{_APP_URL}

{_rights(lang)}
"""
        rows = [("Тариф", dp), ("Сумма", amount_str)]
        if reason:
            rows.append(("Причина", reason))
        content = _detail_card(rows) + _cta_button("Попробовать снова")
        badge = "Требуется действие"
    else:
        subject = "Payment failed - GRANI"
        title = "Payment failed"
        lead = "Check your payment method and try again. Access will not be extended until payment succeeds."
        reason_line = f"\nReason: {reason}" if reason else ""
        text = f"""Hello!

Unfortunately, payment for subscription "{dp}" ({amount_str}) failed.{reason_line}

Check your payment method and try again.

{_APP_URL}

{_rights(lang)}
"""
        rows = [("Plan", dp), ("Amount", amount_str)]
        if reason:
            rows.append(("Reason", reason))
        content = _detail_card(rows) + _cta_button("Try again")
        badge = "Action needed"
    html = _email_base_html(title, lead, content, language=lang, kind="danger", badge=badge)
    return subject, text, html


def send_payment_failed_email(
    to_email: str,
    plan_name: str,
    amount: float,
    currency: str,
    reason: str = "",
    language: str = "en",
) -> bool:
    return _send_raw_email(
        to_email,
        *_build_payment_failed_email(to_email, plan_name, amount, currency, reason, language),
    )


def create_email_preview_document(language: str = "ru") -> str:
    """Standalone preview page with the current GRANI email templates."""
    lang = _normalize_language(language)
    samples = [
        ("Verification", create_verification_email_html("4913", "railcuber@gmail.com", lang)),
        ("Payment success", _build_payment_success_email("railcuber@gmail.com", "Годовая", 2990, "RUB", "25.06.2026", lang)[2]),
        ("Subscription warning", _build_subscription_expiry_warning_email("railcuber@gmail.com", "Месячная", "25.06.2026", 3, lang)[2]),
        ("Trial ended", _build_trial_ended_email("railcuber@gmail.com", lang)[2]),
        ("Payment failed", _build_payment_failed_email("railcuber@gmail.com", "Месячная", 299, "RUB", "Google Play declined the payment", lang)[2]),
    ]
    sections = []
    for title, html in samples:
        sections.append(
            '<section style="margin:0 0 34px;">'
            f'<h2 style="font:700 18px/24px Arial;color:#192F3F;margin:0 0 12px;">{_h(title)}</h2>'
            '<iframe style="width:100%;height:820px;border:1px solid #DDE6EE;border-radius:20px;background:#F7F9FA;" '
            f'srcdoc="{_h(html)}"></iframe>'
            '</section>'
        )
    return (
        '<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">'
        '<title>GRANI email preview</title></head>'
        '<body style="margin:0;background:#EEF3F7;padding:28px;font-family:Arial,Helvetica,sans-serif;">'
        '<main style="max-width:760px;margin:0 auto;">'
        '<h1 style="font:800 28px/34px Arial;color:#192F3F;margin:0 0 8px;">GRANI email preview</h1>'
        '<p style="font:400 14px/22px Arial;color:#607080;margin:0 0 24px;">Unified email templates for verification, subscription, trial and payments.</p>'
        f'{"".join(sections)}'
        '</main></body></html>'
    )
