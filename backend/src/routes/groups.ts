import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { validate } from '../middleware/validate.js';
import { createGroupSchema } from '../utils/validation.js';
import { GroupModel } from '../models/Group.js';
import { Response } from 'express';
import supabase from '../utils/supabase.js';
import { requireTenantPermission, resolveTenant, TenantRequest } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { groupDocumentAccessController } from '../controllers/groupDocumentAccessController.js';

const router = Router();
const documentAccessLimiter=rateLimit({windowMs:15*60*1000,max:60,standardHeaders:true,legacyHeaders:false,message:{success:false,error:'TOO_MANY_GROUP_DOCUMENT_ACCESS_REQUESTS'}});

router.get('/search', async (req: TenantRequest, res: Response, next) => {
  try {
    const { state_id, lga_id } = req.query;
    const groups = await GroupModel.findPublicNearby(
      state_id as string, lga_id as string,
    );
    res.json(groups);
  } catch (error) {
    next(error);
  }
});

router.get(
  '/can-create',
  authenticateToken,
  resolveTenant,
  async (req: TenantRequest, res: Response, next) => {
    try {
      const result = await GroupModel.canCreateGroup(req.user.id);
      res.json(result);
    } catch (error) {
      next(error);
    }
  },
);

router.get('/:id', async (req: TenantRequest, res: Response, next) => {
  try {
    const group = await GroupModel.findPublicById(req.params.id);
    if (!group) return res.status(404).json({ error: 'Group not found' });
    res.json(group);
  } catch (error) {
    next(error);
  }
});

router.use(authenticateToken as any);

router.use(resolveTenant);
router.post('/:groupId/documents/versions/:versionId/download-url',requireFeature('groups.documents.download'),requireTenantPermission('groups.read'),documentAccessLimiter,groupDocumentAccessController.issue);

router.post(
  '/',
  requireFeature('groups.membership.manage'),
  validate(createGroupSchema),
  async (req: TenantRequest, res: Response, next) => {
  try {
    const { canCreate, conditions } = await GroupModel.canCreateGroup(req.user.id);
    if (!canCreate) {
      return res.status(403).json({ 
        error: 'You do not meet the requirements to create a group.',
        conditions
      });
    }

    const { payment_reference, ...groupData } = req.body;
    
    const group = await GroupModel.createWithPayment(
      { ...groupData, creator_id: req.user.id },
      req.user.id,
      req.tenant!.id,
      payment_reference
    );
    
    res.status(201).json({
      success: true,
      message: 'Group draft created. Adopt a constitution and fill required offices to activate it.',
      group
    });
  } catch (error: any) {
    console.error('Group creation error:', error);
    
    // Handle specific errors
    if (error.message?.includes('already used')) {
      return res.status(400).json({ error: 'This payment reference has already been used' });
    }
    if (error.message?.includes('verification failed')) {
      return res.status(400).json({ error: 'Payment verification failed. Please try again.' });
    }
    if (error.message?.includes('less than entry fee')) {
      return res.status(400).json({ error: error.message });
    }
    
    res.status(500).json({ error: error.message || 'Failed to create group' });
  }
  },
);

router.get('/:id/members', async (req: TenantRequest, res: Response, next) => {
  try {
    const members = await GroupModel.getMembers(req.params.id, req.tenant!.id);
    res.json(members);
  } catch (error) {
    next(error);
  }
});

router.get('/:id/membership-status', async (req: TenantRequest, res: Response, next) => {
  try {
    const { data, error } = await supabase
      .from('group_members')
      .select('id, status, state_version, payment_status, amount_paid, groups!inner(organization_id)')
      .eq('group_id', req.params.id)
      .eq('user_id', req.user.id)
      .eq('groups.organization_id', req.tenant!.id)
      .maybeSingle();
    
    if (error) {
      console.error('Membership check error:', error);
      return res.json({ isMember: false });
    }
    
    if (!data) {
      return res.json({ isMember: false });
    }
    
    res.json({ isMember: true, ...data });
  } catch (error) {
    console.error('Membership status error:', error);
    res.json({ isMember: false });
  }
});

export default router;
