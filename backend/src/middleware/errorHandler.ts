import { Request, Response, NextFunction } from 'express';
import multer from 'multer';
import { backendConfiguration } from '../config/environment.js';

export interface AppError extends Error {
  statusCode?: number;
  code?: string;
  details?: unknown;
  isOperational?: boolean;
}

export const createError = (message: string, statusCode = 500, code?: string): AppError => {
  const error: AppError = new Error(message);
  error.statusCode = statusCode;
  error.code = code;
  error.isOperational = true;
  return error;
};

const statusCodeName: Record<number, string> = {
  400: 'BAD_REQUEST',
  401: 'AUTHENTICATION_REQUIRED',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  422: 'VALIDATION_ERROR',
  429: 'RATE_LIMITED',
  500: 'INTERNAL_SERVER_ERROR',
  503: 'SERVICE_UNAVAILABLE',
};

const errorCode = (error: AppError, statusCode: number): string => {
  const candidate = error.code?.trim().toUpperCase();
  return candidate && /^[A-Z][A-Z0-9_]{2,63}$/.test(candidate)
    ? candidate
    : (statusCodeName[statusCode] ?? 'REQUEST_FAILED');
};

const publicMessage = (error: AppError, statusCode: number): string => (
  statusCode >= 500 && !error.isOperational
    ? 'Internal Server Error'
    : (error.message || statusCodeName[statusCode] || 'Request failed')
);

export const errorHandler = (
  err: AppError | any,
  req: Request,
  res: Response,
  next: NextFunction
) => {
  // Handle Multer errors
  if (err instanceof multer.MulterError) {
    let message = 'File upload error';
    let code = 'FILE_UPLOAD_ERROR';
    const statusCode = 400;

    switch (err.code) {
      case 'LIMIT_FILE_SIZE':
        code = 'FILE_TOO_LARGE';
        message = 'File too large. Maximum size is 5MB per image.';
        break;
      case 'LIMIT_FILE_COUNT':
        code = 'TOO_MANY_FILES';
        message = 'Too many files. Maximum 5 images allowed.';
        break;
      case 'LIMIT_UNEXPECTED_FILE':
        code = 'UNEXPECTED_UPLOAD_FIELD';
        message = 'Unexpected field in file upload.';
        break;
      default:
        message = err.message;
    }

    console.error(`Multer Error: ${message}`);
    return res.status(statusCode).json({
      success: false,
      error: message,
      code,
      message,
      correlationId: req.correlationId,
    });
  }

  // Handle other errors
  const statusCode = err.statusCode || 500;
  const message = publicMessage(err, statusCode);
  const code = errorCode(err, statusCode);
  const details = statusCode < 500 || err.isOperational
    ? err.details
    : undefined;

  console.error(`Error ${statusCode}: ${message}`, err.stack);

  res.status(statusCode).json({
    success: false,
    error: message,
    code,
    message,
    correlationId: req.correlationId,
    ...(details !== undefined && { details }),
    ...(backendConfiguration.nodeEnv === 'development' && { stack: err.stack }),
  });
};

export const notFound = (req: Request, res: Response, next: NextFunction) => {
  const error = createError(`Route ${req.originalUrl} not found`, 404, 'ROUTE_NOT_FOUND');
  next(error);
};

export const asyncHandler = (fn: Function) => (req: Request, res: Response, next: NextFunction) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};
