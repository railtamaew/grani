import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Полное тестирование админ-панели с отчётом по каждой функции.
 * Запуск: BASE_URL=https://admin.granilink.com ADMIN_EMAIL=... ADMIN_PASSWORD=... npx playwright test e2e/full-admin-report.spec.ts
 */
const CREDENTIALS = {
  email: process.env.ADMIN_EMAIL || '',
  password: process.env.ADMIN_PASSWORD || '',
};

interface TestResult {
  name: string;
  path: string;
  status: 'passed' | 'failed';
  durationMs?: number;
  error?: string;
  extraActions?: string;
}

test('Full admin panel functional test with report', async ({ page }) => {
  test.setTimeout(300000); // 5 min for all pages
  test.skip(!CREDENTIALS.email || !CREDENTIALS.password, 'Set ADMIN_EMAIL and ADMIN_PASSWORD');

  const results: TestResult[] = [];
  const tests: { name: string; path: string; check: string; altCheck?: string; extraAction?: string }[] = [
    { name: 'Дашборд', path: '/dashboard', check: 'Панель управления', altCheck: 'Обновить', extraAction: 'Обновить' },
    { name: 'Пользователи', path: '/users', check: 'Пользователи', altCheck: 'Поиск', extraAction: 'Экспорт CSV' },
    { name: 'Устройства', path: '/devices', check: 'Устройства', altCheck: 'Обновить', extraAction: 'Обновить' },
    { name: 'Триалы', path: '/trials', check: 'Триалы', altCheck: 'Поиск', extraAction: 'Экспорт CSV' },
    { name: 'Протоколы', path: '/protocols', check: 'Протоколы', altCheck: 'Обновить' },
    { name: 'Серверы', path: '/servers', check: 'Серверы', altCheck: 'Добавить сервер', extraAction: 'Обновить' },
    { name: 'Инциденты', path: '/incidents', check: 'Инциденты', altCheck: 'Обновить' },
    { name: 'Платежи', path: '/payments', check: 'Платежи', altCheck: 'Обновить', extraAction: 'Экспорт CSV' },
    { name: 'Подписки', path: '/subscriptions', check: 'Подписки', altCheck: 'Обновить' },
    { name: 'Логи клиента', path: '/client-logs', check: 'Логи клиента', altCheck: 'Экспорт CSV' },
    { name: 'Логи подключений', path: '/connection-logs', check: 'Логи подключений', altCheck: 'Экспорт CSV' },
    { name: 'Логи по пользователю', path: '/user-logs', check: 'Логи по пользователю', altCheck: 'ID пользователя' },
    { name: 'Audit Log', path: '/audit-log', check: 'Audit', altCheck: 'Обновить' },
    { name: 'Настройки', path: '/settings', check: 'Настройки', altCheck: 'Feature flags' },
    { name: 'Коды авторизации', path: '/auth-codes', check: 'Коды авторизации', altCheck: 'Обновить' },
  ];

  // Логин
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  const emailInput = page.locator('input[type="email"], input[name="email"]').first();
  const passwordInput = page.locator('input[type="password"]').first();
  await emailInput.fill(CREDENTIALS.email);
  await passwordInput.fill(CREDENTIALS.password);
  await page.getByRole('button', { name: /Войти/i }).click();
  await expect(page).toHaveURL(/\/dashboard/, { timeout: 25000 });

  // Тест каждой страницы — кликаем по пунктам меню в сайдбаре
  for (const t of tests) {
    const start = Date.now();
    try {
      // Клик по пункту меню в левом сайдбаре
      await page.getByText(t.name, { exact: true }).first().click({ timeout: 10000 });
      await page.waitForTimeout(2000); // дать время на загрузку
      const bodyText = await page.locator('body').textContent() || '';
      const found = new RegExp(t.check, 'i').test(bodyText)
        || (t.altCheck ? new RegExp(t.altCheck, 'i').test(bodyText) : false);
      if (!found) {
        await page.waitForTimeout(3000);
        const bodyTextRetry = await page.locator('body').textContent() || '';
        const foundRetry = new RegExp(t.check, 'i').test(bodyTextRetry)
          || (t.altCheck ? new RegExp(t.altCheck, 'i').test(bodyTextRetry) : false);
        if (!foundRetry) throw new Error('Элемент не найден');
      }
      // Расширенные проверки: клик по кнопке действия
      let extraActions = '';
      if (t.extraAction) {
        try {
          const btn = page.getByRole('button', { name: new RegExp(t.extraAction, 'i') }).first();
          if (await btn.isVisible({ timeout: 2000 }) && !(await btn.isDisabled())) {
            await btn.click();
            extraActions = t.extraAction;
            await page.waitForTimeout(500);
          }
        } catch {
          // игнорируем — не критично
        }
      }
      results.push({ name: t.name, path: t.path, status: 'passed', durationMs: Date.now() - start, extraActions });
    } catch (e: any) {
      results.push({
        name: t.name,
        path: t.path,
        status: 'failed',
        durationMs: Date.now() - start,
        error: (e?.message || String(e)).slice(0, 200),
      });
    }
  }

  // Запись отчёта
  const reportPath = path.join(process.cwd(), 'admin-panel-test-report.md');
  const passed = results.filter((r) => r.status === 'passed').length;
  const failed = results.filter((r) => r.status === 'failed').length;

  const md = [
    '# Отчёт тестирования админ-панели',
    '',
    `**Дата:** ${new Date().toISOString().slice(0, 19)}`,
    `**URL:** ${process.env.BASE_URL || 'https://admin.granilink.com'}`,
    `**Пользователь:** ${CREDENTIALS.email || '(не указан)'}`,
    '',
    '## Сводка',
    '',
    `| Статус | Количество |`,
    `|--------|------------|`,
    `| ✅ Пройдено | ${passed} |`,
    `| ❌ Провалено | ${failed} |`,
    `| **Всего** | **${results.length}** |`,
    '',
    '## Детали по функциям',
    '',
    '| № | Функция | Путь | Статус | Время (мс) | Доп. проверки |',
    '|---|---------|------|--------|-------------|----------------|',
    ...results.map(
      (r, i) =>
        `| ${i + 1} | ${r.name} | ${r.path} | ${r.status === 'passed' ? '✅' : '❌'} | ${r.durationMs ?? '-'} | ${r.extraActions || '-'} |`
    ),
    '',
    '## Ошибки (если есть)',
    '',
    ...(results.filter((r) => r.error).length > 0
      ? results.filter((r) => r.error).map((r) => `- **${r.name}**: ${r.error}`)
      : ['Нет ошибок.']),
  ].join('\n');

  fs.writeFileSync(reportPath, md, 'utf-8');
  console.log('\n📄 Отчёт сохранён: ' + reportPath);

  if (failed > 0) {
    throw new Error(`${failed} из ${results.length} страниц не прошли проверку. См. отчёт: ${reportPath}`);
  }
});
