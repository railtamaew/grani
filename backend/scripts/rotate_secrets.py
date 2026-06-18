#!/usr/bin/env python3
"""
Скрипт для безопасной ротации секретов без остановки сервиса.

Использование:
    python scripts/rotate_secrets.py --generate-new-secret-key
    python scripts/rotate_secrets.py --rotate-all
    python scripts/rotate_secrets.py --check-secrets
"""
import sys
import os
import secrets
import argparse
from pathlib import Path

# Добавляем путь к backend
sys.path.insert(0, str(Path(__file__).parent.parent))

def generate_secret_key() -> str:
    """Генерирует криптографически стойкий секретный ключ"""
    return secrets.token_urlsafe(32)

def check_secrets_file(file_path: str) -> dict:
    """Проверяет файл с секретами на наличие проблем"""
    issues = []
    if not os.path.exists(file_path):
        return {"exists": False, "issues": ["File does not exist"]}
    
    # Проверяем права доступа
    stat_info = os.stat(file_path)
    mode = stat_info.st_mode & 0o777
    if mode > 0o600:
        issues.append(f"File permissions too open: {oct(mode)} (should be 600)")
    
    # Проверяем содержимое
    with open(file_path, 'r') as f:
        content = f.read()
        if 'change-this' in content.lower():
            issues.append("Contains placeholder 'change-this'")
        if 'password123' in content.lower() or 'password' in content.lower():
            issues.append("Contains weak password patterns")
    
    return {"exists": True, "issues": issues, "mode": oct(mode)}

def create_secrets_template(output_path: str):
    """Создает шаблон файла с секретами"""
    template = """# GRANI VPN Secrets Configuration
# ВАЖНО: Этот файл содержит секреты. Храните его в безопасном месте.
# Права доступа должны быть 600: chmod 600 {file}
# Не коммитьте этот файл в Git!

# Database
DATABASE_URL=postgresql://user:CHANGE_ME@localhost:5432/granivpn
POSTGRES_PASSWORD=CHANGE_ME

# Redis
REDIS_URL=redis://:CHANGE_ME@localhost:6379/0
REDIS_PASSWORD=CHANGE_ME

# JWT Secret Key (минимум 32 символа)
# Сгенерировать: python -c "import secrets; print(secrets.token_urlsafe(32))"
SECRET_KEY=CHANGE_ME

# Старый SECRET_KEY для ротации (опционально, оставьте пустым если не ротируете)
SECRET_KEY_OLD=

# Email SMTP
SMTP_HOST=smtp.yandex.ru
SMTP_PORT=465
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
SMTP_FROM_EMAIL=CHANGE_ME
SMTP_FROM_NAME=GRANI

# AWS SES / Yandex Cloud Postbox (альтернатива SMTP)
AWS_ACCESS_KEY_ID=CHANGE_ME
AWS_SECRET_ACCESS_KEY=CHANGE_ME
AWS_REGION=ru-central1
USE_AWS_SES=false

# Environment
ENV=production
""".format(file=output_path)
    
    with open(output_path, 'w') as f:
        f.write(template)
    
    # Устанавливаем безопасные права
    os.chmod(output_path, 0o600)
    print(f"✅ Created secrets template: {output_path}")
    print(f"⚠️  Remember to set secure permissions: chmod 600 {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Rotate secrets safely')
    parser.add_argument('--generate-new-secret-key', action='store_true',
                       help='Generate a new SECRET_KEY')
    parser.add_argument('--check-secrets', type=str, metavar='FILE',
                       help='Check secrets file for issues')
    parser.add_argument('--create-template', type=str, metavar='FILE',
                       help='Create a secrets template file')
    parser.add_argument('--rotate-all', action='store_true',
                       help='Interactive rotation of all secrets')
    
    args = parser.parse_args()
    
    if args.generate_new_secret_key:
        new_key = generate_secret_key()
        print(f"\n🔑 New SECRET_KEY generated:")
        print(f"SECRET_KEY={new_key}")
        print(f"\n⚠️  To rotate without logout:")
        print(f"1. Set SECRET_KEY_OLD to current SECRET_KEY")
        print(f"2. Set SECRET_KEY to the new key above")
        print(f"3. Restart application")
        print(f"4. After all tokens expire, remove SECRET_KEY_OLD")
    
    elif args.check_secrets:
        result = check_secrets_file(args.check_secrets)
        if not result["exists"]:
            print(f"❌ File does not exist: {args.check_secrets}")
            return
        
        if result["issues"]:
            print(f"⚠️  Issues found in {args.check_secrets}:")
            for issue in result["issues"]:
                print(f"  - {issue}")
        else:
            print(f"✅ Secrets file looks good: {args.check_secrets}")
        print(f"   Permissions: {result['mode']}")
    
    elif args.create_template:
        create_secrets_template(args.create_template)
    
    elif args.rotate_all:
        print("🔄 Interactive secret rotation")
        print("This will guide you through rotating all secrets safely.")
        print("\n⚠️  Make sure you have backups before proceeding!")
        
        response = input("\nContinue? (yes/no): ")
        if response.lower() != 'yes':
            print("Cancelled.")
            return
        
        # Генерируем новый SECRET_KEY
        new_key = generate_secret_key()
        print(f"\n🔑 New SECRET_KEY: {new_key}")
        print("\nTo apply:")
        print("1. Update your secrets file with the new SECRET_KEY")
        print("2. Set SECRET_KEY_OLD to current value (for graceful migration)")
        print("3. Restart the application")
        print("4. Monitor logs for any issues")
        print("5. After migration period, remove SECRET_KEY_OLD")
    
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
