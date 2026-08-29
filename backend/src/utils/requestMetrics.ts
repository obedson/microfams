export interface RequestMetricSnapshot {
  startedAt: string;
  requests: number;
  failures: number;
  totalDurationMs: number;
  byRoute: Record<string, { requests: number; failures: number; totalDurationMs: number }>;
}
const startedAt = new Date().toISOString();
const byRoute = new Map<string, { requests: number; failures: number; totalDurationMs: number }>();
let requests = 0; let failures = 0; let totalDurationMs = 0;
const routeLabel = (path: string): string => path.split('/').map((segment) => /^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(segment) || /^\d+$/.test(segment) ? ':id' : segment).join('/') || '/';
export const recordRequestMetric = (method: string, path: string, statusCode: number, durationMs: number): void => { const key = `${method.toUpperCase()} ${routeLabel(path)}`; const current = byRoute.get(key) ?? { requests: 0, failures: 0, totalDurationMs: 0 }; current.requests += 1; if (statusCode >= 500) { current.failures += 1; failures += 1; } current.totalDurationMs += durationMs; byRoute.set(key, current); requests += 1; totalDurationMs += durationMs; };
export const requestMetricSnapshot = (): RequestMetricSnapshot => ({ startedAt, requests, failures, totalDurationMs, byRoute: Object.fromEntries([...byRoute.entries()].map(([key, value]) => [key, { ...value }])) });
export const resetRequestMetrics = (): void => { requests = 0; failures = 0; totalDurationMs = 0; byRoute.clear(); };
