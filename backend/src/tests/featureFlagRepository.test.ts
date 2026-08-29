import { jest } from '@jest/globals';
import { SupabaseFeatureFlagRepository } from '../repositories/featureFlagRepository.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  supabase: { from: jest.fn() },
}));

describe('SupabaseFeatureFlagRepository', () => {
  it('loads only approved overrides for runtime evaluation', async () => {
    const definitionQuery = {
      select: jest.fn(),
      eq: jest.fn(),
      maybeSingle: jest.fn().mockResolvedValue({
        data: { emergency_disabled: false },
        error: null,
      } as never),
    };
    definitionQuery.select.mockReturnValue(definitionQuery);
    definitionQuery.eq.mockReturnValue(definitionQuery);

    const overrideResult = { data: [], error: null };
    const overrideQuery: any = {
      select: jest.fn(),
      eq: jest.fn(),
      then: (resolve: (value: unknown) => unknown) => Promise.resolve(overrideResult).then(resolve),
    };
    overrideQuery.select.mockReturnValue(overrideQuery);
    overrideQuery.eq.mockReturnValue(overrideQuery);

    (supabase.from as jest.Mock)
      .mockReturnValueOnce(definitionQuery)
      .mockReturnValueOnce(overrideQuery);

    await new SupabaseFeatureFlagRepository().getState('integration.weather');

    expect(overrideQuery.eq).toHaveBeenNthCalledWith(1, 'feature_key', 'integration.weather');
    expect(overrideQuery.eq).toHaveBeenNthCalledWith(2, 'status', 'approved');
  });
});
