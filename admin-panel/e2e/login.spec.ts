import { test, expect } from '@playwright/test';

test.describe('Login page', () => {
  test('shows login form with email and password fields', async ({ page }) => {
    await page.goto('/login');
    await expect(page.getByRole('textbox', { name: /email|почта|логин/i })).toBeVisible();
    await expect(page.getByLabel(/пароль|password/i)).toBeVisible();
    await expect(page.getByRole('button', { name: /вход|войти|login|sign in/i })).toBeVisible();
  });

  test('disables submit when form is empty', async ({ page }) => {
    await page.goto('/login');
    await expect(page.getByRole('button', { name: 'Войти' })).toBeDisabled();
    await expect(page).toHaveURL(/\/login/);
  });

  test('redirects to dashboard after successful login when backend available', async ({ page }) => {
    const email = process.env.ADMIN_EMAIL;
    const password = process.env.ADMIN_PASSWORD;
    test.skip(!email || !password, 'Set ADMIN_EMAIL and ADMIN_PASSWORD for login E2E');

    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Пароль').fill(password);
    await page.getByRole('button', { name: 'Войти' }).click();

    await expect(page).toHaveURL(/\/dashboard/, { timeout: 15000 });
  });
});
