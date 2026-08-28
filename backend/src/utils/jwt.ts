import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { backendConfiguration } from '../config/environment.js';

export const generateToken = (payload: object): string => {
  return jwt.sign(payload, backendConfiguration.jwt.secret, { expiresIn: '15m' });
};

export const generateRefreshToken = (): string => {
  return crypto.randomBytes(40).toString('hex');
};

export const verifyToken = (token: string): any => {
  return jwt.verify(token, backendConfiguration.jwt.secret);
};
