import { Router } from 'express';
import { authenticateToken, requireRole, AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import { logAudit } from '../utils/audit.js';
import { getSecurityAlerts, setupMFA, verifyMFA } from '../controllers/adminController.js';

const router = Router();

// Admin only routes (MFA setup is available to all authenticated users)
router.post('/mfa/setup', authenticateToken, setupMFA);
router.post('/mfa/verify', authenticateToken, verifyMFA);

router.use(authenticateToken);
router.use(requireRole(['admin']));

// Get dashboard stats
router.get('/stats', async (req: AuthRequest, res) => {
  try {
    const [users, properties, bookings, revenue] = await Promise.all([
      supabase.from('users').select('id', { count: 'exact', head: true }),
      supabase.from('properties').select('id', { count: 'exact', head: true }),
      supabase.from('bookings').select('id', { count: 'exact', head: true }),
      supabase.from('bookings').select('total_amount').eq('payment_status', 'paid')
    ]);

    const totalRevenue = revenue.data?.reduce((sum, b) => sum + Number(b.total_amount), 0) || 0;

    res.json({
      totalUsers: users.count || 0,
      totalProperties: properties.count || 0,
      totalBookings: bookings.count || 0,
      totalRevenue
    });
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch stats' });
  }
});

// Get all users
router.get('/users', async (req: AuthRequest, res) => {
  try {
    const { data, error } = await supabase
      .from('users')
      .select('id, email, name, role, created_at')
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch users' });
  }
});

// Suspend user
router.post('/users/:id/suspend', async (req: AuthRequest, res) => {
  try {
    const { id } = req.params;
    const { reason } = req.body;

    await supabase
      .from('users')
      .update({ is_suspended: true })
      .eq('id', id);

    await logAudit({
      user_id: req.user.id,
      action: 'user.suspend',
      resource_type: 'user',
      resource_id: id,
      details: { reason },
      ip_address: req.ip
    });

    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to suspend user' });
  }
});

// Get security alerts
router.get('/security-alerts', getSecurityAlerts);

// Get audit logs
router.get('/audit-logs', async (req: AuthRequest, res) => {
  try {
    const { data, error } = await supabase
      .from('audit_logs')
      .select('*, users(name, email)')
      .order('created_at', { ascending: false })
      .limit(100);

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch audit logs' });
  }
});

/**
 * Requirement 7.1 - 7.6: Group Admin Role Management
 */
router.put('/groups/:groupId/admin', async (req: AuthRequest, res) => {
  const { groupId } = req.params;
  const { newAdminUserId } = req.body;

  try {
    // 1. Verify new admin is a paid member
    const { data: membership } = await supabase
      .from('group_members')
      .select('id, role')
      .eq('group_id', groupId)
      .eq('user_id', newAdminUserId)
      .eq('payment_status', 'paid')
      .single();

    if (!membership) {
      return res.status(400).json({ error: 'User must be a paid member of the group' });
    }

    // 2. Find current owner
    const { data: currentOwner } = await supabase
      .from('group_members')
      .select('id, user_id')
      .eq('group_id', groupId)
      .eq('role', 'owner')
      .maybeSingle();

    // 3. Swap roles
    if (currentOwner) {
      await supabase
        .from('group_members')
        .update({ role: 'member' })
        .eq('id', currentOwner.id);
    }

    await supabase
      .from('group_members')
      .update({ role: 'owner' })
      .eq('id', membership.id);

    await logAudit({
      user_id: req.user.id,
      action: 'group.admin_change',
      resource_type: 'group',
      resource_id: groupId,
      details: { newAdminUserId, previousAdminUserId: currentOwner?.user_id },
      ip_address: req.ip
    });

    res.json({ success: true });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
});

router.delete('/groups/:groupId/admin', async (req: AuthRequest, res) => {
  const { groupId } = req.params;

  try {
    const { data: currentOwner, error } = await supabase
      .from('group_members')
      .select('id')
      .eq('group_id', groupId)
      .eq('role', 'owner')
      .maybeSingle();

    if (!currentOwner) {
      return res.status(404).json({ error: 'Group currently has no owner' });
    }

    await supabase
      .from('group_members')
      .update({ role: 'member' })
      .eq('id', currentOwner.id);

    res.json({ success: true });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
});

export default router;
