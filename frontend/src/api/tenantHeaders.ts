export const getActiveOrganizationId = (): string | null => {
  try {
    const stored = localStorage.getItem('organization-storage');
    if (!stored) return null;
    return JSON.parse(stored).state?.activeOrganizationId || null;
  } catch {
    return null;
  }
};

export const getTenantHeaders = (token?: string | null, json = false): Record<string, string> => {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const organizationId = getActiveOrganizationId();
  if (organizationId) headers['X-Organization-ID'] = organizationId;
  if (json) headers['Content-Type'] = 'application/json';
  return headers;
};
