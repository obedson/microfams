import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { validate } from '../middleware/validate.js';
import { createGroupSchema, joinGroupSchema } from '../utils/validation.js';
import { GroupModel } from '../models/Group.js';
import { WalletService } from '../services/walletService.js';
import { Response } from 'express';
import supabase from '../utils/supabase.js';

const walletService = new WalletService();
const router = Router();

// Rate limiters
const joinGroupLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 5,
  message: { error: 'Too many join attempts, please try again later' }
});

router.get('/search', async (req, res, next) => {
  try {
    const { state_id, lga_id } = req.query;
    const groups = await GroupModel.findNearby(state_id as string, lga_id as string);
    res.json(groups);
  } catch (error) {
    next(error);
  }
});

router.get('/can-create', authenticateToken, async (req: AuthRequest, res: Response, next) => {
  try {
    const result = await GroupModel.canCreateGroup(req.user.id);
    res.json(result);
  } catch (error) {
    next(error);
  }
});

router.get('/:id', async (req, res, next) => {
  try {
    const group = await GroupModel.findById(req.params.id);
    res.json(group);
  } catch (error) {
    next(error);
  }
});

router.post('/', authenticateToken, validate(createGroupSchema), async (req: AuthRequest, res: Response, next) => {
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
      payment_reference
    );
    
    // Provision NUBAN
    try {
      await walletService.provisionGroupNuban(group.id, group.name);
    } catch (nubanError) {
      console.error(`Group NUBAN provisioning failed for group ${group.id}:`, nubanError);
    }
    
    res.status(201).json({ 
      success: true,
      message: 'Group created successfully! You are now a member.',
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
});

router.post('/:id/join', authenticateToken, joinGroupLimiter, validate(joinGroupSchema), async (req: AuthRequest, res: Response, next) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('nin_verified')
      .eq('id', req.user.id)
      .single();

    if (!user?.nin_verified) {
      return res.status(403).json({ error: 'You must verify your NIN before joining a group.' });
    }

    const { payment_reference, amount } = req.body;
    
    const membership = await GroupModel.joinGroup(
      req.params.id, 
      req.user.id, 
      payment_reference,
      amount
    );
    res.json(membership);
  } catch (error: any) {
    if (error.message?.includes('duplicate key') || error.code === '23505') {
      return res.status(400).json({ error: 'You are already a member of this group' });
    }
    res.status(500).json({ error: error.message || 'Failed to join group' });
  }
});

router.post('/confirm-payment/:memberId', authenticateToken, async (req: AuthRequest, res: Response, next) => {
  try {
    const membership = await GroupModel.confirmPayment(req.params.memberId);
    res.json(membership);
  } catch (error) {
    next(error);
  }
});

router.get('/:id/members', async (req, res, next) => {
  try {
    const members = await GroupModel.getMembers(req.params.id);
    res.json(members);
  } catch (error) {
    next(error);
  }
});

router.get('/:id/membership-status', authenticateToken, async (req: AuthRequest, res: Response, next) => {
  try {
    const { data, error } = await supabase
      .from('group_members')
      .select('id, payment_status, amount_paid')
      .eq('group_id', req.params.id)
      .eq('user_id', req.user.id)
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
