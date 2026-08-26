import { expect, test } from '@playwright/test';

test('farm records workflow creates and displays a tenant-scoped record', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('auth-storage', JSON.stringify({ state: { token: 'test-token', user: { id: 'farmer-1', role: 'farmer' }, isAuthenticated: true }, version: 0 }));
    localStorage.setItem('organization-storage', JSON.stringify({ state: { activeOrganizationId: 'organization-1' }, version: 0 }));
  });

  let records = [{ id: 'record-1', record_date: '2026-08-26', livestock_type: 'Goat', livestock_count: 12, feed_consumption: 4, mortality_count: 0, expenses: 1500 }];

  await page.route('**/api/properties**', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: [] }) }));
  await page.route('**/api/farm-records/my-records', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: records }) }));
  await page.route('**/api/farm-records/analytics**', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ analytics: { totalLivestock: 12, totalFeedConsumption: 4, totalMortality: 0, totalExpenses: 1500, mortalityRate: 0, recordCount: 1 }, records }) }));
  await page.route('**/api/farm-records', async route => {
    if (route.request().method() === 'POST') {
      const body = route.request().postDataJSON();
      records = [{ id: 'record-2', ...body }, ...records];
      await route.fulfill({ status: 201, contentType: 'application/json', body: JSON.stringify({ success: true, data: records[0] }) });
      return;
    }
    await route.continue();
  });

  await page.goto('/farm-records');
  await expect(page.getByRole('heading', { name: 'Farm Records & Analytics' })).toBeVisible();
  await expect(page.getByText('Goat')).toBeVisible();

  await page.locator('select').nth(1).selectOption({ label: 'Poultry' });
  await page.locator('input[type=number]').nth(1).fill('25');
  await page.getByRole('button', { name: 'Add Record' }).click();

  await expect(page.getByText('Poultry')).toBeVisible();
  await expect(page.getByText('25', { exact: true })).toBeVisible();
});
