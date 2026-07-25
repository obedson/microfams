import { Request, Response } from 'express';
import Joi from 'joi';
import { SuspendedRecoveryError, suspendedAccountRecoveryService } from '../domains/trust/suspendedAccountRecoveryService.js';

const requestSchema = Joi.object({ email: Joi.string().email().max(254).required() });
const tokenSchema = Joi.string().min(40).max(100).required();
const appealSchema = Joi.object({ token: tokenSchema, grounds: Joi.string().trim().min(10).max(4000).required() });
const genericMessage = 'If this account is eligible, a recovery link will be sent to its verified channel.';
const failure = (res: Response, error: unknown) => {
  if (error instanceof SuspendedRecoveryError) return res.status(error.status).json({ success: false, error: error.code });
  return res.status(503).json({ success: false, error: 'RECOVERY_SERVICE_UNAVAILABLE' });
};

export const suspendedAccountRecoveryController = {
  async request(req: Request, res: Response) {
    const { error, value } = requestSchema.validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    await suspendedAccountRecoveryService.request(value.email);
    return res.status(202).json({ success: true, message: genericMessage });
  },
  async inspect(req: Request, res: Response) {
    const { error, value } = tokenSchema.validate(req.query.token);
    if (error) return res.status(400).json({ success: false, error: 'INVALID_RECOVERY_TOKEN' });
    try { return res.json({ success: true, data: await suspendedAccountRecoveryService.inspect(value) }); }
    catch (commandError) { return failure(res, commandError); }
  },
  async fileAppeal(req: Request, res: Response) {
    const { error, value } = appealSchema.validate(req.body, { abortEarly: false, stripUnknown: true });
    if (error) return res.status(400).json({ success: false, error: 'VALIDATION_ERROR' });
    const key = req.header('Idempotency-Key') || '';
    try { return res.status(202).json({ success: true, data: await suspendedAccountRecoveryService.fileAppeal(value.token, value.grounds, key) }); }
    catch (commandError) { return failure(res, commandError); }
  },
};