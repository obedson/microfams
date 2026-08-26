import { expect, test } from '@playwright/test';

test('inventory workflow creates an item and records a stock movement', async ({ page }) => {
  let items = [{ id: 'item-1', name: 'Feed', unit: 'kg', quantityMinor: 100, reorderLevelMinor: 20, sku: null, metadata: {} }];
  await page.route('**/api/auth/login', route => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ data: { user: { id: 'operator-1', email: 'operator@example.test', name: 'Operator', role: 'owner' }, token: 'test-token', refreshToken: 'refresh-token' } } ) }));
  await page.route('**/api/inventory', async route => {
    if (route.request().method() === 'GET') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ success: true, data: items }) });
    const body = route.request().postDataJSON();
    items = [{ id: 'item-2', name: body.name, unit: body.unit, quantityMinor: 0, reorderLevelMinor: body.reorderLevelMinor, sku: null, metadata: {} }, ...items];
    return route.fulfill({ status: 201, contentType: 'application/json', body: JSON.stringify({ success: true, data: items[0] }) });
  });
  await page.route('**/api/inventory/item-1/movements', async route => {
    const body = route.request().postDataJSON();
    items[0] = { ...items[0], quantityMinor: items[0].quantityMinor + body.quantityMinor };
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ success: true, data: items[0] }) });
  });

  await page.goto('/login');
  await page.getByLabel('Email Address').fill('operator@example.test');
  await page.getByLabel('Password').fill('test-password');
  await page.getByRole('button', { name: 'Sign In' }).click();
  await page.evaluate(() => localStorage.setItem('organization-storage', JSON.stringify({ state: { activeOrganizationId: 'organization-1' }, version: 0 })));
  await page.goto('/inventory');

  await expect(page.getByRole('heading', { name: 'Inventory' })).toBeVisible();
  await expect(page.getByText('Feed')).toBeVisible();
  await page.getByLabel('Item name').fill('Medicine');
  await page.getByLabel('Unit').fill('bottles');
  await page.getByRole('button', { name: 'Add item' }).click();
  await expect(page.getByText('Medicine')).toBeVisible();

  await page.getByLabel('Quantity for Feed').fill('25');
  await page.getByLabel('Reason for Feed').fill('Weekly delivery');
  await page.getByRole('button', { name: 'Record movement' }).first().click();
  await expect(page.getByText(/125 kg in stock/)).toBeVisible();
});
