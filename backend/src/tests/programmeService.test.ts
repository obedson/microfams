import { ProgrammeService } from '../domains/institutional/programmeService.js';
describe('ProgrammeService', () => {
  it('rejects blank programme names before persistence', async () => {
    await expect(new ProgrammeService().create('org', { name: ' ' })).rejects.toThrow('PROGRAMME_NAME_REQUIRED');
  });
});
