#!/usr/bin/env python3
"""Скрипт для добавления полей новых протоколов в таблицу servers"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from sqlalchemy import create_engine, text
from core.config import settings

def add_new_protocols_columns():
    """Добавляет поля для новых протоколов (GRANIWG, REALITY, OpenVPN Cloak)"""
    engine = create_engine(settings.database_url)
    conn = engine.connect()
    trans = conn.begin()
    
    try:
        print("Добавление полей для новых протоколов VPN...")
        print("=" * 80)
        
        # Поля для GRANIWG (обфусцированный WireGuard)
        graniwg_columns = [
            ("graniwg_enabled", "BOOLEAN DEFAULT FALSE", "Включен ли GRANIWG"),
            ("graniwg_obfuscation_key", "VARCHAR", "Ключ обфускации для GRANIWG"),
            ("graniwg_obfuscation_type", "VARCHAR", "Тип обфускации (например, 'udp2raw')"),
        ]
        
        # Поля для XRay Reality
        reality_columns = [
            ("reality_enabled", "BOOLEAN DEFAULT FALSE", "Включен ли REALITY"),
            ("reality_short_id", "VARCHAR", "Short ID для REALITY"),
            ("reality_server_name", "VARCHAR", "Имя сервера для маскировки"),
            ("reality_dest", "VARCHAR", "Dest для REALITY"),
            ("reality_sni", "VARCHAR", "SNI для REALITY"),
            ("reality_private_key", "VARCHAR", "Приватный ключ для REALITY"),
            ("reality_public_key", "VARCHAR", "Публичный ключ для REALITY"),
        ]
        
        # Поля для OpenVPN over Cloak
        cloak_columns = [
            ("cloak_enabled", "BOOLEAN DEFAULT FALSE", "Включен ли Cloak"),
            ("cloak_uid", "VARCHAR", "UID для Cloak"),
            ("cloak_public_key", "VARCHAR", "Публичный ключ Cloak"),
            ("cloak_private_key", "VARCHAR", "Приватный ключ Cloak"),
            ("cloak_mask_site", "VARCHAR", "Сайт для маскировки"),
            ("cloak_admin_uid", "VARCHAR", "Admin UID для Cloak"),
            ("cloak_bypass_uid", "VARCHAR", "Bypass UID для Cloak"),
        ]
        
        # Поле для OpenVPN порта (если еще нет)
        openvpn_columns = [
            ("openvpn_config_path", "VARCHAR", "Путь к конфигурации OpenVPN"),
        ]
        
        all_columns = [
            ("GRANIWG", graniwg_columns),
            ("XRay Reality", reality_columns),
            ("OpenVPN over Cloak", cloak_columns),
            ("OpenVPN", openvpn_columns),
        ]
        
        added_count = 0
        skipped_count = 0
        error_count = 0
        
        for protocol_name, columns in all_columns:
            print(f"\n📋 Добавление полей для {protocol_name}:")
            for col_name, col_type, description in columns:
                try:
                    # Проверяем, существует ли колонка
                    check_query = text("""
                        SELECT column_name 
                        FROM information_schema.columns 
                        WHERE table_name = 'servers' AND column_name = :col_name
                    """)
                    result = conn.execute(check_query, {"col_name": col_name})
                    exists = result.fetchone() is not None
                    
                    if exists:
                        print(f"   ⏭️  {col_name} - уже существует, пропускаем")
                        skipped_count += 1
                    else:
                        conn.execute(text(f"ALTER TABLE servers ADD COLUMN IF NOT EXISTS {col_name} {col_type}"))
                        print(f"   ✅ {col_name} - добавлено ({description})")
                        added_count += 1
                except Exception as e:
                    print(f"   ❌ {col_name} - ошибка: {e}")
                    error_count += 1
        
        trans.commit()
        
        print("\n" + "=" * 80)
        print("📊 ИТОГИ МИГРАЦИИ:")
        print(f"   ✅ Добавлено полей: {added_count}")
        print(f"   ⏭️  Пропущено (уже существуют): {skipped_count}")
        print(f"   ❌ Ошибок: {error_count}")
        print("=" * 80)
        
        if error_count == 0:
            print("\n✅ Миграция успешно завершена!")
            return True
        else:
            print(f"\n⚠️  Миграция завершена с {error_count} ошибками")
            return False
            
    except Exception as e:
        trans.rollback()
        print(f"\n❌ Критическая ошибка миграции: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        conn.close()

if __name__ == "__main__":
    print("=" * 80)
    print("🚀 МИГРАЦИЯ БД: Добавление полей для новых протоколов VPN")
    print("=" * 80)
    success = add_new_protocols_columns()
    sys.exit(0 if success else 1)


