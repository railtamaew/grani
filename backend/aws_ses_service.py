"""
AWS SES / Yandex Cloud Postbox email service для отправки писем через API
Используется вместо SMTP когда SMTP порты заблокированы провайдером

Поддерживает:
- AWS SES (endpoint по умолчанию)
- Yandex Cloud Postbox (совместим с AWS SES API, endpoint: https://postbox.cloud.yandex.net)
"""
from typing import Optional
import logging
from core.config import settings

logger = logging.getLogger(__name__)

# Ленивый импорт boto3 для избежания проблем с OpenSSL
def _get_boto3():
    """Ленивый импорт boto3"""
    try:
        import boto3
        from botocore.exceptions import ClientError, BotoCoreError
        return boto3, ClientError, BotoCoreError
    except Exception as e:
        logger.error(f"[aws_ses_service] Ошибка импорта boto3: {e}", exc_info=True)
        raise


def send_verification_email_ses(
    to_email: str,
    verification_code: str,
    language: str = "en",
    from_email: Optional[str] = None,
    from_name: Optional[str] = None
) -> bool:
    """
    Отправка письма с кодом подтверждения через AWS SES
    
    Args:
        to_email: Email получателя
        verification_code: Код подтверждения
        from_email: Email отправителя (по умолчанию из settings)
        from_name: Имя отправителя (по умолчанию из settings)
    
    Returns:
        True если письмо отправлено успешно, False в противном случае
    """
    logger.info(f"[aws_ses_service] Начало отправки через SES/Postbox на {to_email}")
    logger.debug(f"[aws_ses_service] Параметры: verification_code={verification_code}, from_email={from_email}, from_name={from_name}")
    
    from_email = from_email or settings.aws_ses_from_email
    from_name = from_name or settings.aws_ses_from_name
    
    logger.info(f"[aws_ses_service] Используемый from_email: {from_email}, from_name: {from_name}")
    
    # Проверяем наличие настроек AWS
    if not hasattr(settings, 'aws_access_key_id') or not settings.aws_access_key_id:
        logger.error("[aws_ses_service] AWS_ACCESS_KEY_ID не настроен. Проверьте настройки в .env файле.")
        return False
    
    if not hasattr(settings, 'aws_secret_access_key') or not settings.aws_secret_access_key:
        logger.error("[aws_ses_service] AWS_SECRET_ACCESS_KEY не настроен. Проверьте настройки в .env файле.")
        return False
    
    if not from_email:
        logger.error("[aws_ses_service] AWS_SES_FROM_EMAIL не настроен.")
        return False
    
    logger.debug(f"[aws_ses_service] Настройки AWS проверены успешно. aws_region={getattr(settings, 'aws_region', 'not set')}")
    logger.debug(f"[aws_ses_service] aws_ses_endpoint={getattr(settings, 'aws_ses_endpoint', 'not set')}")
    
    # Определяем, используем ли Yandex Postbox (до создания клиента)
    region = settings.aws_region or 'us-east-1'
    endpoint = settings.aws_ses_endpoint.rstrip('/') if hasattr(settings, 'aws_ses_endpoint') and settings.aws_ses_endpoint else None
    is_yandex_postbox = endpoint and 'postbox.cloud.yandex.net' in endpoint
    
    # Импортируем функции создания email из email_service
    from services.email_service import (
        create_verification_email_text,
        create_verification_email_html
    )
    
    # Создаем клиент SES / Yandex Cloud Postbox (timeout 15s connect, 30s read — избегаем зависаний)
    try:
        # Ленивый импорт boto3
        boto3, ClientError, BotoCoreError = _get_boto3()
        from botocore.config import Config
        boto_config = Config(connect_timeout=15, read_timeout=30, retries={"mode": "standard", "max_attempts": 2})

        if is_yandex_postbox:
            logger.info(f"[aws_ses_service] Использование Yandex Cloud Postbox с sesv2 client")
            logger.info(f"[aws_ses_service] Endpoint: {endpoint}")
            logger.info(f"[aws_ses_service] Region: {region}")
            
            ses_client = boto3.client(
                'sesv2',
                region_name=region,
                endpoint_url=endpoint,
                aws_access_key_id=settings.aws_access_key_id,
                aws_secret_access_key=settings.aws_secret_access_key,
                config=boto_config
            )
            logger.info(f"[aws_ses_service] sesv2 клиент успешно создан")
        else:
            # Для AWS SES используем стандартный ses client
            logger.info(f"[aws_ses_service] Использование стандартного AWS SES endpoint")
            ses_client = boto3.client(
                'ses',
                region_name=region,
                aws_access_key_id=settings.aws_access_key_id,
                aws_secret_access_key=settings.aws_secret_access_key,
                config=boto_config
            )
            logger.info(f"[aws_ses_service] SES клиент успешно создан")
    except Exception as e:
        logger.error(f"[aws_ses_service] Ошибка создания SES/Postbox клиента: {e}", exc_info=True)
        return False
    
    # Создаем содержимое письма (код в теме для удобства в почте)
    is_ru = (language or "").strip().lower() == "ru"
    subject = (
        f'Код подтверждения GRANI - {verification_code}'
        if is_ru
        else f'GRANI verification code - {verification_code}'
    )
    logger.debug(f"[aws_ses_service] Создание содержимого письма: subject={subject}")
    
    try:
        text_body = create_verification_email_text(
            verification_code, to_email, language=language
        )
        html_body = create_verification_email_html(
            verification_code, to_email, language=language
        )
        logger.debug(f"[aws_ses_service] Содержимое письма создано. text_body length={len(text_body)}, html_body length={len(html_body)}")
    except Exception as e:
        logger.error(f"[aws_ses_service] Ошибка создания содержимого письма: {e}", exc_info=True)
        return False
    
    try:
        service_name = "Yandex Cloud Postbox" if is_yandex_postbox else "AWS SES"
        logger.info(f"[aws_ses_service] Отправка email через {service_name} на {to_email}")
        logger.info(f"[aws_ses_service] Отправитель: {from_email}")
        
        # Для Yandex Cloud Postbox используем sesv2 формат
        if is_yandex_postbox:
            # Формируем адрес отправителя с именем: "Имя" <email>
            sender_with_name = f'"{from_name}" <{from_email}>' if from_name else from_email
            logger.debug(f"[aws_ses_service] Вызов sesv2_client.send_email с форматом sesv2...")
            logger.debug(f"[aws_ses_service] Отправитель с именем: {sender_with_name}")
            response = ses_client.send_email(
                FromEmailAddress=sender_with_name,
                Destination={'ToAddresses': [to_email]},
                Content={
                    'Simple': {
                        'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                        'Body': {
                            'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                            'Html': {'Data': html_body, 'Charset': 'UTF-8'}
                        }
                    }
                }
            )
        else:
            # Для AWS SES используем стандартный формат
            logger.debug(f"[aws_ses_service] Вызов ses_client.send_email с стандартным форматом...")
            response = ses_client.send_email(
                Source=from_email,
                Destination={
                    'ToAddresses': [to_email]
                },
                Message={
                    'Subject': {
                        'Data': subject,
                        'Charset': 'UTF-8'
                    },
                    'Body': {
                        'Text': {
                            'Data': text_body,
                            'Charset': 'UTF-8'
                        },
                        'Html': {
                            'Data': html_body,
                            'Charset': 'UTF-8'
                        }
                    }
                }
            )
        
        message_id = response.get('MessageId', 'unknown')
        logger.info(f"[aws_ses_service] Email успешно отправлен через {service_name} на {to_email}. MessageId: {message_id}")
        logger.debug(f"[aws_ses_service] Полный ответ от API: {response}")
        return True
        
    except ClientError as e:
        # Это ClientError от AWS/Yandex
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        error_message = e.response.get('Error', {}).get('Message', str(e))
        service_name = "Yandex Cloud Postbox" if is_yandex_postbox else "AWS SES"
        
        logger.error(f"[aws_ses_service] Ошибка {service_name} при отправке на {to_email}: {error_code} - {error_message}")
        logger.error(f"[aws_ses_service] Полный ответ об ошибке: {e.response}")
        
        # Специальная обработка ошибок
        if error_code == 'MessageRejected':
            logger.error("[aws_ses_service] Письмо отклонено. Возможные причины:")
            logger.error("[aws_ses_service]   - Домен не верифицирован")
            logger.error("[aws_ses_service]   - Email адрес не верифицирован (в Sandbox режиме)")
            logger.error("[aws_ses_service]   - Превышен лимит отправки")
        elif error_code == 'MailFromDomainNotVerified':
            logger.error("[aws_ses_service] Домен отправителя не верифицирован в AWS SES")
        elif error_code == 'AccountSendingPausedException':
            logger.error("[aws_ses_service] Отправка приостановлена для аккаунта AWS")
        
        return False
        
    except Exception as e:
        # Любая другая ошибка - это НЕ успех
        error_str = str(e)
        service_name = "Yandex Cloud Postbox" if is_yandex_postbox else "AWS SES"
        
        # Если это ResponseParserError с текстовым ответом - это ОШИБКА, не успех!
        if 'ResponseParserError' in error_str or 'Unable to parse response' in error_str:
            logger.error(f"[aws_ses_service] {service_name} вернул текстовый ответ вместо XML - это ОШИБКА!")
            logger.error(f"[aws_ses_service] Текстовый ответ означает, что письмо НЕ отправлено")
            logger.error(f"[aws_ses_service] Ошибка: {e}", exc_info=True)
            return False
        
        logger.error(f"[aws_ses_service] Неожиданная ошибка при отправке через {service_name} на {to_email}: {e}", exc_info=True)
        return False


def send_raw_email_ses(
    to_email: str,
    subject: str,
    text_body: str,
    html_body: str,
    from_email: Optional[str] = None,
    from_name: Optional[str] = None
) -> bool:
    """
    Отправка произвольного письма через AWS SES / Yandex Postbox.
    """
    from_email = from_email or settings.aws_ses_from_email
    from_name = from_name or settings.aws_ses_from_name

    if not hasattr(settings, 'aws_access_key_id') or not settings.aws_access_key_id:
        logger.error("[aws_ses_service] AWS_ACCESS_KEY_ID не настроен.")
        return False
    if not hasattr(settings, 'aws_secret_access_key') or not settings.aws_secret_access_key:
        logger.error("[aws_ses_service] AWS_SECRET_ACCESS_KEY не настроен.")
        return False
    if not from_email:
        logger.error("[aws_ses_service] AWS_SES_FROM_EMAIL не настроен.")
        return False

    region = settings.aws_region or 'us-east-1'
    endpoint = settings.aws_ses_endpoint.rstrip('/') if hasattr(settings, 'aws_ses_endpoint') and settings.aws_ses_endpoint else None
    is_yandex_postbox = endpoint and 'postbox.cloud.yandex.net' in endpoint

    try:
        boto3, ClientError, BotoCoreError = _get_boto3()
        from botocore.config import Config
        boto_config = Config(connect_timeout=15, read_timeout=30, retries={"mode": "standard", "max_attempts": 2})

        if is_yandex_postbox:
            ses_client = boto3.client(
                'sesv2', region_name=region, endpoint_url=endpoint,
                aws_access_key_id=settings.aws_access_key_id,
                aws_secret_access_key=settings.aws_secret_access_key,
                config=boto_config
            )
        else:
            ses_client = boto3.client(
                'ses', region_name=region,
                aws_access_key_id=settings.aws_access_key_id,
                aws_secret_access_key=settings.aws_secret_access_key,
                config=boto_config
            )
    except Exception as e:
        logger.error(f"[aws_ses_service] Ошибка создания SES клиента: {e}", exc_info=True)
        return False

    service_name = "Yandex Cloud Postbox" if is_yandex_postbox else "AWS SES"
    try:
        if is_yandex_postbox:
            sender = f'"{from_name}" <{from_email}>' if from_name else from_email
            response = ses_client.send_email(
                FromEmailAddress=sender,
                Destination={'ToAddresses': [to_email]},
                Content={
                    'Simple': {
                        'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                        'Body': {
                            'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                            'Html': {'Data': html_body, 'Charset': 'UTF-8'}
                        }
                    }
                }
            )
        else:
            response = ses_client.send_email(
                Source=from_email,
                Destination={'ToAddresses': [to_email]},
                Message={
                    'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                    'Body': {
                        'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                        'Html': {'Data': html_body, 'Charset': 'UTF-8'}
                    }
                }
            )
        logger.info(f"[aws_ses_service] Email '{subject}' отправлен на {to_email}. MessageId: {response.get('MessageId', 'unknown')}")
        return True
    except ClientError as e:
        logger.error(f"[aws_ses_service] Ошибка {service_name}: {e.response.get('Error', {})}")
        return False
    except Exception as e:
        logger.error(f"[aws_ses_service] Ошибка отправки на {to_email}: {e}", exc_info=True)
        return False

