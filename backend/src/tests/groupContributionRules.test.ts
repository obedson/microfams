import fc from 'fast-check';
import {
  GROUP_CONTRIBUTION_PRODUCT_CLASSES,
  normalizeContributionProposalPayload,
  ownershipForProductClass,
} from '../domains/groups/contributionRules.js';

describe('group contribution rules', () => {
  const projectId = '00000000-0000-4000-8000-000000000801';
  const productId = '00000000-0000-4000-8000-000000000802';

  const base = {
    action: 'adopt',
    productKey: 'monthly_due',
    displayName: 'Monthly due',
    purpose: 'Cover monthly governance and operating costs',
    amountMinor: 250_000,
    currency: 'NGN',
    permittedRails: ['paystack', 'bank_transfer'],
    refundRuleCode: 'NO_REFUND',
    revenueAccountCode: 'DUES_INCOME',
  };

  it('derives ownership from the product class rather than the caller', () => {
    expect(ownershipForProductClass('membership_fee')).toBe('group_income');
    expect(ownershipForProductClass('periodic_due')).toBe('group_income');
    expect(ownershipForProductClass('member_capital')).toBe('member_attributed');
    expect(ownershipForProductClass('savings')).toBe('member_attributed');
    expect(ownershipForProductClass('project_subscription')).toBe('project_restricted');
  });

  it('assigns exactly one ownership to every classified product', () => {
    fc.assert(fc.property(
      fc.constantFrom(...GROUP_CONTRIBUTION_PRODUCT_CLASSES),
      (productClass) => {
        expect(['group_income', 'member_attributed', 'project_restricted'])
          .toContain(ownershipForProductClass(productClass));
      },
    ));
  });

  it('rejects an unclassified product', () => {
    expect(() => ownershipForProductClass('group_fund_balance'))
      .toThrow('GROUP_CONTRIBUTION_CLASS_INVALID');
  });

  it('normalizes an adopt payload to the database contract', () => {
    expect(normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due',
    })).toEqual({
      action: 'adopt',
      product_class: 'periodic_due',
      product_key: 'monthly_due',
      display_name: 'Monthly due',
      purpose: 'Cover monthly governance and operating costs',
      amount_minor: 250_000,
      currency: 'NGN',
      permitted_rails: ['paystack', 'bank_transfer'],
      payer_eligibility: {},
      due_schedule: {},
      refund_rule_code: 'NO_REFUND',
      withdrawal_rule_code: null,
      loss_allocation_rule_code: null,
      revenue_account_code: 'DUES_INCOME',
      project_id: null,
    });
  });

  it('requires a product id for a supersede and no product key', () => {
    const result = normalizeContributionProposalPayload('contribution_rule', {
      ...base, action: 'supersede', productClass: 'periodic_due', productId,
    });
    expect(result.product_id).toBe(productId);
    expect(result.product_key).toBeUndefined();
  });

  it('requires withdrawal and loss rules for member-attributed money', () => {
    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'member_capital',
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');

    expect(normalizeContributionProposalPayload('contribution_rule', {
      ...base,
      productClass: 'savings',
      withdrawalRuleCode: 'NOTICE_30_DAYS',
      lossAllocationRuleCode: 'PRO_RATA',
    })).toMatchObject({
      product_class: 'savings',
      withdrawal_rule_code: 'NOTICE_30_DAYS',
      loss_allocation_rule_code: 'PRO_RATA',
    });
  });

  it('refuses withdrawal terms on group income', () => {
    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due', withdrawalRuleCode: 'NOTICE_30_DAYS',
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');
  });

  it('requires a named project for restricted funding and forbids one elsewhere', () => {
    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'project_subscription',
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');

    expect(normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'project_subscription', projectId,
    })).toMatchObject({ product_class: 'project_subscription', project_id: projectId });

    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due', projectId,
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');
  });

  it('rejects unsupported and duplicated payment rails', () => {
    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due', permittedRails: ['western_union'],
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');

    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due', permittedRails: ['paystack', 'paystack'],
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');

    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'periodic_due', permittedRails: [],
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');
  });

  it('rejects a non-integer, negative, or oversized amount', () => {
    fc.assert(fc.property(
      fc.oneof(
        fc.integer({ min: -1_000_000, max: -1 }),
        fc.integer({ min: 100_000_000_001, max: 200_000_000_000 }),
        fc.constant(1.5),
      ),
      (amountMinor) => {
        expect(() => normalizeContributionProposalPayload('contribution_rule', {
          ...base, productClass: 'periodic_due', amountMinor,
        })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');
      },
    ));
  });

  it('rejects an unknown action and an unknown class', () => {
    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, action: 'rewrite', productClass: 'periodic_due',
    })).toThrow('GROUP_CONTRIBUTION_PAYLOAD_INVALID');

    expect(() => normalizeContributionProposalPayload('contribution_rule', {
      ...base, productClass: 'group_fund_balance',
    })).toThrow('GROUP_CONTRIBUTION_CLASS_INVALID');
  });

  it('leaves unrelated proposal payloads intact', () => {
    expect(normalizeContributionProposalPayload('ordinary', { note: 'agenda' }))
      .toEqual({ note: 'agenda' });
  });
});
