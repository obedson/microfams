import { assertDistinctTenants, TEST_TENANTS, tenantFixture } from './tenantFixtures.js';

describe('synthetic tenant fixtures', () => {
  it('provides two stable unrelated tenants for isolation scenarios', () => {
    assertDistinctTenants();
    expect(TEST_TENANTS).toHaveLength(2);
    expect(tenantFixture(0).organizationId).not.toBe(tenantFixture(1).organizationId);
    expect(tenantFixture(0).userId).not.toBe(tenantFixture(1).userId);
  });

  it('never uses production-looking identity values', () => {
    for (const tenant of TEST_TENANTS) {
      expect(tenant.name).toMatch(/^Synthetic /);
      expect(tenant.slug).toMatch(/^synthetic-/);
    }
  });
});
