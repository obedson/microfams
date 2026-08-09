import { expect, test } from '@playwright/test';

test('login route renders and validates required credentials', async ({ page }) => {
  await page.goto('/login');

  await expect(page.getByRole('heading', { name: 'Welcome Back' })).toBeVisible();
  await page.getByRole('button', { name: 'Sign In' }).click();

  await expect(page.getByText('Email is required')).toBeVisible();
  await expect(page.getByText('Password is required')).toBeVisible();
});
