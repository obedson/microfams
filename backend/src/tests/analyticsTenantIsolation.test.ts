import { CacheKeys } from '../utils/redis.js';

describe('analytics tenant isolation', () => {
  const tenantA = '11111111-1111-4111-8111-111111111111';
  const tenantB = '22222222-2222-4222-8222-222222222222';
  const propertyId = '33333333-3333-4333-8333-333333333333';
  const ownerId = '44444444-4444-4444-8444-444444444444';

  test('property and occupancy cache entries cannot collide across tenants', () => {
    expect(CacheKeys.propertyAnalytics(tenantA, propertyId)).not.toBe(
      CacheKeys.propertyAnalytics(tenantB, propertyId),
    );
    expect(CacheKeys.occupancyRate(tenantA, propertyId, '2026-01-01', '2026-01-31')).not.toBe(
      CacheKeys.occupancyRate(tenantB, propertyId, '2026-01-01', '2026-01-31'),
    );
  });

  test('aggregate cache entries cannot collide across tenants', () => {
    expect(CacheKeys.dashboardAnalytics(tenantA, ownerId)).not.toBe(
      CacheKeys.dashboardAnalytics(tenantB, ownerId),
    );
    expect(CacheKeys.revenueBreakdown(tenantA, propertyId, ownerId)).not.toBe(
      CacheKeys.revenueBreakdown(tenantB, propertyId, ownerId),
    );
    expect(CacheKeys.propertyPerformance(tenantA, ownerId)).not.toBe(
      CacheKeys.propertyPerformance(tenantB, ownerId),
    );
    expect(CacheKeys.monthlyTrends(tenantA, ownerId, propertyId, 12)).not.toBe(
      CacheKeys.monthlyTrends(tenantB, ownerId, propertyId, 12),
    );
  });
});
