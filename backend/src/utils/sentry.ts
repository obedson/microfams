import * as Sentry from '@sentry/node';
import { Express, ErrorRequestHandler } from 'express';

export const initSentry = (app: Express) => {
  if (!process.env.SENTRY_DSN) {
    console.warn('⚠️  SENTRY_DSN not configured - error tracking disabled');
    return;
  }

  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.NODE_ENV || 'development',
    tracesSampleRate: 1.0,
  });

  app.use(Sentry.Handlers.requestHandler());
  app.use(Sentry.Handlers.tracingHandler());
};

export const sentryErrorHandler: ErrorRequestHandler = Sentry.Handlers.errorHandler();
