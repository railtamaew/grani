"""
Сервис отправки Push-уведомлений через Firebase Cloud Messaging (V1 API).
"""
import logging
import os
from typing import Optional, Dict

import firebase_admin
from firebase_admin import credentials, messaging

from core.config import settings

logger = logging.getLogger(__name__)

_firebase_app: Optional[firebase_admin.App] = None


def _get_firebase_app() -> Optional[firebase_admin.App]:
    global _firebase_app
    if _firebase_app is not None:
        return _firebase_app

    cred_path = settings.firebase_service_account_path
    if not cred_path or not os.path.exists(cred_path):
        logger.error("[firebase_push] Service account key не найден: %s", cred_path)
        return None

    try:
        cred = credentials.Certificate(cred_path)
        _firebase_app = firebase_admin.initialize_app(cred)
        logger.info("[firebase_push] Firebase Admin SDK инициализирован (project: %s)", cred.project_id)
        return _firebase_app
    except ValueError:
        _firebase_app = firebase_admin.get_app()
        return _firebase_app
    except Exception as e:
        logger.exception("[firebase_push] Ошибка инициализации Firebase: %s", e)
        return None


def send_push(
    token: str,
    title: str,
    body: str,
    data: Optional[Dict[str, str]] = None,
) -> bool:
    """
    Отправляет push-уведомление одному устройству.

    Args:
        token: FCM device token
        title: заголовок уведомления
        body: текст уведомления
        data: дополнительные данные (ключ-значение, строки)

    Returns:
        True если отправлено успешно
    """
    app = _get_firebase_app()
    if app is None:
        return False

    if not token:
        logger.warning("[firebase_push] Пустой FCM-токен, пропускаем")
        return False

    message = messaging.Message(
        notification=messaging.Notification(title=title, body=body),
        data=data or {},
        token=token,
        android=messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(
                channel_id="grani_notifications",
                icon="ic_notification_g",
            ),
        ),
    )

    try:
        msg_id = messaging.send(message, app=app)
        logger.info("[firebase_push] Push отправлен: token=%s..., msg_id=%s", token[:20], msg_id)
        return True
    except messaging.UnregisteredError:
        logger.warning("[firebase_push] Токен недействителен (unregistered): %s...", token[:20])
        return False
    except messaging.SenderIdMismatchError:
        logger.error("[firebase_push] SenderIdMismatch для токена: %s...", token[:20])
        return False
    except Exception as e:
        logger.exception("[firebase_push] Ошибка отправки push: %s", e)
        return False


def send_push_to_user(user, title: str, body: str, data: Optional[Dict[str, str]] = None) -> bool:
    """
    Отправляет push-уведомление пользователю (если у него есть push_token).
    """
    if not user or not getattr(user, "push_token", None):
        return False
    return send_push(token=user.push_token, title=title, body=body, data=data)
