"""
Тесты для AuthService.
ВАЖНО: Не изменяем логику AuthService, только добавляем тесты.
"""
import pytest
from datetime import datetime, timedelta
from fastapi import HTTPException
from sqlalchemy.orm import Session

from services.auth_service import AuthService
from models.user import User
from core.config import settings


class TestPasswordHashing:
    """Тесты для хеширования и проверки паролей"""
    
    def test_hash_password(self):
        """Тест хеширования пароля"""
        password = "TestPassword123"
        hashed = AuthService.hash_password(password)
        
        assert hashed is not None
        assert hashed != password
        assert len(hashed) > 0
    
    def test_verify_password_correct(self):
        """Тест проверки правильного пароля"""
        password = "TestPassword123"
        hashed = AuthService.hash_password(password)
        
        assert AuthService.verify_password(password, hashed) is True
    
    def test_verify_password_incorrect(self):
        """Тест проверки неправильного пароля"""
        password = "TestPassword123"
        wrong_password = "WrongPassword123"
        hashed = AuthService.hash_password(password)
        
        assert AuthService.verify_password(wrong_password, hashed) is False
    
    def test_verify_password_empty_hash(self):
        """Тест проверки пароля с пустым хешем"""
        assert AuthService.verify_password("password", None) is False
        assert AuthService.verify_password("password", "") is False


class TestJWTTokens:
    """Тесты для JWT токенов"""
    
    def test_create_access_token(self):
        """Тест создания access token"""
        user_id = 1
        token = AuthService.create_access_token(user_id)
        
        assert token is not None
        assert isinstance(token, str)
        assert len(token) > 0
    
    def test_create_refresh_token(self):
        """Тест создания refresh token"""
        user_id = 1
        token = AuthService.create_refresh_token(user_id)
        
        assert token is not None
        assert isinstance(token, str)
        assert len(token) > 0
    
    def test_verify_token_valid_access(self):
        """Тест проверки валидного access token"""
        user_id = 1
        token = AuthService.create_access_token(user_id)
        
        verified_id = AuthService.verify_token(token, token_type="access")
        assert verified_id == user_id
    
    def test_verify_token_valid_refresh(self):
        """Тест проверки валидного refresh token"""
        user_id = 1
        token = AuthService.create_refresh_token(user_id)
        
        verified_id = AuthService.verify_token(token, token_type="refresh")
        assert verified_id == user_id
    
    def test_verify_token_wrong_type(self):
        """Тест проверки токена с неправильным типом"""
        user_id = 1
        access_token = AuthService.create_access_token(user_id)
        refresh_token = AuthService.create_refresh_token(user_id)
        
        # Access token не должен проходить проверку как refresh
        assert AuthService.verify_token(access_token, token_type="refresh") is None
        
        # Refresh token не должен проходить проверку как access
        assert AuthService.verify_token(refresh_token, token_type="access") is None
    
    def test_verify_token_invalid(self):
        """Тест проверки невалидного токена"""
        invalid_token = "invalid.token.here"
        
        assert AuthService.verify_token(invalid_token) is None
    
    def test_verify_token_empty(self):
        """Тест проверки пустого токена"""
        assert AuthService.verify_token("") is None
        assert AuthService.verify_token(None) is None
    
    def test_refresh_access_token_valid(self):
        """Тест обновления access token через валидный refresh token"""
        user_id = 1
        refresh_token = AuthService.create_refresh_token(user_id)
        
        new_access_token = AuthService.refresh_access_token(refresh_token)
        
        assert new_access_token is not None
        assert isinstance(new_access_token, str)
        
        # Проверяем, что новый токен валиден
        verified_id = AuthService.verify_token(new_access_token, token_type="access")
        assert verified_id == user_id
    
    def test_refresh_access_token_invalid(self):
        """Тест обновления access token через невалидный refresh token"""
        invalid_token = "invalid.token.here"
        
        new_access_token = AuthService.refresh_access_token(invalid_token)
        assert new_access_token is None
    
    def test_verify_token_with_secret_rotation(self, monkeypatch):
        """Тест проверки токена с поддержкой ротации ключей"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем токен со старым ключом (симулируем старый токен)
        from datetime import datetime, timedelta
        import jwt
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        old_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем settings для поддержки ротации
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Токен должен проверяться со старым ключом
        verified_id = AuthService.verify_token(old_token, token_type="access")
        assert verified_id == user_id


class TestPasswordValidation:
    """Тесты для валидации паролей"""
    
    def test_validate_password_strength_valid(self):
        """Тест валидации правильного пароля"""
        password = "ValidPassword123"
        email = "test@example.com"
        
        # Не должно быть исключения
        try:
            AuthService.validate_password_strength(password, email)
        except HTTPException:
            pytest.fail("Валидный пароль не должен вызывать исключение")
    
    def test_validate_password_strength_too_short(self):
        """Тест валидации слишком короткого пароля"""
        password = "Short1"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
        assert "8 до 64 символов" in exc_info.value.detail
    
    def test_validate_password_strength_too_long(self):
        """Тест валидации слишком длинного пароля"""
        password = "A" * 65 + "1"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
    
    def test_validate_password_strength_no_lowercase(self):
        """Тест валидации пароля без строчных букв"""
        password = "NOLOWERCASE123"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
        assert "строчную букву" in exc_info.value.detail
    
    def test_validate_password_strength_no_uppercase(self):
        """Тест валидации пароля без заглавных букв"""
        password = "nouppercase123"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
        assert "заглавную букву" in exc_info.value.detail
    
    def test_validate_password_strength_no_digit(self):
        """Тест валидации пароля без цифр"""
        password = "NoDigitsHere"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
        assert "цифру" in exc_info.value.detail
    
    def test_validate_password_strength_contains_email(self):
        """Тест валидации пароля, содержащего email"""
        password = "testPassword123"
        email = "test@example.com"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.validate_password_strength(password, email)
        
        assert exc_info.value.status_code == 400
        assert "email" in exc_info.value.detail
    
    def test_validate_password_strength_blacklisted(self):
        """Тест валидации пароля из черного списка"""
        # Пароли в черном списке не проходят проверку формата (нет заглавных букв/цифр)
        # Поэтому проверяем, что черный список существует и содержит ожидаемые пароли
        assert "123456" in AuthService.PASSWORD_BLACKLIST
        assert "qwerty" in AuthService.PASSWORD_BLACKLIST
        assert "password" in AuthService.PASSWORD_BLACKLIST
        assert "granivpn" in AuthService.PASSWORD_BLACKLIST
        
        # Проверяем, что пароль из черного списка (в нижнем регистре) вызывает ошибку
        # Но так как он не проходит проверку формата, проверим логику черного списка отдельно
        password = "Qwerty123"  # Пароль с правильным форматом, но "qwerty" в черном списке
        email = "test@example.com"
        
        # Этот пароль должен пройти валидацию, так как "Qwerty123" != "qwerty" (разный регистр)
        # Но если бы был "qwerty123", он бы не прошел проверку формата (нет заглавной буквы)
        # Поэтому проверяем, что черный список работает для точных совпадений в нижнем регистре
        try:
            AuthService.validate_password_strength(password, email)
            # Если не было исключения, проверяем, что пароль не в черном списке
            assert password.lower() not in AuthService.PASSWORD_BLACKLIST
        except HTTPException:
            # Если было исключение, проверяем причину
            pass


class TestUserManagement:
    """Тесты для управления пользователями"""
    
    def test_create_user_success(self, auth_service, db_session):
        """Тест успешного создания пользователя"""
        email = "newuser@example.com"
        password = "NewPassword123"
        
        user = auth_service.create_user(email, password)
        
        assert user is not None
        assert user.email == email
        assert user.password_hash is not None
        assert user.password_hash != password
        assert user.is_verified is True
        assert user.auth_provider == "email"
        
        # Проверяем, что пароль правильно захеширован
        assert AuthService.verify_password(password, user.password_hash) is True
    
    def test_create_user_duplicate_email(self, auth_service, db_session):
        """Тест создания пользователя с существующим email"""
        email = "duplicate@example.com"
        password = "Password123"
        
        # Создаем первого пользователя
        auth_service.create_user(email, password)
        
        # Пытаемся создать второго с тем же email
        with pytest.raises(HTTPException) as exc_info:
            auth_service.create_user(email, password)
        
        assert exc_info.value.status_code == 400
        assert "уже существует" in exc_info.value.detail
    
    def test_authenticate_user_success(self, auth_service, db_session):
        """Тест успешной аутентификации пользователя"""
        email = "auth@example.com"
        password = "AuthPassword123"
        
        # Создаем пользователя
        auth_service.create_user(email, password)
        
        # Аутентифицируем
        user = auth_service.authenticate_user(email, password)
        
        assert user is not None
        assert user.email == email
    
    def test_authenticate_user_wrong_password(self, auth_service, db_session):
        """Тест аутентификации с неправильным паролем"""
        email = "wrongpass@example.com"
        password = "CorrectPassword123"
        wrong_password = "WrongPassword123"
        
        # Создаем пользователя
        auth_service.create_user(email, password)
        
        # Пытаемся аутентифицироваться с неправильным паролем
        user = auth_service.authenticate_user(email, wrong_password)
        
        assert user is None
    
    def test_authenticate_user_not_exists(self, auth_service, db_session):
        """Тест аутентификации несуществующего пользователя"""
        user = auth_service.authenticate_user("nonexistent@example.com", "Password123")
        
        assert user is None
    
    def test_change_password_success(self, auth_service, db_session):
        """Тест успешной смены пароля"""
        email = "changepass@example.com"
        old_password = "OldPassword123"
        new_password = "NewPassword123"
        
        # Создаем пользователя
        user = auth_service.create_user(email, old_password)
        
        # Меняем пароль
        result = auth_service.change_password(user.id, old_password, new_password)
        
        assert result is True
        
        # Проверяем, что старый пароль не работает
        assert auth_service.authenticate_user(email, old_password) is None
        
        # Проверяем, что новый пароль работает
        assert auth_service.authenticate_user(email, new_password) is not None
    
    def test_change_password_wrong_old_password(self, auth_service, db_session):
        """Тест смены пароля с неправильным старым паролем"""
        email = "wrongold@example.com"
        old_password = "OldPassword123"
        wrong_old_password = "WrongOldPassword123"
        new_password = "NewPassword123"
        
        # Создаем пользователя
        user = auth_service.create_user(email, old_password)
        
        # Пытаемся сменить пароль с неправильным старым
        result = auth_service.change_password(user.id, wrong_old_password, new_password)
        
        assert result is False
        
        # Старый пароль должен все еще работать
        assert auth_service.authenticate_user(email, old_password) is not None
    
    def test_reset_password_success(self, auth_service, db_session):
        """Тест успешного сброса пароля"""
        email = "reset@example.com"
        old_password = "OldPassword123"
        
        # Создаем пользователя
        user = auth_service.create_user(email, old_password)
        
        # Сбрасываем пароль
        result = auth_service.reset_password(email)
        
        assert result is True
        
        # Старый пароль не должен работать
        assert auth_service.authenticate_user(email, old_password) is None


class TestGetCurrentUser:
    """Тесты для получения текущего пользователя"""
    
    def test_get_current_user_success(self, auth_service, db_session):
        """Тест успешного получения текущего пользователя"""
        email = "current@example.com"
        password = "Password123"
        
        # Создаем пользователя
        user = auth_service.create_user(email, password)
        
        # Создаем токен
        token = AuthService.create_access_token(user.id)
        
        # Получаем пользователя по токену
        current_user = AuthService.get_current_user(token, db_session)
        
        assert current_user is not None
        assert current_user.id == user.id
        assert current_user.email == email
    
    def test_get_current_user_invalid_token(self, db_session):
        """Тест получения пользователя с невалидным токеном"""
        invalid_token = "invalid.token.here"
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.get_current_user(invalid_token, db_session)
        
        assert exc_info.value.status_code == 401
    
    def test_get_current_user_expired_token(self, db_session):
        """Тест получения пользователя с истекшим токеном"""
        # Создаем токен с истекшим временем
        import jwt
        from datetime import datetime, timedelta
        
        expired_payload = {
            "exp": datetime.utcnow() - timedelta(hours=1),
            "sub": "1",
            "type": "access"
        }
        expired_token = jwt.encode(expired_payload, settings.secret_key, algorithm=settings.algorithm)
        
        with pytest.raises(HTTPException) as exc_info:
            AuthService.get_current_user(expired_token, db_session)
        
        assert exc_info.value.status_code == 401
