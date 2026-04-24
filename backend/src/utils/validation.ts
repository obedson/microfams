import Joi from 'joi';

// Group validation schemas
export const createGroupSchema = Joi.object({
  name: Joi.string().min(3).max(100).required(),
  description: Joi.string().max(500).required(),
  category: Joi.string().valid('poultry', 'cattle', 'fish', 'crops', 'mixed').required(),
  state_id: Joi.string().uuid().required(),
  lga_id: Joi.string().uuid().required(),
  entry_fee: Joi.number().min(500).max(10000).required(),
  max_members: Joi.number().min(5).max(100).optional(),
  payment_reference: Joi.string().required(),
});

export const joinGroupSchema = Joi.object({
  payment_reference: Joi.string().required(),
  amount: Joi.number().min(500).required(),
});

// Contribution validation schemas
export const contributionSettingsSchema = Joi.object({
  contribution_enabled: Joi.boolean().required(),
  contribution_amount: Joi.number().min(100).max(100000).required(),
  payment_day: Joi.number().min(1).max(28).required(),
  grace_period_days: Joi.number().min(0).max(7).required(),
  late_penalty_type: Joi.string().valid('fixed', 'percentage').required(),
  late_penalty_amount: Joi.number().min(0).required(),
  auto_suspend_after: Joi.number().min(1).max(12).required(),
  auto_expel_after: Joi.number().min(2).max(12).required(),
});

export const makePaymentSchema = Joi.object({
  amount: Joi.number().min(0).required(),
  payment_reference: Joi.string().required(),
});

// Auth validation schemas
export const registerSchema = Joi.object({
  name: Joi.string().min(2).max(100).required(),
  email: Joi.string().email().required(),
  password: Joi.string().min(6).required(),
  role: Joi.string().valid('farmer', 'owner').required(),
  phone: Joi.string().optional(),
  referred_by: Joi.string().optional(),
});

export const loginSchema = Joi.object({
  email: Joi.string().email().required(),
  password: Joi.string().required(),
});

// Property validation schemas
export const createPropertySchema = Joi.object({
  title: Joi.string().min(5).max(200).required(),
  description: Joi.string().min(20).max(2000).required(),
  property_type: Joi.string().valid('land', 'barn', 'pen', 'pond', 'greenhouse').required(),
  location: Joi.string().required(),
  price_per_month: Joi.number().min(1000).required(),
  size: Joi.string().required(),
  amenities: Joi.array().items(Joi.string()).optional(),
});
