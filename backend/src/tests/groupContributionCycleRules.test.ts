import fc from 'fast-check';
import {
  GROUP_CONTRIBUTION_CYCLE_STATES,
  assertCycleTransition,
  canTransitionCycle,
  summarizeCycleTotals,
  validateCycleWindow,
  validateObligationAdjustment,
} from '../domains/groups/contributionCycleRules.js';

describe('group contribution cycle rules', () => {
  const window = {
    periodKey: '2026-09',
    periodStart: '2026-09-01',
    periodEnd: '2026-09-30',
    dueDate: '2026-09-25',
    timezone: 'Africa/Lagos',
  };

  it('normalizes a valid billing window to ISO days', () => {
    expect(validateCycleWindow(window)).toEqual({
      periodKey: '2026-09',
      periodStart: '2026-09-01',
      periodEnd: '2026-09-30',
      dueDate: '2026-09-25',
      timezone: 'Africa/Lagos',
    });
  });

  it('refuses a period that ends before it starts', () => {
    expect(() => validateCycleWindow({ ...window, periodEnd: '2026-08-01' }))
      .toThrow('GROUP_CONTRIBUTION_PERIOD_INVALID');
  });

  it('refuses a cycle that falls due before its period begins', () => {
    expect(() => validateCycleWindow({ ...window, dueDate: '2026-08-15' }))
      .toThrow('GROUP_CONTRIBUTION_DUE_DATE_INVALID');
  });

  it('refuses a malformed period key or timezone', () => {
    expect(() => validateCycleWindow({ ...window, periodKey: 'September' }))
      .toThrow('GROUP_CONTRIBUTION_PERIOD_KEY_INVALID');
    expect(() => validateCycleWindow({ ...window, timezone: 'X' }))
      .toThrow('GROUP_CONTRIBUTION_TIMEZONE_INVALID');
  });

  it('treats closed and cancelled as terminal', () => {
    for (const state of GROUP_CONTRIBUTION_CYCLE_STATES) {
      expect(canTransitionCycle('closed', state)).toBe(false);
      expect(canTransitionCycle('cancelled', state)).toBe(false);
    }
  });

  it('allows only the documented cycle transitions', () => {
    expect(canTransitionCycle('draft', 'open')).toBe(true);
    expect(canTransitionCycle('open', 'grace')).toBe(true);
    expect(canTransitionCycle('open', 'closing')).toBe(true);
    expect(canTransitionCycle('grace', 'closing')).toBe(true);
    expect(canTransitionCycle('closing', 'closed')).toBe(true);
    // A cycle may not skip straight from billing to closed, and may not reopen.
    expect(canTransitionCycle('open', 'closed')).toBe(false);
    expect(canTransitionCycle('grace', 'open')).toBe(false);
    expect(canTransitionCycle('closing', 'open')).toBe(false);
    expect(() => assertCycleTransition('closed', 'open'))
      .toThrow('GROUP_CONTRIBUTION_CYCLE_TRANSITION_INVALID');
  });

  it('never permits a transition out of a terminal state', () => {
    fc.assert(fc.property(
      fc.constantFrom('closed', 'cancelled'),
      fc.constantFrom(...GROUP_CONTRIBUTION_CYCLE_STATES),
      (from, to) => {
        expect(canTransitionCycle(from, to)).toBe(false);
      },
    ));
  });

  describe('obligation adjustments', () => {
    const adjustment = {
      adjustmentKind: 'reduction',
      deltaMinor: -50_000,
      reasonCode: 'PARTIAL_HARDSHIP',
      reason: 'Committee approved a partial reduction.',
    };

    it('accepts a reduction that leaves a balance', () => {
      expect(validateObligationAdjustment(adjustment, 250_000)).toEqual({
        adjustmentKind: 'reduction',
        deltaMinor: -50_000,
        reasonCode: 'PARTIAL_HARDSHIP',
        reason: 'Committee approved a partial reduction.',
        evidence: {},
      });
    });

    it('refuses an adjustment that pushes the obligation below zero', () => {
      expect(() => validateObligationAdjustment(
        { ...adjustment, deltaMinor: -400_000 }, 250_000,
      )).toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_EXCEEDS_OBLIGATION');
    });

    it('requires a waiver to clear the whole debt', () => {
      expect(() => validateObligationAdjustment(
        { ...adjustment, adjustmentKind: 'waiver', deltaMinor: -50_000 }, 250_000,
      )).toThrow('GROUP_CONTRIBUTION_WAIVER_MUST_CLEAR_OBLIGATION');

      expect(validateObligationAdjustment(
        { ...adjustment, adjustmentKind: 'waiver', deltaMinor: -250_000 }, 250_000,
      )).toMatchObject({ adjustmentKind: 'waiver', deltaMinor: -250_000 });
    });

    it('refuses a zero delta, an unknown kind, and a missing reason', () => {
      expect(() => validateObligationAdjustment({ ...adjustment, deltaMinor: 0 }, 250_000))
        .toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_DELTA_INVALID');
      expect(() => validateObligationAdjustment(
        { ...adjustment, adjustmentKind: 'forgive' }, 250_000,
      )).toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_KIND_INVALID');
      expect(() => validateObligationAdjustment({ ...adjustment, reason: '  ' }, 250_000))
        .toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_REASON_INVALID');
      expect(() => validateObligationAdjustment(
        { ...adjustment, reasonCode: 'lowercase' }, 250_000,
      )).toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_REASON_INVALID');
    });

    it('refuses non-object evidence', () => {
      expect(() => validateObligationAdjustment(
        { ...adjustment, evidence: ['not', 'an', 'object'] }, 250_000,
      )).toThrow('GROUP_CONTRIBUTION_ADJUSTMENT_EVIDENCE_INVALID');
    });

    it('never lets any accepted adjustment leave a negative balance', () => {
      fc.assert(fc.property(
        fc.integer({ min: 1, max: 1_000_000 }),
        fc.integer({ min: -1_000_000, max: 1_000_000 }).filter((d) => d !== 0),
        (owed, delta) => {
          let accepted = true;
          try {
            validateObligationAdjustment({ ...adjustment, deltaMinor: delta }, owed);
          } catch {
            accepted = false;
          }
          if (accepted) expect(owed + delta).toBeGreaterThanOrEqual(0);
        },
      ));
    });
  });

  describe('cycle totals', () => {
    it('derives pending as expected minus received', () => {
      expect(summarizeCycleTotals({ expectedMinor: 500_000, receivedMinor: 200_000 }))
        .toMatchObject({ expectedMinor: 500_000, receivedMinor: 200_000, pendingMinor: 300_000 });
    });

    it('never reports negative pending when receipts exceed expectations', () => {
      expect(summarizeCycleTotals({ expectedMinor: 100_000, receivedMinor: 250_000 }))
        .toMatchObject({ pendingMinor: 0 });
    });

    it('distinguishes every figure the dashboard must show', () => {
      const totals = summarizeCycleTotals({
        expectedMinor: 500_000,
        receivedMinor: 300_000,
        waivedMinor: 50_000,
        writtenOffMinor: 25_000,
        overdueMinor: 150_000,
        reversedMinor: 10_000,
        unreconciledExcessMinor: 5_000,
        refundedExcessMinor: 2_000,
      });
      expect(Object.keys(totals).sort()).toEqual([
        'expectedMinor', 'overdueMinor', 'pendingMinor', 'receivedMinor',
        'refundedExcessMinor', 'reversedMinor', 'unreconciledExcessMinor',
        'waivedMinor', 'writtenOffMinor',
      ]);
    });
  });
});
