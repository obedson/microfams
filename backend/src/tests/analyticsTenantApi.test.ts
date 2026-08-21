import express from 'express';
import request from 'supertest';
import analyticsRoutes from '../routes/analytics.js';
import { AnalyticsService } from '../services/analyticsService.js';
import supabase from '../utils/supabase.js';

jest.mock('../middleware/auth.js', () => ({
  authenticateToken: (req: any, _res: any, next: any) => {
    req.user = { id: 'user-1', role: 'owner' };
    next();
  },
}));

jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, _res: any, next: any) => {
    req.tenant = { id: 'organization-1', role: 'viewer', permissions: [] };
    next();
  },
}));

jest.mock('../services/analyticsService.js', () => ({
  AnalyticsService: {
    getPropertyAnalytics: jest.fn(),
    getFarmerDashboardAnalytics: jest.fn(),
    getDashboardAnalytics: jest.fn(),
    getRevenueBreakdown: jest.fn(),
    getPropertyPerformanceRanking: jest.fn(),
    getMonthlyTrends: jest.fn(),
    calculateOccupancyRate: jest.fn(),
  },
}));

jest.mock('../utils/supabase.js', () => ({
  __esModule: true,
  default: { from: jest.fn() },
}));

const app = express();
app.use('/api/analytics', analyticsRoutes);

describe('analytics tenant API boundary', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns not found without invoking analytics for a property outside the selected tenant', async () => {
    const single = jest.fn().mockResolvedValue({ data: null, error: { code: 'PGRST116' } });
    const eqOrganization = jest.fn().mockReturnValue({ single });
    const eqProperty = jest.fn().mockReturnValue({ eq: eqOrganization });
    const select = jest.fn().mockReturnValue({ eq: eqProperty });
    (supabase.from as jest.Mock).mockReturnValue({ select });

    await request(app).get('/api/analytics/property/foreign-property').expect(404, {
      success: false,
      message: 'Property not found',
    });

    expect(eqProperty).toHaveBeenCalledWith('id', 'foreign-property');
    expect(eqOrganization).toHaveBeenCalledWith('organization_id', 'organization-1');
    expect(AnalyticsService.getPropertyAnalytics).not.toHaveBeenCalled();
  });

  it('passes the resolved organization into dashboard aggregation', async () => {
    (AnalyticsService.getDashboardAnalytics as jest.Mock).mockResolvedValue({ total_properties: 0 });

    await request(app).get('/api/analytics/dashboard').expect(200);

    expect(AnalyticsService.getDashboardAnalytics).toHaveBeenCalledWith(
      'organization-1',
      'user-1',
      undefined,
      undefined,
    );
  });
});
