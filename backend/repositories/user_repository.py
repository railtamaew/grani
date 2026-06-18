"""
Репозиторий для работы с пользователями.
"""
from typing import Optional, List
from sqlalchemy.orm import Session

from domain.models.user import User
from infrastructure.repositories.base_repository import BaseRepository


class UserRepository(BaseRepository[User]):
    """Репозиторий для пользователей"""
    
    def __init__(self, db: Session):
        super().__init__(db, User)
    
    def get_by_email(self, email: str) -> Optional[User]:
        """Получить пользователя по email"""
        return self.db.query(User).filter(User.email == email).first()
    
    def get_by_auth_provider(self, auth_provider: str) -> List[User]:
        """Получить пользователей по провайдеру аутентификации"""
        return self.db.query(User).filter(User.auth_provider == auth_provider).all()
    
    def exists_by_email(self, email: str) -> bool:
        """Проверить существование пользователя по email"""
        return self.db.query(User).filter(User.email == email).first() is not None
