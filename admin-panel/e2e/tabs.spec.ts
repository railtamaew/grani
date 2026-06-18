import { test, expect } from '@playwright/test';

test.describe('Protected routes', () => {
  test('redirects to login when visiting dashboard without auth', async ({ page }) => {
    await page.goto('/dashboard');
    await expect(page).toHaveURL(/\/login/);
  });

  test('redirects to login when visiting users without auth', async ({ page }) => {
    await page.goto('/users');
    await expect(page).toHaveURL(/\/login/);
  });

  test('redirects to login when visiting servers without auth', async ({ page }) => {
    await page.goto('/servers');
    await expect(page).toHaveURL(/\/login/);
  });
});

test.describe('Main tabs when authenticated', () => {
  test.beforeEach(async ({ page }) => {
    const email = process.env.ADMIN_EMAIL;
    const password = process.env.ADMIN_PASSWORD;
    test.skip(!email || !password, 'Set ADMIN_EMAIL and ADMIN_PASSWORD for authenticated E2E');

    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Пароль').fill(password);
    await page.getByRole('button', { name: 'Войти' }).click();
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 15000 });
  });

  test('dashboard page loads', async ({ page }) => {
    await page.goto('/dashboard');
    await expect(page.getByText(/дашборд|dashboard|главная/i).first()).toBeVisible({ timeout: 10000 });
  });

  test('users page loads and shows table or filters', async ({ page }) => {
    await page.goto('/users');
    await expect(
      page.getByRole('heading', { name: /пользователи|users/i }).or(page.getByText(/пользователи|поиск/i).first())
    ).toBeVisible({ timeout: 10000 });
  });

  test('servers page loads', async ({ page }) => {
    await page.goto('/servers');
    await expect(
      page.getByRole('heading', { name: /серверы|servers/i }).or(page.getByText(/серверы|добавить сервер/i).first())
    ).toBeVisible({ timeout: 10000 });
  });

  test('settings page loads', async ({ page }) => {
    await page.goto('/settings');
    await expect(page.getByText(/настройки|settings|feature flags|администраторы/i).first()).toBeVisible({
      timeout: 10000,
    });
  });
});
