import { SupabaseTenantRepository } from '../repositories/tenantRepository.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => {
  const client = { from: jest.fn() };
  return {
    __esModule: true,
    supabase: client,
    default: client,
  };
});

interface QueryResult {
  data: unknown;
  error: unknown;
}

const query = (result: QueryResult) => {
  const builder: any = {};
  builder.select = jest.fn(() => builder);
  builder.eq = jest.fn(() => builder);
  builder.maybeSingle = jest.fn().mockResolvedValue(result);
  builder.then = (resolve: (value: QueryResult) => unknown, reject: (reason: unknown) => unknown) => (
    Promise.resolve(result).then(resolve, reject)
  );
  return builder;
};

const membershipRow = {
  id: 'membership-1',
  user_id: 'user-1',
  organization_id: 'organization-1',
  role: 'member',
  permissions: ['farms.read'],
  organization: {
    id: 'organization-1',
    name: 'Growers Cooperative',
    slug: 'growers-cooperative',
    type: 'cooperative',
    jurisdiction: 'NG',
    default_currency: 'NGN',
    timezone: 'Africa/Lagos',
    status: 'active',
  },
};

describe('SupabaseTenantRepository', () => {
  beforeEach(() => jest.clearAllMocks());

  it('requires active membership and active organization for an explicit selector', async () => {
    const builder = query({ data: null, error: null });
    (supabase.from as jest.Mock).mockReturnValue(builder);

    await expect(new SupabaseTenantRepository().findActiveMembership(
      'user-1',
      'organization-1',
    )).resolves.toBeNull();

    expect(supabase.from).toHaveBeenCalledWith('organization_memberships');
    expect(builder.eq.mock.calls).toEqual([
      ['user_id', 'user-1'],
      ['organization_id', 'organization-1'],
      ['status', 'active'],
      ['organizations.status', 'active'],
    ]);
    expect(builder.maybeSingle).toHaveBeenCalledTimes(1);
  });

  it('maps only a verified active membership into tenant context input', async () => {
    const builder = query({ data: membershipRow, error: null });
    (supabase.from as jest.Mock).mockReturnValue(builder);

    await expect(new SupabaseTenantRepository().findActiveMembership(
      'user-1',
      'organization-1',
    )).resolves.toMatchObject({
      id: 'membership-1',
      userId: 'user-1',
      organizationId: 'organization-1',
      role: 'member',
      permissions: ['farms.read'],
      organization: {
        id: 'organization-1',
        status: 'active',
      },
    });
  });

  it('filters automatic selection by active membership and active organization', async () => {
    const builder = query({ data: [membershipRow], error: null });
    (supabase.from as jest.Mock).mockReturnValue(builder);

    await expect(new SupabaseTenantRepository().listActiveMemberships('user-1'))
      .resolves.toHaveLength(1);

    expect(builder.eq.mock.calls).toEqual([
      ['user_id', 'user-1'],
      ['status', 'active'],
      ['organizations.status', 'active'],
    ]);
  });
});
