import { organizationController } from '../controllers/organizationController.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => {
  const client = { from: jest.fn(), rpc: jest.fn() };
  return { __esModule: true, supabase: client, default: client };
});

const organizationId = '11111111-1111-4111-8111-111111111111';
const actorId = '22222222-2222-4222-8222-222222222222';
const tenant = {
  id: organizationId,
  name: 'Growers Cooperative',
  slug: 'growers',
  type: 'cooperative',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-1',
  userId: actorId,
  role: 'owner',
  permissions: [],
};

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('organization settings API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects non-object settings before persistence', async () => {
    const res = response();
    await organizationController.updateSettings({
      user: { id: actorId },
      tenant,
      body: { notificationPreferences: ['email'] },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('updates settings only through verified tenant and actor context', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: [{
        notification_preferences: { email: true },
        reporting_policy: { exportsEnabled: false },
        updated_by: actorId,
        updated_at: '2026-08-31T08:00:00.000Z',
      }],
      error: null,
    });
    const res = response();
    await organizationController.updateSettings({
      user: { id: actorId },
      tenant,
      body: {
        notificationPreferences: { email: true },
        organizationId: 'attacker-organization',
      },
    } as any, res);

    expect(supabase.rpc).toHaveBeenCalledWith('update_organization_settings', {
      p_organization_id: organizationId,
      p_actor_id: actorId,
      p_notification_preferences: { email: true },
      p_reporting_policy: null,
    });
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: {
        notificationPreferences: { email: true },
        reportingPolicy: { exportsEnabled: false },
        updatedBy: actorId,
        updatedAt: '2026-08-31T08:00:00.000Z',
      },
    });
  });

  it('reads settings only for the verified tenant', async () => {
    const maybeSingle = jest.fn().mockResolvedValue({
      data: {
        notification_preferences: {},
        reporting_policy: { crossTenantReporting: false },
        updated_by: null,
        updated_at: '2026-08-31T08:00:00.000Z',
      },
      error: null,
    });
    const eq = jest.fn().mockReturnValue({ maybeSingle });
    const select = jest.fn().mockReturnValue({ eq });
    (supabase.from as jest.Mock).mockReturnValue({ select });
    const res = response();
    await organizationController.getSettings({
      user: { id: actorId },
      tenant,
    } as any, res);

    expect(eq).toHaveBeenCalledWith('organization_id', organizationId);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: true,
      data: expect.objectContaining({
        reportingPolicy: { crossTenantReporting: false },
      }),
    }));
  });
});
