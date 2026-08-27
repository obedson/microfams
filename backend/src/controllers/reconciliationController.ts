import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { ReconciliationService, reconciliationService } from '../domains/financial/reconciliationService.js';

const investigationSchema = Joi.object({ reason: Joi.string().min(10).max(500).required() });
const resolutionSchema = Joi.object({
  resolutionType: Joi.string().valid('matched_evidence', 'provider_correction', 'compensating_adjustment', 'writeoff').required(),
  resolutionReason: Joi.string().min(10).max(500).required(), evidenceReference: Joi.string().min(1).max(500).required(),
  compensatingJournalEntryId: Joi.string().uuid().optional(), idempotencyKey: Joi.string().min(8).max(160).required(),
});
const decisionSchema = Joi.object({ approve: Joi.boolean().required(), decisionReason: Joi.string().min(10).max(500).required() });

// Maker-checker resolution and write-off API; the database validates immutable evidence and compensating journals.
export class ReconciliationController {
  constructor(private readonly service: ReconciliationService = reconciliationService) {}
  startInvestigation = async (req: TenantRequest, res: Response) => {
    const { error, value } = investigationSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_RECONCILIATION_INVESTIGATION' });
    try { return res.status(200).json(await this.service.startExceptionInvestigation({
      organizationId: req.tenant!.id, exceptionId: req.params.exceptionId, actorId: req.user!.id, reason: value.reason,
    })); } catch { return res.status(409).json({ success: false, error: 'RECONCILIATION_INVESTIGATION_REJECTED' }); }
  };
  requestResolution = async (req: TenantRequest, res: Response) => {
    const { error, value } = resolutionSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_RECONCILIATION_RESOLUTION' });
    try { return res.status(201).json(await this.service.requestExceptionResolution({
      organizationId: req.tenant!.id, exceptionId: req.params.exceptionId, actorId: req.user!.id, ...value,
    })); } catch { return res.status(409).json({ success: false, error: 'RECONCILIATION_RESOLUTION_REJECTED' }); }
  };
  decideResolution = async (req: TenantRequest, res: Response) => {
    const { error, value } = decisionSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'INVALID_RECONCILIATION_DECISION' });
    try { return res.status(200).json(await this.service.decideExceptionResolution({
      organizationId: req.tenant!.id, resolutionRequestId: req.params.requestId, actorId: req.user!.id, ...value,
    })); } catch { return res.status(409).json({ success: false, error: 'RECONCILIATION_DECISION_REJECTED' }); }
  };
}
export const reconciliationController = new ReconciliationController();
