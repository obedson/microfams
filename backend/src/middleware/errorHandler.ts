import { Request, Response, NextFunction } from 'express';
import multer from 'multer';

export interface AppError extends Error {
  statusCode?: number;
  isOperational?: boolean;
}

export const createError = (message: string, statusCode: number = 500): AppError => {
  const error: AppError = new Error(message);
  error.statusCode = statusCode;
  error.isOperational = true;
  return error;
};

export const errorHandler = (
  err: AppError | any,
  req: Request,
  res: Response,
  next: NextFunction
) => {
  // Handle Multer errors
  if (err instanceof multer.MulterError) {
    let message = 'File upload error';
    let statusCode = 400;

    switch (err.code) {
      case 'LIMIT_FILE_SIZE':
        message = 'File too large. Maximum size is 5MB per image.';
        break;
      case 'LIMIT_FILE_COUNT':
        message = 'Too many files. Maximum 5 images allowed.';
        break;
      case 'LIMIT_UNEXPECTED_FILE':
        message = 'Unexpected field in file upload.';
        break;
      default:
        message = err.message;
    }

    console.error(`Multer Error: ${message}`);
    return res.status(statusCode).json({
      success: false,
      error: message
    });
  }

  // Handle other errors
  const statusCode = err.statusCode || 500;
  const message = err.message || 'Internal Server Error';

  console.error(`Error ${statusCode}: ${message}`, err.stack);

  res.status(statusCode).json({
    success: false,
    error: message,
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
  });
};

export const notFound = (req: Request, res: Response, next: NextFunction) => {
  const error = createError(`Route ${req.originalUrl} not found`, 404);
  next(error);
};

export const asyncHandler = (fn: Function) => (req: Request, res: Response, next: NextFunction) => {
  Promise.resolve(fn(req, res, next)).catch(next);
};
