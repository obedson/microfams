const DEFAULT_ALLOWED_ORIGINS = [
  'http://localhost:3000',
  'http://localhost:3001',
  'https://microfams.vercel.app',
];

const MICROFAMS_VERCEL_PREVIEW = /^https:\/\/microfams-git-[a-z0-9-]+-obedsons-projects\.vercel\.app$/i;

const normalizeOrigin = (value: string): string | null => {
  const trimmed = value.trim();
  if (!trimmed) return null;

  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    return parsed.origin;
  } catch {
    return null;
  }
};

export const configuredCorsOrigins = (value = process.env.CORS_ALLOWED_ORIGINS): Set<string> => {
  const configured = (value ?? '').split(',').map(normalizeOrigin).filter((origin): origin is string => Boolean(origin));
  return new Set([...DEFAULT_ALLOWED_ORIGINS, ...configured]);
};

export const isCorsOriginAllowed = (
  origin: string | undefined,
  configuredOrigins = configuredCorsOrigins(),
): boolean => {
  if (!origin) return true;
  const normalized = normalizeOrigin(origin);
  if (!normalized) return false;
  return configuredOrigins.has(normalized) || MICROFAMS_VERCEL_PREVIEW.test(normalized);
};
