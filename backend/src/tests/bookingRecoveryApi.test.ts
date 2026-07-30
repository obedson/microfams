import { jest } from '@jest/globals';
import {
  decideBookingRecoveryAction,
  proposeBookingRecoveryAction,
  proposeBookingRecoveryOffsetAgreement,
} from '../controllers/bookingRecoveryController.js';
import { bookingRecoveryService } from '../services/bookingRecoveryService.js';

jest.mock('../services/bookingRecoveryService.js', () => ({
  BookingRecoveryError: class MockError extends Error {
    constructor(readonly code: string, readonly status: number) { super(code); }
  },
  bookingRecoveryService: {
    proposeOffsetAgreement: jest.fn(),
    decideOffsetAgreement: jest.fn(),
    proposeAction: jest.fn(),
    decideAction: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};
const organizationId = '00000000-0000-4000-8000-000000000981';
const providerOrganizationId = '00000000-0000-4000-8000-000000000982';
const actorId = '00000000-0000-4000-8000-000000000983';
const caseId = '00000000-0000-4000-8000-000000000984';
const actionId = '00000000-0000-4000-8000-000000000985';
const agreementId = '00000000-0000-4000-8000-000000000986';
const releaseId = '00000000-0000-4000-8000-000000000987';

describe('booking recovery API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('proposes an offset agreement using the authenticated tenant identity', async () => {
    (bookingRecoveryService.proposeOffsetAgreement as jest.Mock)
      .mockResolvedValue({ id: agreementId } as never);
    const res = response();
    await proposeBookingRecoveryOffsetAgreement({
      headers: { 'idempotency-key': 'offset-agreement-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        organization_id: 'attacker',
        provider_organization_id: providerOrganizationId,
        currency: 'NGN',
        maximum_amount_minor: 50_000,
        effective_from: '2026-07-30T00:00:00.000Z',
        effective_until: '2026-08-30T00:00:00.000Z',
        reason: 'Supplier authorized recovery from future proceeds.',
        evidence_reference: 'agreement://signed/001',
      },
    } as any, res);
    expect(bookingRecoveryService.proposeOffsetAgreement).toHaveBeenCalledWith({
      organizationId,
      providerOrganizationId,
      actorId,
      currency: 'NGN',
      maximumAmountMinor: 50_000,
      effectiveFrom: '2026-07-30T00:00:00.000Z',
      effectiveUntil: '2026-08-30T00:00:00.000Z',
      reason: 'Supplier authorized recovery from future proceeds.',
      evidenceReference: 'agreement://signed/001',
      idempotencyKey: 'offset-agreement-001',
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires both approved offset references for a future-settlement action', async () => {
    const res = response();
    await proposeBookingRecoveryAction({
      params: { caseId },
      headers: { 'idempotency-key': 'recovery-action-001' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        method: 'future_settlement_offset',
        amount_minor: 10_000,
        offset_agreement_id: agreementId,
        reason: 'Apply the approved offset against future proceeds.',
        evidence_reference: 'agreement://signed/001',
      },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingRecoveryService.proposeAction).not.toHaveBeenCalled();
  });

  it('accepts integer-money recovery actions without caller tenant overrides', async () => {
    (bookingRecoveryService.proposeAction as jest.Mock)
      .mockResolvedValue({ id: actionId } as never);
    const res = response();
    await proposeBookingRecoveryAction({
      params: { caseId },
      headers: { 'idempotency-key': 'recovery-action-002' },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: {
        organization_id: 'attacker',
        method: 'future_settlement_offset',
        amount_minor: 10_000,
        offset_agreement_id: agreementId,
        settlement_release_id: releaseId,
        reason: 'Apply the approved offset against future proceeds.',
        evidence_reference: 'agreement://signed/001',
      },
    } as any, res);
    expect(bookingRecoveryService.proposeAction).toHaveBeenCalledWith({
      recoveryCaseId: caseId,
      organizationId,
      actorId,
      method: 'future_settlement_offset',
      amountMinor: 10_000,
      offsetAgreementId: agreementId,
      settlementReleaseId: releaseId,
      evidenceReference: 'agreement://signed/001',
      reason: 'Apply the approved offset against future proceeds.',
      idempotencyKey: 'recovery-action-002',
    });
  });

  it('rejects malformed maker-checker decisions before calling the service', async () => {
    const res = response();
    await decideBookingRecoveryAction({
      params: { actionId },
      tenant: { id: organizationId },
      user: { id: actorId },
      body: { approve: 'yes', reason: 'Approve the evidenced recovery action.' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(bookingRecoveryService.decideAction).not.toHaveBeenCalled();
  });
});
