# Настройка GitHub для Desktop Build

## Текущее состояние

- Workflow добавлен: `.github/workflows/desktop-build.yml`
- Git: первый коммит сделан (только workflow)

## Вариант A: У вас уже есть репозиторий на GitHub

1. Откройте ваш репозиторий: **https://github.com/YOUR_USERNAME/YOUR_REPO**
2. Скопируйте содержимое `.github/workflows/desktop-build.yml` в ваш репо (через веб-интерфейс или `git pull` + копирование файла)
3. Закоммитьте и запушьте
4. Перейдите в **Actions** → **Desktop Build (Windows + macOS)** → **Run workflow**

## Вариант B: Новый репозиторий

1. Создайте репозиторий на GitHub: **https://github.com/new**
2. Добавьте remote и запушьте:
   ```bash
   cd /opt/grani
   git remote add origin https://github.com/YOUR_USERNAME/grani.git
   git add .
   git commit -m "Add full project"
   git push -u origin master
   ```
3. Actions запустится автоматически при push

## Открыть GitHub в браузере

- Создать репо: https://github.com/new?name=grani
- Actions (после push): https://github.com/YOUR_USERNAME/YOUR_REPO/actions
