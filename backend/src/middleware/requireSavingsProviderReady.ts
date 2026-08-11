import { NextFunction, Response } from 'express';
import {
  SavingsProviderActivationGuard,
  SavingsProviderConfigurationError,
  savingsProviderActivationGuard,
} from '../domains/financial/savingsProviderCertificationService.js';
import { TenantRequest } from './tenant.js';

export const createRequireSavingsProviderReady = (
  guard: Pick<SavingsProviderActivationGuard, 'assertNewExposureReady'>,
) => async (req: TenantRequest, res: Response, next: NextFunction) => {
  try {
    await guard.assertNewExposureReady(req.tenant!.id, req.user!.id);
    next();
  } catch (error) {
    if (error instanceof SavingsProviderConfigurationError) {
      return res.status(503).json({
        success: false,
        error: error.code,
        message: 'Savings acquisition is unavailable until provider certification and activation are complete.',
        missing: error.missing,
      });
    }
    return res.status(503).json({
      success: false,
      error: 'SAVINGS_PROVIDER_READINESS_UNAVAILABLE',
      message: 'Savings provider readiness could not be verified.',
    });
  }
};

export const requireSavingsProviderReady = createRequireSavingsProviderReady(savingsProviderActivationGuard);
