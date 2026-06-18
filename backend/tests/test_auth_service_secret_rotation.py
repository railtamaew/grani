"""
Тесты для ротации SECRET_KEY в AuthService.
Проверяют graceful migration без logout пользователей.
"""
import pytest
import jwt
from datetime import datetime, timedelta
from unittest.mock import patch, MagicMock

from services.auth_service import AuthService
from core.config import settings


class TestJWTSecretRotation:
    """Тесты для ротации SECRET_KEY в JWT токенах"""
    
    def test_verify_token_with_new_key(self):
        """Тест: проверка токена с новым ключом"""
        user_id = 1
        # Создаем токен с текущим ключом
        token = AuthService.create_access_token(user_id)
        
        # Проверяем токен
        verified_id = AuthService.verify_token(token, token_type="access")
        assert verified_id == user_id
    
    def test_verify_token_with_old_key(self, monkeypatch):
        """Тест: проверка токена со старым ключом (ротация)"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем токен со старым ключом (симулируем старый токен)
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        old_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем secret_key и secret_key_old (jwt_secret_keys обновится автоматически)
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Токен должен проверяться со старым ключом
        verified_id = AuthService.verify_token(old_token, token_type="access")
        assert verified_id == user_id
    
    def test_create_token_with_new_key(self, monkeypatch):
        """Тест: новые токены создаются с новым ключом"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Мокируем settings для ротации
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Создаем новый токен
        new_token = AuthService.create_access_token(user_id)
        
        # Новый токен должен проверяться только новым ключом
        # (старый ключ не должен его проверить)
        try:
            payload = jwt.decode(new_token, old_key, algorithms=[settings.algorithm])
            pytest.fail("Новый токен не должен проверяться старым ключом")
        except jwt.InvalidTokenError:
            pass  # Ожидаемое поведение
        
        # Новый токен должен проверяться новым ключом
        verified_id = AuthService.verify_token(new_token, token_type="access")
        assert verified_id == user_id
    
    def test_verify_token_tries_both_keys(self, monkeypatch):
        """Тест: verify_token пробует оба ключа"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем токен со старым ключом
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        old_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем settings
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # verify_token должен попробовать новый ключ (не сработает),
        # затем старый ключ (сработает)
        verified_id = AuthService.verify_token(old_token, token_type="access")
        assert verified_id == user_id
    
    def test_verify_token_fails_with_wrong_keys(self, monkeypatch):
        """Тест: verify_token возвращает None если ни один ключ не подходит"""
        user_id = 1
        wrong_key = "wrong_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        old_key = "old_secret_key_123456789012345678901234567890"
        
        # Создаем токен с неправильным ключом
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        wrong_token = jwt.encode(to_encode, wrong_key, algorithm=settings.algorithm)
        
        # Мокируем settings
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Токен не должен проверяться
        verified_id = AuthService.verify_token(wrong_token, token_type="access")
        assert verified_id is None
    
    def test_verify_token_expired_does_not_try_other_keys(self, monkeypatch):
        """Тест: истекший токен не проверяется другими ключами"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем истекший токен со старым ключом
        expire = datetime.utcnow() - timedelta(minutes=1)  # Истек минуту назад
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        expired_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем settings
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Истекший токен не должен проверяться
        verified_id = AuthService.verify_token(expired_token, token_type="access")
        assert verified_id is None
    
    def test_refresh_token_with_rotation(self, monkeypatch):
        """Тест: refresh token работает с ротацией ключей"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем refresh token со старым ключом
        expire = datetime.utcnow() + timedelta(days=settings.refresh_token_expire_days)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "refresh"}
        old_refresh_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем settings
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # refresh_access_token должен работать со старым refresh token
        new_access_token = AuthService.refresh_access_token(old_refresh_token)
        assert new_access_token is not None
        
        # Новый access token должен быть создан с новым ключом
        verified_id = AuthService.verify_token(new_access_token, token_type="access")
        assert verified_id == user_id
    
    def test_token_type_check_with_rotation(self, monkeypatch):
        """Тест: проверка типа токена работает с ротацией"""
        user_id = 1
        old_key = "old_secret_key_123456789012345678901234567890"
        new_key = "new_secret_key_123456789012345678901234567890"
        
        # Создаем refresh token со старым ключом
        expire = datetime.utcnow() + timedelta(days=settings.refresh_token_expire_days)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "refresh"}
        old_refresh_token = jwt.encode(to_encode, old_key, algorithm=settings.algorithm)
        
        # Мокируем settings
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        # Refresh token не должен проходить проверку как access token
        verified_id = AuthService.verify_token(old_refresh_token, token_type="access")
        assert verified_id is None
        
        # Но должен проходить как refresh token
        verified_id = AuthService.verify_token(old_refresh_token, token_type="refresh")
        assert verified_id == user_id


class TestJWTSecretRotationEdgeCases:
    """Тесты для граничных случаев ротации SECRET_KEY"""
    
    def test_empty_secret_keys_list(self, monkeypatch):
        """Тест: пустой список ключей (не должно происходить, но на всякий случай)"""
        user_id = 1
        token = AuthService.create_access_token(user_id)
        
        monkeypatch.setattr(settings, 'secret_key', "")
        monkeypatch.setattr(settings, 'secret_key_old', None)
        
        # Должно вернуть None, так как нет ключей для проверки
        verified_id = AuthService.verify_token(token, token_type="access")
        assert verified_id is None
    
    def test_multiple_old_keys(self, monkeypatch):
        """Тест: поддержка нескольких старых ключей (если нужно)"""
        user_id = 1
        key1 = "key1_123456789012345678901234567890"
        key2 = "key2_123456789012345678901234567890"
        key3 = "key3_123456789012345678901234567890"
        
        # Создаем токен с key2
        expire = datetime.utcnow() + timedelta(minutes=settings.access_token_expire_minutes)
        to_encode = {"exp": expire, "sub": str(user_id), "type": "access"}
        token = jwt.encode(to_encode, key2, algorithm=settings.algorithm)
        
        # Мокируем settings: key1 - новый, key2 и key3 - старые
        # (в реальности поддерживается только один старый ключ, но логика проверяет все)
        monkeypatch.setattr(settings, 'secret_key', key1)
        monkeypatch.setattr(settings, 'secret_key_old', key2)
        # Для теста множественных ключей мокируем getattr для jwt_secret_keys
        def mock_jwt_secret_keys(self):
            return [key1, key2, key3]
        monkeypatch.setattr(type(settings), 'jwt_secret_keys', property(mock_jwt_secret_keys))
        
        # Токен должен проверяться key2
        verified_id = AuthService.verify_token(token, token_type="access")
        assert verified_id == user_id
    
    def test_verify_token_with_invalid_format(self, monkeypatch):
        """Тест: невалидный формат токена не проверяется"""
        invalid_token = "not.a.valid.jwt.token"
        new_key = "new_secret_key_123456789012345678901234567890"
        old_key = "old_secret_key_123456789012345678901234567890"
        
        monkeypatch.setattr(settings, 'secret_key', new_key)
        monkeypatch.setattr(settings, 'secret_key_old', old_key)
        
        verified_id = AuthService.verify_token(invalid_token, token_type="access")
        assert verified_id is None
