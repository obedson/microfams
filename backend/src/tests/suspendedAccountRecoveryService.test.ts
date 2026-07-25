import { RecoveryDelivery, RecoveryRepository, SuspendedAccountRecoveryService } from '../domains/trust/suspendedAccountRecoveryService.js';

const eligible = { userId: 'u1', email: 'user@example.test', name: 'User', caseId: 'c1' };
const repository = (): jest.Mocked<RecoveryRepository> => ({ findEligible: jest.fn(), issue: jest.fn(), invalidate: jest.fn(), inspect: jest.fn(), fileAppeal: jest.fn() });
const delivery = (): jest.Mocked<RecoveryDelivery> => ({ send: jest.fn() });

describe('SuspendedAccountRecoveryService', () => {
 it('uses an opaque token and never stores or delivers its digest', async () => {
  const repo=repository(), channel=delivery(); repo.findEligible.mockResolvedValue(eligible); repo.issue.mockResolvedValue({tokenId:'t1'});
  await new SuspendedAccountRecoveryService(repo,channel).request(' USER@EXAMPLE.TEST ');
  expect(repo.findEligible).toHaveBeenCalledWith('user@example.test');
  const issued=repo.issue.mock.calls[0][0], sent=channel.send.mock.calls[0][0];
  expect(issued.digest).toMatch(/^[0-9a-f]{64}$/); expect(sent.token).not.toBe(issued.digest); expect(sent.token.length).toBeGreaterThanOrEqual(40);
 });
 it('returns silently for ineligible addresses', async () => {
  const repo=repository(), channel=delivery(); repo.findEligible.mockResolvedValue(null);
  await expect(new SuspendedAccountRecoveryService(repo,channel).request('none@example.test')).resolves.toBeUndefined(); expect(channel.send).not.toHaveBeenCalled();
 });
 it('invalidates a token when delivery fails', async () => {
  const repo=repository(), channel=delivery(); repo.findEligible.mockResolvedValue(eligible); repo.issue.mockResolvedValue({tokenId:'t1'}); channel.send.mockRejectedValue(new Error('down'));
  await new SuspendedAccountRecoveryService(repo,channel).request(eligible.email); expect(repo.invalidate).toHaveBeenCalledWith('t1','DELIVERY_FAILED');
 });
 it('validates appeal grounds and passes a request hash', async () => {
  const repo=repository(), channel=delivery(); repo.fileAppeal.mockResolvedValue({status:'filed'}); const token='A'.repeat(43);
  await new SuspendedAccountRecoveryService(repo,channel).fileAppeal(token,'Material evidence was omitted.','appeal-key-1');
  expect(repo.fileAppeal.mock.calls[0][0]).toMatch(/^[0-9a-f]{64}$/); expect(repo.fileAppeal.mock.calls[0][3]).toMatch(/^[0-9a-f]{64}$/);
 });
});