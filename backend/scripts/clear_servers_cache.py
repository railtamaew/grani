#!/usr/bin/env python3
"""Очищает кэш серверов"""
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from core.cache import cache_delete, cache_clear

# Очищаем кэш серверов
cache_delete("cache:servers:list")
print("✅ Кэш серверов очищен")

# Можно также очистить весь кэш
# cache_clear()
# print("✅ Весь кэш очищен")


