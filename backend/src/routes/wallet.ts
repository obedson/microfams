import { Router } from 'express';
import { walletController } from '../controllers/walletController.js';
import { authenticateToken } from '../middleware/auth.js';
import { rateLimit } from 'express-rate-limit';
import { requireFeature } from '../middleware/requireFeature.js';
import { resolveTenant } from '../middleware/tenant.js';

const router = Router();

// Dedicated rate limiter for wallet mutations - Fixed IPv6 issue
const walletLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10, // 10 requests per user
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many wallet requests, please try again later' }
});

// All wallet routes require authentication
router.use(authenticateToken as any);
router.use(resolveTenant);

// Individual wallet routes
router.get('/', requireFeature('financial.wallets.read'), walletController.getWallet);
router.get('/transactions/:id', requireFeature('financial.wallets.read'), walletController.getTransaction);
router.post('/p2p/lookup', requireFeature('financial.wallets.read'), walletLimiter, walletController.lookupRecipient);
router.post('/p2p', requireFeature('financial.wallets.transact'), walletLimiter, walletController.initiateP2P);
router.post('/withdraw', requireFeature('financial.wallets.transact'), requireFeature('financial.payouts.create'), walletLimiter, walletController.previewWithdrawal);
router.post('/withdraw/confirm', requireFeature('financial.wallets.transact'), requireFeature('financial.payouts.create'), walletLimiter, walletController.confirmWithdrawal);
router.post('/withdraw/:requestId/sync', requireFeature('financial.payouts.service_existing'), walletLimiter, walletController.syncWithdrawal);
router.get('/withdraw/:id/status', requireFeature('financial.payouts.service_existing'), walletController.getWithdrawalStatus);

// Group wallet routes
router.get('/groups/:id', requireFeature('financial.wallets.read'), walletController.getGroupWallet);
router.post('/groups/:id/withdraw', requireFeature('financial.wallets.transact'), requireFeature('financial.payouts.create'), walletLimiter, walletController.initiateGroupWithdrawal);
router.get('/groups/:id/withdraw/:requestId', requireFeature('financial.wallets.read'), walletController.getGroupWithdrawalRequest);
router.post('/groups/:id/withdraw/:requestId/approve', requireFeature('financial.wallets.transact'), requireFeature('financial.payouts.create'), walletLimiter, walletController.castApprovalVote);

export default router;
