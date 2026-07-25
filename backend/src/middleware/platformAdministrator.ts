import { NextFunction, Response } from 'express';
import {
  PlatformAdministrationService,
  platformAdministrationService,
} from '../domains/platform/platformAdministrationService.js';
import { AuthRequest } from './auth.js';

export const createRequirePlatformAdministrator = (
  service: Pick<PlatformAdministrationService, 'isAuthorized'>,
) => async (req: AuthRequest, res: Response, next: NextFunction) => {
  if (!req.user?.id) {
    return res.status(401).json({ success: false, error: 'AUTHENTICATION_REQUIRED' });
  }

  try {
    if (!await service.isAuthorized(req.user.id)) {
      return res.status(403).json({
        success: false,
        error: 'PLATFORM_ADMINISTRATOR_REQUIRED',
      });
    }
    next();
  } catch {
    return res.status(503).json({
      success: false,
      error: 'PLATFORM_AUTHORIZATION_UNAVAILABLE',
    });
  }
};

export const requirePlatformAdministrator = createRequirePlatformAdministrator(
  platformAdministrationService,
);
