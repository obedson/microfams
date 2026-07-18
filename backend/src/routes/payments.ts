import { Router, Response } from 'express';
import { initializePayment, verifyPayment } from '../controllers/paymentController.js';
import { authenticateToken } from '../middleware/auth.js';
import { paymentLimiter } from '../middleware/rateLimiter.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { resolveTenant, TenantRequest } from '../middleware/tenant.js';
import { supabase } from '../utils/supabase.js';

const router = Router();

router.post('/initialize', authenticateToken, resolveTenant, requireFeature('financial.payments.accept_new'), paymentLimiter, initializePayment);
router.get('/verify/:reference', requireFeature('financial.payments.service_existing'), verifyPayment);

router.post('/initialize-group', authenticateToken, resolveTenant, requireFeature('financial.payments.accept_new'), async (req: TenantRequest, res: Response) => {
  const { member_id } = req.body;
  if (!member_id) return res.status(400).json({ success: false, error: 'Group member is required' });

  try {
    const { data: member, error } = await supabase
      .from('group_members')
      .select('id, group_id, groups!inner(organization_id)')
      .eq('id', member_id)
      .eq('user_id', req.user?.id)
      .eq('groups.organization_id', req.tenant!.id)
      .single();

    if (error || !member) return res.status(404).json({ success: false, error: 'Group membership not found' });

    const reference = `GRP-${member.id}-${Date.now()}`;
    const { error: updateError } = await supabase
      .from('group_members')
      .update({ payment_reference: reference })
      .eq('id', member.id);

    if (updateError) throw updateError;
    return res.json({ success: true, reference });
  } catch (error) {
    return res.status(500).json({ success: false, error: 'Failed to initialize group payment' });
  }
});

export default router;
