"""
Базовый репозиторий для общих операций с БД.
"""
from typing import Generic, TypeVar, Type, Optional, List, Dict, Any
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_

ModelType = TypeVar("ModelType")


class BaseRepository(Generic[ModelType]):
    """Базовый репозиторий с общими методами CRUD"""
    
    def __init__(self, db: Session, model: Type[ModelType]):
        self.db = db
        self.model = model
    
    def get(self, id: int) -> Optional[ModelType]:
        """Получить объект по ID"""
        return self.db.query(self.model).filter(self.model.id == id).first()
    
    def get_all(self, skip: int = 0, limit: int = 100) -> List[ModelType]:
        """Получить все объекты с пагинацией"""
        return self.db.query(self.model).offset(skip).limit(limit).all()
    
    def create(self, **kwargs) -> ModelType:
        """Создать новый объект"""
        instance = self.model(**kwargs)
        self.db.add(instance)
        self.db.commit()
        self.db.refresh(instance)
        return instance
    
    def update(self, id: int, **kwargs) -> Optional[ModelType]:
        """Обновить объект"""
        instance = self.get(id)
        if instance:
            for key, value in kwargs.items():
                setattr(instance, key, value)
            self.db.commit()
            self.db.refresh(instance)
        return instance
    
    def delete(self, id: int) -> bool:
        """Удалить объект"""
        instance = self.get(id)
        if instance:
            self.db.delete(instance)
            self.db.commit()
            return True
        return False
    
    def count(self) -> int:
        """Подсчитать количество объектов"""
        return self.db.query(self.model).count()
    
    def filter_by(self, **kwargs) -> List[ModelType]:
        """Фильтровать по параметрам"""
        return self.db.query(self.model).filter_by(**kwargs).all()
    
    def first_by(self, **kwargs) -> Optional[ModelType]:
        """Найти первый объект по параметрам"""
        return self.db.query(self.model).filter_by(**kwargs).first()
