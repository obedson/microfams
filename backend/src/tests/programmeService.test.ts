import { ProgrammeService } from '../domains/institutional/programmeService.js';
describe('ProgrammeService', () => {
  it('rejects blank programme names before persistence', async () => {
    await expect(new ProgrammeService().create('org', { name: ' ' })).rejects.toThrow('PROGRAMME_NAME_REQUIRED');
  });
  it('rejects invalid cohort date ranges before persistence', async () => { await expect(new ProgrammeService().createCohort('org', 'programme', { name: 'Batch 1', startsOn: '2026-05-02', endsOn: '2026-05-01' })).rejects.toThrow('COHORT_DATE_RANGE_INVALID'); });
  it('rejects blank benefit names before persistence', async () => { await expect(new ProgrammeService().createBenefit('org', 'programme', { name: ' ' })).rejects.toThrow('BENEFIT_NAME_REQUIRED'); });
});
