import { ReportingService } from '../services/reportingService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  __esModule: true,
  supabase: { from: jest.fn() },
  default: { from: jest.fn() },
}));

const settingsQuery = (result: { data: unknown; error: unknown }) => {
  const query = {
    select: jest.fn(),
    eq: jest.fn(),
    maybeSingle: jest.fn().mockResolvedValue(result),
  };
  query.select.mockReturnValue(query);
  query.eq.mockReturnValue(query);
  return query;
};

describe('tenant reporting exports', () => {
  beforeEach(() => jest.clearAllMocks());

  it('requires an enabled tenant policy before querying participant exports', async () => {
    const policyQuery = settingsQuery({
      data: { reporting_policy: { exportsEnabled: true } },
      error: null,
    });
    const exportQuery = {
      select: jest.fn(),
      limit: jest.fn(),
      or: jest.fn(),
      eq: jest.fn(),
    };
    exportQuery.select.mockReturnValue(exportQuery);
    exportQuery.limit.mockReturnValue(exportQuery);
    exportQuery.or.mockResolvedValue({ data: [{ id: 'booking-1' }], error: null });
    (supabase.from as jest.Mock).mockImplementation((table: string) => (
      table === 'organization_settings' ? policyQuery : exportQuery
    ));

    await ReportingService.exportToCSV('org-a', 'bookings', ['id']);

    expect(policyQuery.eq).toHaveBeenCalledWith('organization_id', 'org-a');
    expect(exportQuery.or).toHaveBeenCalledWith(
      'organization_id.eq.org-a,provider_organization_id.eq.org-a',
    );
    expect(exportQuery.eq).not.toHaveBeenCalled();
  });

  it('fails closed when export policy is missing or disabled', async () => {
    const policyQuery = settingsQuery({ data: null, error: null });
    (supabase.from as jest.Mock).mockReturnValue(policyQuery);

    await expect(ReportingService.exportToCSV('org-a', 'bookings', ['id']))
      .rejects.toThrow('Organization report exports are disabled');

    expect(supabase.from).toHaveBeenCalledTimes(1);
    expect(supabase.from).toHaveBeenCalledWith('organization_settings');
  });

  it('fails closed when the policy lookup fails', async () => {
    const policyQuery = settingsQuery({
      data: null,
      error: new Error('settings unavailable'),
    });
    (supabase.from as jest.Mock).mockReturnValue(policyQuery);

    await expect(ReportingService.exportToCSV('org-a', 'bookings', ['id']))
      .rejects.toThrow('Organization report exports are disabled');
    expect(supabase.from).toHaveBeenCalledTimes(1);
  });

  it('fails closed when a table has no tenant scope', async () => {
    await expect(ReportingService.exportToCSV('org-a', 'users', ['id']))
      .rejects.toThrow('Export tenant scope is not configured');
    expect(supabase.from).not.toHaveBeenCalled();
  });
});
