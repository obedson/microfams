import { apiClient } from './client';

export interface InventoryItem {
  id: string;
  organizationId: string;
  name: string;
  sku: string | null;
  unit: string;
  quantityMinor: number;
  reorderLevelMinor: number;
  metadata: Record<string, unknown>;
}

export const inventoryApi = {
  list: () => apiClient.get<{ success: boolean; data: InventoryItem[] }>('/inventory'),
  create: (data: { name: string; sku?: string; unit: string; reorderLevelMinor?: number }) =>
    apiClient.post<{ success: boolean; data: InventoryItem }>('/inventory', data),
  move: (id: string, data: { quantityMinor: number; reason: string; idempotencyKey: string }) =>
    apiClient.post<{ success: boolean; data: InventoryItem }>(`/inventory/${id}/movements`, data),
};
