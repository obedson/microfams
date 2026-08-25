import { InventoryService } from ''../domains/inventory/inventoryService.js'';
describe(''InventoryService'', () => {
  it(''rejects invalid item input'', async () => { await expect(new InventoryService().create(''org'', { name: '' '', unit: ''kg'' })).rejects.toThrow(''INVENTORY_ITEM_INVALID''); });
  it(''rejects zero movements'', async () => { await expect(new InventoryService().move(''org'', ''item'', { quantityMinor: 0, reason: ''x'', idempotencyKey: ''k'' })).rejects.toThrow(''INVENTORY_MOVEMENT_INVALID''); });
});
