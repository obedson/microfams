import { ProgrammeReportingScopeService } from '../domains/institutional/programmeReportingScopeService.js';

describe('ProgrammeReportingScopeService', () => {
  it('rejects wildcard metrics before persistence', async () => {
    const service = new ProgrammeReportingScopeService();
    await expect(service.request({
      organizationId: 'programme-org',
      actorId: 'actor',
      programmeId: 'programme',
      participatingOrganizationId: 'participant-org',
      purpose: 'Measure aggregate programme outcomes',
      permittedMetrics: ['participants.*'],
      disclosureVersion: 'v1',
      requestEvidence: 'approved disclosure evidence',
      expiresAt: '2027-01-01T00:00:00.000Z',
    })).rejects.toThrow('PROGRAMME_REPORTING_SCOPE_INVALID');
  });

  it('requires consent evidence before granting a scope', async () => {
    const service = new ProgrammeReportingScopeService();
    await expect(service.decide({
      organizationId: 'participant-org',
      actorId: 'owner',
      scopeId: 'scope',
      decision: 'granted',
      reason: 'Approved for aggregate monitoring',
      effectiveAt: '2026-09-01T00:00:00.000Z',
    })).rejects.toThrow('PROGRAMME_REPORTING_SCOPE_DECISION_INVALID');
  });

  it('rejects missing disclosure evidence before persistence', async () => {
    const service = new ProgrammeReportingScopeService();
    await expect(service.request({
      organizationId: 'programme-org',
      actorId: 'actor',
      programmeId: 'programme',
      participatingOrganizationId: 'participant-org',
      purpose: 'Measure aggregate programme outcomes',
      permittedMetrics: ['aggregate.participant_count'],
      disclosureVersion: 'v1',
      requestEvidence: 'short',
      expiresAt: '2027-01-01T00:00:00.000Z',
    })).rejects.toThrow('PROGRAMME_REPORTING_SCOPE_INVALID');
  });

  it('rejects blank revocation reasons before persistence', async () => {
    const service = new ProgrammeReportingScopeService();
    await expect(service.revoke({
      organizationId: 'participant-org',
      actorId: 'owner',
      scopeId: 'scope',
      reason: ' ',
    })).rejects.toThrow('PROGRAMME_REPORTING_SCOPE_REVOCATION_INVALID');
  });
});
