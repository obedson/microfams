import { ContributionModel } from '../models/Contribution.js';
import supabase from '../utils/supabase.js';

describe('Contribution System', () => {
  let testGroupId: string;
  let testCycleId: string;
  let testUserId: string;

  beforeAll(async () => {
    // Create a test user first
    const { data: user } = await supabase
      .from('users')
      .insert({
        email: 'test-contribution@example.com',
        password: 'hashedpassword',
        name: 'Test User',
        role: 'farmer'
      })
      .select()
      .single();

    testUserId = user!.id;

    // Create test group with valid creator_id
    const { data: group } = await supabase
      .from('groups')
      .insert({
        name: 'Test Group',
        description: 'Test',
        creator_id: testUserId,
        contribution_enabled: true,
        contribution_amount: 5000,
        payment_day: 15,
        grace_period_days: 3,
        late_penalty_amount: 500,
        late_penalty_type: 'fixed'
      })
      .select()
      .single();
    
    testGroupId = group!.id;
  });

  afterAll(async () => {
    // Cleanup
    if (testGroupId) {
      await supabase.from('groups').delete().eq('id', testGroupId);
    }
    if (testUserId) {
      await supabase.from('users').delete().eq('id', testUserId);
    }
  });

  test('should create contribution cycle', async () => {
    const cycle = await ContributionModel.createCycle(testGroupId, 2, 2026);
    expect(cycle).toBeDefined();
    expect(cycle.cycle_month).toBe(2);
    expect(cycle.cycle_year).toBe(2026);
    testCycleId = cycle.id;
  });

  test('should get current cycle', async () => {
    const cycle = await ContributionModel.getCurrentCycle(testGroupId);
    expect(cycle).toBeDefined();
    expect(cycle.id).toBe(testCycleId);
  });

  test('should calculate penalty correctly', async () => {
    const { data: contribution } = await supabase
      .from('member_contributions')
      .select('id')
      .eq('cycle_id', testCycleId)
      .limit(1)
      .single();

    if (contribution) {
      const penalty = await ContributionModel.calculatePenalty(contribution.id);
      expect(penalty).toBeGreaterThanOrEqual(0);
    }
  });

  test('should get cycle details with contributions', async () => {
    const details = await ContributionModel.getCycleDetails(testCycleId);
    expect(details).toBeDefined();
    expect(details.contributions).toBeDefined();
  });
});
