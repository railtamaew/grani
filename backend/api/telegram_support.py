import asyncio
import logging
from typing import Any, Dict, Optional, Union

import redis
import requests
from fastapi import APIRouter, Header, Request

from core.config import settings


router = APIRouter(prefix="/api/telegram/support", tags=["telegram-support"])
logger = logging.getLogger(__name__)

_user_lang: Dict[int, str] = {}
_user_grani_id: Dict[int, str] = {}
_user_topic: Dict[int, str] = {}
_redis_client: Optional[redis.Redis] = None
_state_ttl_sec = 14 * 24 * 60 * 60

TOPICS = {
    "connection": {
        "en": "Connection issue",
        "ru": "Проблема с подключением",
    },
    "speed": {
        "en": "Speed issue",
        "ru": "Низкая скорость",
    },
    "billing": {
        "en": "Subscription / payment",
        "ru": "Подписка / оплата",
    },
    "login": {
        "en": "Login issue",
        "ru": "Вход в аккаунт",
    },
    "other": {
        "en": "Other",
        "ru": "Другое",
    },
}

TOPIC_PROMPTS = {
    "connection": {
        "en": (
            "Please describe the connection issue in one message.\n"
            "Include the selected server, what happens when you connect, and any error text. "
            "If the GRANI app copied technical details, paste them here too."
        ),
        "ru": (
            "Опишите проблему с подключением одним сообщением.\n"
            "Укажите выбранный сервер, что происходит при подключении и текст ошибки, если он есть. "
            "Если приложение GRANI скопировало технические данные, вставьте их сюда же."
        ),
    },
    "speed": {
        "en": (
            "Please describe the speed issue in one message.\n"
            "Include the selected server, approximate speed, your country/network, and when it happens. "
            "If the GRANI app copied technical details, paste them here too."
        ),
        "ru": (
            "Опишите проблему со скоростью одним сообщением.\n"
            "Укажите выбранный сервер, примерную скорость, вашу страну/сеть и когда это происходит. "
            "Если приложение GRANI скопировало технические данные, вставьте их сюда же."
        ),
    },
    "billing": {
        "en": (
            "Please describe the subscription or payment issue in one message.\n"
            "Include the payment method, date, amount, and what you see in the app."
        ),
        "ru": (
            "Опишите проблему с подпиской или оплатой одним сообщением.\n"
            "Укажите способ оплаты, дату, сумму и что сейчас видно в приложении."
        ),
    },
    "login": {
        "en": (
            "Please describe the login issue in one message.\n"
            "Include your account email, the step where it fails, and any error text."
        ),
        "ru": (
            "Опишите проблему со входом одним сообщением.\n"
            "Укажите email аккаунта, на каком шаге не получается войти и текст ошибки, если он есть."
        ),
    },
    "other": {
        "en": (
            "Please describe the issue in one message.\n"
            "If the GRANI app copied technical details, paste them here too."
        ),
        "ru": (
            "Опишите проблему одним сообщением.\n"
            "Если приложение GRANI скопировало технические данные, вставьте их сюда же."
        ),
    },
}


def _bot_token() -> str:
    return (settings.telegram_support_bot_token or "").strip()


def _support_chat_id() -> str:
    return (settings.telegram_support_chat_id or "").strip()


def _privacy_url() -> str:
    return (settings.telegram_support_privacy_url or "https://granilink.com/privacy").strip()


def _redis() -> Optional[redis.Redis]:
    global _redis_client
    if _redis_client is not None:
        return _redis_client
    try:
        _redis_client = redis.from_url(
            settings.redis_url,
            socket_connect_timeout=2,
            socket_timeout=2,
            decode_responses=True,
        )
        _redis_client.ping()
        return _redis_client
    except Exception as exc:
        logger.warning("Telegram support Redis state unavailable: %s", exc)
        _redis_client = None
        return None


def _state_key(user_id: int, field: str) -> str:
    return f"telegram_support:user:{user_id}:{field}"


def _state_get(user_id: int, field: str, fallback: Optional[str] = None) -> Optional[str]:
    client = _redis()
    if client is not None:
        try:
            value = client.get(_state_key(user_id, field))
            if value is not None:
                return value
        except Exception as exc:
            logger.warning("Telegram support Redis get failed field=%s error=%s", field, exc)

    if field == "lang":
        return _user_lang.get(user_id, fallback)
    if field == "topic":
        return _user_topic.get(user_id, fallback)
    if field == "grani_id":
        return _user_grani_id.get(user_id, fallback)
    return fallback


def _state_set(user_id: int, field: str, value: str) -> None:
    client = _redis()
    if client is not None:
        try:
            client.setex(_state_key(user_id, field), _state_ttl_sec, value)
        except Exception as exc:
            logger.warning("Telegram support Redis set failed field=%s error=%s", field, exc)

    if field == "lang":
        _user_lang[user_id] = value
    elif field == "topic":
        _user_topic[user_id] = value
    elif field == "grani_id":
        _user_grani_id[user_id] = value


def _telegram_url(method: str) -> str:
    return f"https://api.telegram.org/bot{_bot_token()}/{method}"


def _lang(user_id: Optional[int]) -> str:
    if user_id is None:
        return "en"
    value = _state_get(user_id, "lang", "en")
    return value if value in {"en", "ru"} else "en"


def _keyboard(rows: list[list[tuple[str, str]]]) -> Dict[str, Any]:
    return {
        "inline_keyboard": [
            [{"text": text, "callback_data": callback_data} for text, callback_data in row]
            for row in rows
        ]
    }


def _message_lang(message: Dict[str, Any]) -> str:
    text = (message.get("text") or "").lower()
    markup = message.get("reply_markup") or {}
    buttons = markup.get("inline_keyboard") or []
    callback_data = " ".join(
        str(button.get("callback_data", ""))
        for row in buttons
        for button in row
        if isinstance(button, dict)
    )
    if ":ru:" in callback_data:
        return "ru"
    if ":en:" in callback_data:
        return "en"
    if any(word in text for word in ["чем мы можем помочь", "выберите тему", "проблему"]):
        return "ru"
    return "en"


async def _post_telegram(method: str, payload: Dict[str, Any]) -> bool:
    token = _bot_token()
    if not token:
        logger.warning("Telegram support bot token is not configured")
        return False

    def _send() -> bool:
        try:
            response = requests.post(_telegram_url(method), json=payload, timeout=8)
            if response.status_code >= 400:
                logger.warning(
                    "Telegram support API error method=%s status=%s body=%s",
                    method,
                    response.status_code,
                    response.text[:500],
                )
                return False
            return True
        except Exception as exc:
            logger.warning("Telegram support API request failed method=%s error=%s", method, exc)
            return False

    return await asyncio.to_thread(_send)


async def _send_message(
    chat_id: Union[int, str],
    text: str,
    reply_markup: Optional[Dict[str, Any]] = None,
) -> bool:
    payload: Dict[str, Any] = {
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return await _post_telegram("sendMessage", payload)


async def _answer_callback(callback_query_id: str) -> None:
    await _post_telegram("answerCallbackQuery", {"callback_query_id": callback_query_id})


async def _show_language(chat_id: int, user_id: int) -> None:
    if not _state_get(user_id, "lang"):
        _state_set(user_id, "lang", "en")
    text = "GRANI Support\n\nChoose your language:"
    await _send_message(
        chat_id,
        text,
        _keyboard([[("English", "lang:en"), ("Русский", "lang:ru")]]),
    )


async def _show_menu(chat_id: int, user_id: int) -> None:
    lang = _lang(user_id)
    if lang == "ru":
        text = (
            "Чем мы можем помочь?\n\n"
            "Выберите тему. Если вы открыли поддержку из приложения GRANI, "
            "вставьте скопированные технические данные после выбора темы."
        )
    else:
        text = (
            "How can we help?\n\n"
            "Choose a topic. If you opened support from the GRANI app, "
            "paste the copied technical details after selecting a topic."
        )
    await _send_message(
        chat_id,
        text,
        _keyboard(
            [
                [(TOPICS["connection"][lang], f"topic:{lang}:connection")],
                [(TOPICS["speed"][lang], f"topic:{lang}:speed")],
                [(TOPICS["billing"][lang], f"topic:{lang}:billing")],
                [(TOPICS["login"][lang], f"topic:{lang}:login")],
                [(TOPICS["other"][lang], f"topic:{lang}:other")],
            ]
        ),
    )


async def _handle_topic(chat_id: int, user_id: int, topic: str, lang: Optional[str] = None) -> None:
    if topic not in TOPICS:
        topic = "other"
    _state_set(user_id, "topic", topic)
    if lang in {"en", "ru"}:
        _state_set(user_id, "lang", lang)
    else:
        lang = _lang(user_id)
    text = TOPIC_PROMPTS.get(topic, TOPIC_PROMPTS["other"])[lang]
    await _send_message(chat_id, text)


async def _handle_privacy(chat_id: int, user_id: int) -> None:
    if _lang(user_id) == "ru":
        text = f"Политика конфиденциальности GRANI:\n{_privacy_url()}"
    else:
        text = f"GRANI Privacy Policy:\n{_privacy_url()}"
    await _send_message(chat_id, text)


def _telegram_user_label(user: Dict[str, Any]) -> str:
    username = (user.get("username") or "").strip()
    full_name = " ".join(
        part for part in [user.get("first_name"), user.get("last_name")] if part
    ).strip()
    user_id = user.get("id")
    if username:
        return f"@{username} / {user_id}"
    if full_name:
        return f"{full_name} / {user_id}"
    return str(user_id)


async def _forward_support_request(
    user: Dict[str, Any],
    message_text: str,
) -> bool:
    support_chat_id = _support_chat_id()
    if not support_chat_id:
        logger.warning("Telegram support chat id is not configured")
        return False

    user_id = int(user["id"])
    lang = _lang(user_id)
    topic_key = _state_get(user_id, "topic", "other") or "other"
    topic = TOPICS.get(topic_key, TOPICS["other"])[lang]
    grani_id = _state_get(user_id, "grani_id", "not provided") or "not provided"

    operator_text = (
        "New GRANI support request\n\n"
        f"Topic: {topic}\n"
        f"GRANI User ID: {grani_id}\n"
        f"Telegram: {_telegram_user_label(user)}\n"
        f"Language: {lang}\n\n"
        f"Message:\n{message_text}"
    )
    return await _send_message(support_chat_id, operator_text)


async def _handle_text(message: Dict[str, Any]) -> None:
    chat = message.get("chat") or {}
    user = message.get("from") or {}
    text = (message.get("text") or "").strip()
    chat_id = chat.get("id")
    user_id = user.get("id")
    if chat_id is None or user_id is None or not text:
        return

    user_id = int(user_id)
    if text.startswith("/start"):
        parts = text.split(maxsplit=1)
        if len(parts) > 1 and parts[1].startswith("support_"):
            _state_set(user_id, "grani_id", parts[1].replace("support_", "", 1).strip())
        await _show_language(chat_id, user_id)
        return

    if text.startswith("/language"):
        await _show_language(chat_id, user_id)
        return

    if text.startswith("/privacy"):
        await _handle_privacy(chat_id, user_id)
        return

    if text.startswith("/support"):
        await _show_menu(chat_id, user_id)
        return

    forwarded = await _forward_support_request(user, text)
    lang = _lang(user_id)
    if forwarded:
        if lang == "ru":
            await _send_message(chat_id, "Обращение принято. Специалист ответит здесь в Telegram.")
        else:
            await _send_message(chat_id, "Request received. A specialist will reply here in Telegram.")
    else:
        if lang == "ru":
            await _send_message(
                chat_id,
                "Сообщение принято, но маршрут к специалисту еще не настроен. "
                "Пожалуйста, попробуйте позже.",
            )
        else:
            await _send_message(
                chat_id,
                "Message received, but support routing is not configured yet. "
                "Please try again later.",
            )


async def _handle_callback(callback_query: Dict[str, Any]) -> None:
    callback_id = callback_query.get("id")
    message = callback_query.get("message") or {}
    chat = message.get("chat") or {}
    user = callback_query.get("from") or {}
    data = callback_query.get("data") or ""
    chat_id = chat.get("id")
    user_id = user.get("id")
    if callback_id:
        await _answer_callback(callback_id)
    if chat_id is None or user_id is None:
        return

    user_id = int(user_id)
    if data.startswith("lang:"):
        value = data.split(":", 1)[1]
        _state_set(user_id, "lang", "ru" if value == "ru" else "en")
        await _show_menu(chat_id, user_id)
        return

    if data.startswith("topic:"):
        parts = data.split(":")
        if len(parts) == 3:
            await _handle_topic(chat_id, user_id, parts[2], parts[1])
        else:
            await _handle_topic(chat_id, user_id, parts[-1], _message_lang(message))


@router.get("/health")
async def telegram_support_health():
    return {
        "ok": True,
        "bot_token_configured": bool(_bot_token()),
        "support_chat_configured": bool(_support_chat_id()),
        "webhook_secret_configured": bool(
            (settings.telegram_support_webhook_secret or "").strip()
        ),
    }


@router.post("/webhook")
async def telegram_support_webhook(
    request: Request,
    x_telegram_bot_api_secret_token: Optional[str] = Header(default=None),
):
    expected_secret = (settings.telegram_support_webhook_secret or "").strip()
    if expected_secret and x_telegram_bot_api_secret_token != expected_secret:
        logger.warning("Telegram support webhook rejected: invalid secret")
        return {"ok": False}

    update = await request.json()
    try:
        if "message" in update:
            await _handle_text(update["message"])
        elif "callback_query" in update:
            await _handle_callback(update["callback_query"])
    except Exception as exc:
        logger.exception("Telegram support webhook handling failed: %s", exc)
    return {"ok": True}
