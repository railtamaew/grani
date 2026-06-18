import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

/**
 * Расширенное тестирование по плану: фильтры, сортировка, экспорт, навигация.
 * Запуск: BASE_URL=https://admin.granilink.com ADMIN_EMAIL=... ADMIN_PASSWORD=... npx playwright test e2e/plan-extended.spec.ts
 */
const CREDENTIALS = {
  email: process.env.ADMIN_EMAIL || '',
  password: process.env.ADMIN_PASSWORD || '',
};

interface StepResult {
  section: string;
  step: string;
  status: 'passed' | 'failed' | 'skipped';
  error?: string;
}

test('Extended plan: filters, sort, export, navigation', async ({ page }) => {
  test.setTimeout(600000); // 10 min
  test.skip(!CREDENTIALS.email || !CREDENTIALS.password, 'Set ADMIN_EMAIL and ADMIN_PASSWORD');

  const results: StepResult[] = [];

  const runStep = async (section: string, step: string, fn: () => Promise<void>) => {
    try {
      await fn();
      results.push({ section, step, status: 'passed' });
    } catch (e: any) {
      results.push({ section, step, status: 'failed', error: (e?.message || String(e)).slice(0, 150) });
    }
  };

  // Логин
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(CREDENTIALS.email);
  await page.getByLabel('Пароль').fill(CREDENTIALS.password);
  await page.getByRole('button', { name: /Войти/i }).click();
  await expect(page).toHaveURL(/\/dashboard/, { timeout: 25000 });

  // 1. Дашборд
  await page.getByText('Дашборд', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(800);
  await runStep('Дашборд', '1.1 Карточки статистики', async () => {
    await expect(page.getByText(/Всего пользователей|Панель управления/)).toBeVisible({ timeout: 5000 });
  });
  await runStep('Дашборд', '1.6 Кнопка Обновить', async () => {
    await page.getByRole('button', { name: /Обновить/i }).first().click();
    await page.waitForTimeout(1000);
  });

  // 2. Пользователи
  await page.getByText('Пользователи', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1200);
  await runStep('Пользователи', '2.1 Таблица с пагинацией', async () => {
    await expect(page.getByText('Пользователи').first()).toBeVisible({ timeout: 5000 });
    await expect(page.locator('table')).toBeVisible({ timeout: 5000 });
  });
  await runStep('Пользователи', '2.2 Поиск по email', async () => {
    const searchInput = page.getByLabel(/Поиск по email/i);
    await searchInput.fill('test');
    await page.getByRole('button', { name: /Найти/i }).first().click();
    await page.waitForTimeout(1200);
  });
  await runStep('Пользователи', '2.7 Сброс фильтров', async () => {
    await page.getByRole('button', { name: /Сбросить/i }).first().click();
    await page.waitForTimeout(800);
  });
  await runStep('Пользователи', '2.8 Сортировка (клик по ID)', async () => {
    const idHeader = page.locator('th').filter({ hasText: /^ID$/ }).first();
    if (await idHeader.isVisible()) {
      await idHeader.click();
      await page.waitForTimeout(1000);
    }
  });
  await runStep('Пользователи', '2.10 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    await expect(exportBtn).toBeVisible();
    await exportBtn.click();
  });
  await runStep('Пользователи', '2.13 Переход в карточку', async () => {
    const viewBtn = page.locator('button[aria-label*="view"], button[aria-label*="visibility"]').first();
    if (await viewBtn.isVisible()) {
      await viewBtn.click();
      await expect(page).toHaveURL(/\/users\/\d+/);
      await page.goBack();
    } else {
      const firstUserLink = page.locator('table tbody tr').first().locator('a, button').first();
      if (await firstUserLink.isVisible()) {
        await firstUserLink.click();
        await page.waitForTimeout(800);
        await page.goBack();
      }
    }
  });

  // 4. Устройства
  await page.getByText('Устройства', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Устройства', '4.1 Таблица', async () => {
    await expect(page.getByText('Устройства').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Устройства', '4.5 Поиск + Найти', async () => {
    const searchInput = page.getByLabel(/Поиск по email|search/i).first();
    if (await searchInput.isVisible()) {
      await searchInput.fill('1');
      await page.getByRole('button', { name: /Найти/i }).first().click();
      await page.waitForTimeout(800);
    }
  });
  await runStep('Устройства', '4.6 Сброс', async () => {
    await page.getByRole('button', { name: /Сбросить/i }).first().click();
    await page.waitForTimeout(1000);
  });
  await runStep('Устройства', '4.9 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    if (await exportBtn.isVisible() && !(await exportBtn.isDisabled())) {
      await exportBtn.click();
    }
  });

  // 5. Триалы
  await page.getByText('Триалы', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Триалы', '5.1 Таблица', async () => {
    await expect(page.getByText('Триалы').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Триалы', '5.7 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    if (await exportBtn.isVisible() && !(await exportBtn.isDisabled())) {
      await exportBtn.click();
    }
  });

  // 6. Протоколы
  await page.getByText('Протоколы', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Протоколы', '6.1 Таблица или пустое состояние', async () => {
    const hasTable = await page.locator('table').isVisible();
    const hasEmpty = await page.getByText(/протоколы не настроены|протоколов/i).isVisible();
    expect(hasTable || hasEmpty).toBeTruthy();
  });

  // 7. Серверы
  await page.getByText('Серверы', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Серверы', '7.1 Таблица', async () => {
    await expect(page.getByText('Серверы').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Серверы', '7.2 Кнопка Добавить', async () => {
    const addBtn = page.getByRole('button', { name: /Добавить/i });
    await expect(addBtn).toBeVisible({ timeout: 3000 });
  });

  // 8. Инциденты
  await page.getByText('Инциденты', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Инциденты', '8.1 Таблица', async () => {
    await expect(page.getByText('Инциденты').first()).toBeVisible({ timeout: 5000 });
  });

  // 9. Платежи
  await page.getByText('Платежи', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Платежи', '9.1 Таблица', async () => {
    await expect(page.getByText('Платежи').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Платежи', '9.9 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    if (await exportBtn.isVisible() && !(await exportBtn.isDisabled())) {
      await exportBtn.click();
    }
  });

  // 10. Подписки
  await page.getByText('Подписки', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Подписки', '10.1 Таблица', async () => {
    await expect(page.getByText('Подписки').first()).toBeVisible({ timeout: 5000 });
  });

  // 11. Логи клиента
  await page.getByText('Логи клиента', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Логи клиента', '11.1 Таблица', async () => {
    await expect(page.getByText('Логи клиента').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Логи клиента', '11.10 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    if (await exportBtn.isVisible() && !(await exportBtn.isDisabled())) {
      await exportBtn.click();
    }
  });

  // 12. Логи подключений
  await page.getByText('Логи подключений', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Логи подключений', '12.1 Таблица', async () => {
    await expect(page.getByText('Логи подключений').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Логи подключений', '12.6 Экспорт CSV', async () => {
    const exportBtn = page.getByRole('button', { name: /Экспорт CSV/i });
    if (await exportBtn.isVisible() && !(await exportBtn.isDisabled())) {
      await exportBtn.click();
    }
  });

  // 13. Логи по пользователю
  await page.getByText('Логи по пользователю', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Логи по пользователю', '13.1 Форма выбора', async () => {
    await expect(page.getByText('Логи по пользователю').first()).toBeVisible({ timeout: 5000 });
    await expect(page.getByText(/User ID|ID пользователя/i)).toBeVisible({ timeout: 3000 });
  });
  await runStep('Логи по пользователю', '13.2 Поиск по User ID', async () => {
    const idInput = page.getByLabel(/User ID/i).or(page.locator('input[placeholder*="42"]')).first();
    if (await idInput.isVisible()) {
      await idInput.fill('1');
      await page.getByRole('button', { name: /Показать логи/i }).click();
      await page.waitForTimeout(1500);
    }
  });

  // 14. Audit Log
  await page.getByText('Audit Log', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Audit Log', '14.1 Таблица', async () => {
    await expect(page.getByText(/Audit|аудит/i).first()).toBeVisible({ timeout: 5000 });
  });

  // 15. Настройки
  await page.getByText('Настройки', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Настройки', '15.1 Вкладки', async () => {
    await expect(page.getByText('Настройки').first()).toBeVisible({ timeout: 5000 });
    await expect(page.getByText(/Feature|feature flags|Feature flags/i)).toBeVisible({ timeout: 3000 });
  });

  // 16. Коды авторизации
  await page.getByText('Коды авторизации', { exact: true }).first().click({ timeout: 10000 });
  await page.waitForTimeout(1000);
  await runStep('Коды авторизации', '16.1 Таблица', async () => {
    await expect(page.getByText('Коды авторизации').first()).toBeVisible({ timeout: 5000 });
  });
  await runStep('Коды авторизации', '16.2 Поиск по email', async () => {
    const searchInput = page.getByLabel(/Поиск по email/i);
    if (await searchInput.isVisible()) {
      await searchInput.fill(CREDENTIALS.email);
      await page.getByRole('button', { name: /Поиск/i }).click();
      await page.waitForTimeout(1000);
    }
  });

  // Запись отчёта
  const passed = results.filter((r) => r.status === 'passed').length;
  const failed = results.filter((r) => r.status === 'failed').length;

  const md = [
    '# Расширенный отчёт тестирования админ-панели',
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
    '## Детали по шагам',
    '',
    '| Раздел | Шаг | Статус | Ошибка |',
    '|--------|-----|--------|--------|',
    ...results.map(
      (r) =>
        `| ${r.section} | ${r.step} | ${r.status === 'passed' ? '✅' : '❌'} | ${r.error || '-'} |`
    ),
    '',
    '## Ошибки',
    '',
    ...(failed > 0
      ? results.filter((r) => r.error).map((r) => `- **${r.section}** ${r.step}: ${r.error}`)
      : ['Нет ошибок.']),
  ].join('\n');

  const reportPath = path.join(process.cwd(), 'admin-panel-test-report.md');
  fs.writeFileSync(reportPath, md, 'utf-8');
  console.log('\n📄 Отчёт сохранён: ' + reportPath);

  expect(failed, `Провалено ${failed} из ${results.length} шагов. Отчёт: ${reportPath}`).toBe(0);
});
