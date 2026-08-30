import { AsyncLocalStorage } from 'node:async_hooks';

interface CorrelationContext { correlationId: string; }
const storage = new AsyncLocalStorage<CorrelationContext>();

export const withCorrelationContext = <T>(
  correlationId: string,
  callback: () => T,
): T => storage.run({ correlationId }, callback);

export const currentCorrelationId = (): string | undefined =>
  storage.getStore()?.correlationId;