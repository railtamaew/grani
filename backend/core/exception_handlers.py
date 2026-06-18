"""
Централизованная обработка ошибок для FastAPI приложения.
"""
import logging
import traceback
from typing import Union
from datetime import datetime
from fastapi import Request, status
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError, HTTPException
from sqlalchemy.exc import SQLAlchemyError
from pydantic import ValidationError

from core.error_types import ErrorCode, AppError, ErrorDetail, AppException

logger = logging.getLogger(__name__)


async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    """
    Обработчик для HTTPException.
    Возвращает стандартизированный формат ошибок.
    """
    logger.warning(
        f"HTTPException: {exc.status_code} - {exc.detail} - Path: {request.url.path}"
    )
    
    # Специальная обработка для rate limiting (429)
    if exc.status_code == status.HTTP_429_TOO_MANY_REQUESTS:
        # Если detail уже в формате словаря с error, возвращаем как есть
        if isinstance(exc.detail, dict) and "error" in exc.detail:
            return JSONResponse(
                status_code=exc.status_code,
                content=exc.detail
            )
        # Иначе форматируем стандартно
        error = AppError(
            code=ErrorCode.RATE_LIMIT_EXCEEDED,
            message=str(exc.detail) if isinstance(exc.detail, str) else "Превышен лимит запросов",
            path=request.url.path,
            method=request.method,
            timestamp=datetime.now().isoformat()
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": error.to_dict()}
        )
    
    # Маппинг статус кодов на ErrorCode
    status_to_code = {
        400: ErrorCode.HTTP_BAD_REQUEST,
        401: ErrorCode.HTTP_UNAUTHORIZED,
        403: ErrorCode.HTTP_FORBIDDEN,
        404: ErrorCode.HTTP_NOT_FOUND,
        409: ErrorCode.HTTP_CONFLICT,
        422: ErrorCode.HTTP_UNPROCESSABLE_ENTITY,
        500: ErrorCode.HTTP_INTERNAL_SERVER_ERROR,
    }
    
    error_code = status_to_code.get(exc.status_code, ErrorCode.INTERNAL_ERROR)
    
    error = AppError(
        code=error_code,
        message=str(exc.detail) if isinstance(exc.detail, str) else str(exc.detail),
        path=request.url.path,
        method=request.method,
        timestamp=datetime.now().isoformat()
    )
    
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": error.to_dict()}
    )


async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    """
    Обработчик для ошибок валидации Pydantic.
    """
    error_details = []
    for error in exc.errors():
        error_details.append(ErrorDetail(
            field=".".join(str(loc) for loc in error["loc"]),
            message=error["msg"],
            type=error["type"],
            value=error.get("input")
        ))
    
    logger.warning(
        f"ValidationError: {len(error_details)} errors - Path: {request.url.path}"
    )
    
    error = AppError(
        code=ErrorCode.VALIDATION_ERROR,
        message="Ошибка валидации данных",
        details=error_details,
        path=request.url.path,
        method=request.method,
        timestamp=datetime.now().isoformat()
    )
    
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={"error": error.to_dict()}
    )


async def database_exception_handler(request: Request, exc: SQLAlchemyError) -> JSONResponse:
    """
    Обработчик для ошибок базы данных.
    """
    error_message = str(exc)
    logger.error(
        f"DatabaseError: {error_message} - Path: {request.url.path}",
        exc_info=True
    )
    
    # В продакшене не показываем детали ошибки БД
    from core.config import settings
    detail_message = "Ошибка базы данных" if settings.is_production else error_message
    
    error = AppError(
        code=ErrorCode.DATABASE_ERROR,
        message=detail_message,
        path=request.url.path,
        method=request.method,
        timestamp=datetime.now().isoformat()
    )
    
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"error": error.to_dict()}
    )


async def general_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """
    Обработчик для всех необработанных исключений.
    """
    # Если это AppException, используем его структуру
    if isinstance(exc, AppException):
        error = exc.to_app_error(path=request.url.path, method=request.method)
        logger.error(
            f"AppException: {error.code.value} - {error.message} - Path: {request.url.path}",
            exc_info=True
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": error.to_dict()}
        )
    
    # Для остальных исключений
    error_trace = traceback.format_exc()
    error_message = str(exc) if str(exc) else "Неизвестная ошибка"
    
    logger.error(
        f"UnhandledException: {error_message} - Path: {request.url.path} - Method: {request.method}",
        exc_info=True
    )
    
    # В продакшене не показываем детали ошибки
    from core.config import settings
    detail_message = "Внутренняя ошибка сервера" if settings.is_production else error_message
    
    error = AppError(
        code=ErrorCode.INTERNAL_ERROR,
        message=detail_message,
        path=request.url.path,
        method=request.method,
        timestamp=datetime.now().isoformat()
    )
    
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"error": error.to_dict()}
    )


def register_exception_handlers(app):
    """
    Регистрирует все exception handlers в FastAPI приложении.
    
    Args:
        app: FastAPI приложение
    """
    # HTTPException должен быть первым, так как он более специфичен
    app.add_exception_handler(HTTPException, http_exception_handler)
    
    # RequestValidationError для валидации Pydantic
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    
    # SQLAlchemyError для ошибок БД
    app.add_exception_handler(SQLAlchemyError, database_exception_handler)
    
    # Общий обработчик для всех остальных исключений
    app.add_exception_handler(Exception, general_exception_handler)
    
    logger.info("Exception handlers registered successfully")
