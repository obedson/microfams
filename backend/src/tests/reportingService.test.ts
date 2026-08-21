import { ReportingService } from '../services/reportingService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  __esModule: true,
  supabase: { from: jest.fn() },
  default: { from: jest.fn() },
}));

describe('tenant reporting exports', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses both booking organization columns for participant exports', async () => {
    const query = { select: jest.fn(), limit: jest.fn(), or: jest.fn(), eq: jest.fn() };
    query.select.mockReturnValue(query); query.limit.mockReturnValue(query); query.or.mockReturnValue(query);
    query.or.mockResolvedValue({ data: [{ id: 'booking-1' }], error: null });
    (supabase.from as jest.Mock).mockReturnValue(query);

    await ReportingService.exportToCSV('org-a', 'bookings', ['id']);

    expect(query.or).toHaveBeenCalledWith('organization_id.eq.org-a,provider_organization_id.eq.org-a');
    expect(query.eq).not.toHaveBeenCalled();
  });

  it('fails closed when a table has no tenant scope', async () => {
    await expect(ReportingService.exportToCSV('org-a', 'users', ['id']))
      .rejects.toThrow('Export tenant scope is not configured');
    expect(supabase.from).not.toHaveBeenCalled();
  });
});
