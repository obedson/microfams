import { organizationController } from '../controllers/organizationController.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => {
  const client = { from: jest.fn() };
  return { __esModule: true, supabase: client, default: client };
});

const tenant = {
  id: '11111111-1111-4111-8111-111111111111',
  name: 'Growers Cooperative',
  slug: 'growers-cooperative',
  type: 'cooperative',
  jurisdiction: 'NG',
  defaultCurrency: 'NGN',
  timezone: 'Africa/Lagos',
  status: 'active',
  membershipId: 'membership-1',
  userId: 'user-1',
  role: 'owner',
  permissions: [],
};

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('organization branding API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects unsafe branding values before persistence', async () => {
    const res = response();

    await organizationController.updateBranding({
      user: { id: 'user-1' },
      tenant,
      body: {
        logoUrl: 'http://insecure.example.test/logo.png',
        primaryColor: 'green',
      },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(supabase.from).not.toHaveBeenCalled();
  });

  it('persists validated branding under verified tenant context', async () => {
    const single = jest.fn().mockResolvedValue({
      data: {
        display_name: 'Growers',
        logo_url: 'https://cdn.example.test/logo.png',
        primary_color: '#008000',
        secondary_color: '#FFFFFF',
        support_email: 'support@example.test',
        support_phone: '+2348000000000',
        custom_domain: 'growers.example.test',
      },
      error: null,
    });
    const select = jest.fn().mockReturnValue({ single });
    const upsert = jest.fn().mockReturnValue({ select });
    (supabase.from as jest.Mock).mockReturnValue({ upsert });
    const res = response();

    await organizationController.updateBranding({
      user: { id: 'user-1' },
      tenant,
      body: { primaryColor: '#008000' },
    } as any, res);

    expect(supabase.from).toHaveBeenCalledWith('organization_branding');
    expect(upsert).toHaveBeenCalledWith(expect.objectContaining({
      organization_id: tenant.id,
      updated_by: 'user-1',
      primary_color: '#008000',
    }), { onConflict: 'organization_id' });
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: true,
      data: expect.objectContaining({ primaryColor: '#008000' }),
    }));
  });

  it('reads current branding only for the verified tenant', async () => {
    const maybeSingle = jest.fn().mockResolvedValue({ data: null, error: null });
    const eq = jest.fn().mockReturnValue({ maybeSingle });
    const select = jest.fn().mockReturnValue({ eq });
    (supabase.from as jest.Mock).mockReturnValue({ select });
    const res = response();

    await organizationController.current({
      user: { id: 'user-1' },
      tenant,
    } as any, res);

    expect(eq).toHaveBeenCalledWith('organization_id', tenant.id);
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: { organization: tenant, branding: null },
    });
  });
});
