import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { SupabaseOrganizationRepository } from '../repositories/organizationRepository.js';
import { OrganizationService } from '../services/organizationService.js';

const service = new OrganizationService(new SupabaseOrganizationRepository());

const createSchema = Joi.object({
  name: Joi.string().trim().min(2).max(160).required(),
  legalName: Joi.string().trim().max(200).optional(),
  slug: Joi.string().lowercase().pattern(/^[a-z0-9][a-z0-9-]{1,62}$/).required(),
  type: Joi.string().valid('farm_business', 'cooperative', 'ngo', 'government_program', 'agribusiness').required(),
  jurisdiction: Joi.string().uppercase().length(2).default('NG'),
  defaultCurrency: Joi.string().uppercase().length(3).default('NGN'),
  timezone: Joi.string().max(100).default('Africa/Lagos'),
});

const brandingSchema = Joi.object({
  displayName: Joi.string().trim().max(160).allow(null),
  logoUrl: Joi.string().uri({ scheme: ['https'] }).allow(null),
  primaryColor: Joi.string().pattern(/^#[0-9A-Fa-f]{6}$/).allow(null),
  secondaryColor: Joi.string().pattern(/^#[0-9A-Fa-f]{6}$/).allow(null),
  supportEmail: Joi.string().email().allow(null),
  supportPhone: Joi.string().pattern(/^[0-9+()\-\s]{7,24}$/).allow(null),
  customDomain: Joi.string().hostname().allow(null),
}).min(1);

export const organizationController = {
  async list(req: TenantRequest, res: Response) {
    try {
      const memberships = await service.listForUser(req.user!.id);
      return res.json({ success: true, data: memberships });
    } catch {
      return res.status(503).json({ success: false, error: 'ORGANIZATION_SERVICE_UNAVAILABLE' });
    }
  },

  async create(req: TenantRequest, res: Response) {
    const { error, value } = createSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'VALIDATION_ERROR', details: error.details.map((item) => item.message) });
    try {
      const membership = await service.create(req.user!.id, value);
      return res.status(201).json({ success: true, data: membership });
    } catch {
      return res.status(409).json({ success: false, error: 'ORGANIZATION_CREATE_FAILED' });
    }
  },

  async current(req: TenantRequest, res: Response) {
    try {
      const branding = await service.getBranding(req.tenant!.id);
      return res.json({ success: true, data: { organization: req.tenant, branding } });
    } catch {
      return res.status(503).json({ success: false, error: 'ORGANIZATION_SERVICE_UNAVAILABLE' });
    }
  },

  async updateBranding(req: TenantRequest, res: Response) {
    const { error, value } = brandingSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'VALIDATION_ERROR', details: error.details.map((item) => item.message) });
    try {
      const branding = await service.updateBranding(req.tenant!.id, req.user!.id, value);
      return res.json({ success: true, data: branding });
    } catch {
      return res.status(503).json({ success: false, error: 'ORGANIZATION_SERVICE_UNAVAILABLE' });
    }
  },
};
