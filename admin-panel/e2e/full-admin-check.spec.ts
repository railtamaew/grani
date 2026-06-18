import { test, expect } from '@playwright/test';

/**
 * Полная проверка админ-панели под Owner.
 * Запуск: ADMIN_EMAIL=rail.tamaew@gmail.com ADMIN_PASSWORD='ChangeThisPassword123!' npx playwright test e2e/full-admin-check.spec.ts
 */
const PAGES: { path: string; titlePattern: RegExp | string }[] = [
  { path: '/dashboard', titlePattern: /панель управления|дашборд|dashboard/i },
  { path: '/users', titlePattern: /пользователи|users/i },
  { path: '/devices', titlePattern: /устройства|devices/i },
  { path: '/trials', titlePattern: /триалы|trials/i },
  { path: '/protocols', titlePattern: /протоколы|protocols/i },
  { path: '/servers', titlePattern: /серверы|servers/i },
  { path: '/incidents', titlePattern: /инциденты|incidents/i },
  { path: '/payments', titlePattern: /платежи|payments/i },
  { path: '/subscriptions', titlePattern: /подписки|subscriptions/i },
  { path: '/client-logs', titlePattern: /логи клиента|client logs/i },
  { path: '/connection-logs', titlePattern: /логи подключений|connection logs/i },
  { path: '/user-logs', titlePattern: /логи по пользователю|user logs/i },
  { path: '/audit-log', titlePattern: /audit|аудит/i },
  { path: '/settings', titlePattern: /настройки|settings|feature flags|администраторы/i },
  { path: '/auth-codes', titlePattern: /коды авторизации|auth codes/i },
];

test.describe('Full admin panel check (Owner)', () => {
  test.beforeEach(async ({ page }) => {
    const email = process.env.ADMIN_EMAIL;
    const password = process.env.ADMIN_PASSWORD;
    test.skip(!email || !password, 'Set ADMIN_EMAIL and ADMIN_PASSWORD');

    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Пароль').fill(password);
    await page.getByRole('button', { name: 'Войти' }).click();
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 20000 });
  });

  for (const { path, titlePattern } of PAGES) {
    test(`${path} loads`, async ({ page }) => {
      await page.goto(path);
      const pattern = typeof titlePattern === 'string' ? new RegExp(titlePattern, 'i') : titlePattern;
      await expect(
        page.getByRole('heading', { name: pattern }).or(page.getByText(pattern).first())
      ).toBeVisible({ timeout: 15000 });
    });
  }
});
