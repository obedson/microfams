import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { programmeService } from '../domains/institutional/programmeService.js';

export const programmeController = {
  async list(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await programmeService.list(req.tenant!.id) }); } catch { return res.status(503).json({ success: false, error: 'PROGRAMME_LIST_UNAVAILABLE' }); } },
  async create(req: TenantRequest, res: Response) { try { return res.status(201).json({ success: true, data: await programmeService.create(req.tenant!.id, req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'PROGRAMME_CREATE_FAILED' }); } },
  async listCohorts(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await programmeService.listCohorts(req.tenant!.id, req.params.id) }); } catch { return res.status(503).json({ success: false, error: 'COHORT_LIST_UNAVAILABLE' }); } },
  async listBenefits(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await programmeService.listBenefits(req.tenant!.id, req.params.id) }); } catch { return res.status(503).json({ success: false, error: 'BENEFIT_LIST_UNAVAILABLE' }); } },
  async createCohort(req: TenantRequest, res: Response) { try { return res.status(201).json({ success: true, data: await programmeService.createCohort(req.tenant!.id, req.params.id, req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'COHORT_CREATE_FAILED' }); } },
  async createBenefit(req: TenantRequest, res: Response) { try { return res.status(201).json({ success: true, data: await programmeService.createBenefit(req.tenant!.id, req.params.id, req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'BENEFIT_CREATE_FAILED' }); } },
};
