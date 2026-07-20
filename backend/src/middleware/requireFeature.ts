import { NextFunction, Response } from 'express';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import { SupabaseFeatureFlagRepository } from '../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../services/featureFlagService.js';
import { FeatureFlagEnvironment } from '../types/featureFlags.js';
import { AuthRequest } from './auth.js';

interface FeatureActor {
  id?: string;
  tenant_id?: string;
  jurisdiction?: string;
}

const service = new FeatureFlagService(new SupabaseFeatureFlagRepository());

const getEnvironment = (): FeatureFlagEnvironment => {
  const environment = process.env.NODE_ENV;
  if (environment === 'production' || environment === 'staging' || environment === 'test') return environment;
  return 'development';
};

export const createRequireFeature = (featureService: Pick<FeatureFlagService, 'evaluate'>) => (key: string) => {
  if (!FEATURE_FLAGS.has(key)) throw new Error(`Feature flag is not registered: ${key}`);

  return async (req: AuthRequest, res: Response, next: NextFunction) => {
    const actor = (req.user ?? {}) as FeatureActor;
    const decision = await featureService.evaluate(key, {
      environment: getEnvironment(),
      actorId: actor.id,
      tenantId: actor.tenant_id,
      jurisdiction: actor.jurisdiction,
    });

    res.setHeader('X-Feature-Decision', decision.source);
    if (!decision.enabled) {
      return res.status(503).json({
        success: false,
        error: 'FEATURE_DISABLED',
        feature: key,
        message: 'This capability is not currently enabled for your organization.',
      });
    }

    res.locals.feature = decision;
    next();
  };
};

export const requireFeature = createRequireFeature(service);
