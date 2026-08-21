import { FarmRecordService } from '../services/farmRecordService.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  __esModule: true,
  supabase: { from: jest.fn() },
}));

describe('farm record create reference validation', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects a booking outside the tenant or farmer scope', async () => {
    const maybeSingle = jest.fn().mockResolvedValue({ data: null, error: null });
    const eqFarmer = jest.fn().mockReturnValue({ maybeSingle });
    const eqOrganization = jest.fn().mockReturnValue({ eq: eqFarmer });
    const eqId = jest.fn().mockReturnValue({ eq: eqOrganization });
    const select = jest.fn().mockReturnValue({ eq: eqId });
    (supabase.from as jest.Mock).mockReturnValue({ select });

    await expect(FarmRecordService.validateCreateReferences(
      'booking-foreign', null, 'organization-1', 'farmer-1'
    )).rejects.toThrow('Booking does not belong');
  });

  it('rejects a property that does not match the linked booking', async () => {
    const maybeSingle = jest.fn().mockResolvedValue({
      data: { id: 'booking-1', property_id: 'property-1' }, error: null,
    });
    const eqFarmer = jest.fn().mockReturnValue({ maybeSingle });
    const eqOrganization = jest.fn().mockReturnValue({ eq: eqFarmer });
    const eqId = jest.fn().mockReturnValue({ eq: eqOrganization });
    const select = jest.fn().mockReturnValue({ eq: eqId });
    (supabase.from as jest.Mock).mockReturnValue({ select });

    await expect(FarmRecordService.validateCreateReferences(
      'booking-1', 'property-foreign', 'organization-1', 'farmer-1'
    )).rejects.toThrow('property must match');
  });
});
