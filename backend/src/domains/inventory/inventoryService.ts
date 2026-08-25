import { supabase } from '../../utils/supabase.js';

export type InventoryItem = { id: string; organizationId: string; name: string; sku: string | null; unit: string; quantityMinor: number; reorderLevelMinor: number; metadata: Record<string, unknown> };
const mapItem = (row: any): InventoryItem => ({ id: row.id, organizationId: row.organization_id, name: row.name, sku: row.sku ?? null, unit: row.unit, quantityMinor: Number(row.quantity_minor), reorderLevelMinor: Number(row.reorder_level_minor), metadata: row.metadata ?? {} });

export class InventoryService {
  async list(organizationId: string): Promise<InventoryItem[]> {
    const { data, error } = await supabase.from('inventory_items').select('*').eq('organization_id', organizationId).order('name');
    if (error) throw error;
    return (data ?? []).map(mapItem);
  }
  async create(organizationId: string, input: { name: string; sku?: string; unit: string; reorderLevelMinor?: number; metadata?: Record<string, unknown> }): Promise<InventoryItem> {
    if (!input.name.trim() || !input.unit.trim()) throw new Error('INVENTORY_ITEM_INVALID');
    if (!Number.isInteger(input.reorderLevelMinor ?? 0) || (input.reorderLevelMinor ?? 0) < 0) throw new Error('INVENTORY_REORDER_LEVEL_INVALID');
    const { data, error } = await supabase.from('inventory_items').insert({ organization_id: organizationId, name: input.name.trim(), sku: input.sku?.trim() || null, unit: input.unit.trim(), reorder_level_minor: input.reorderLevelMinor ?? 0, metadata: input.metadata ?? {} }).select('*').single();
    if (error) throw error;
    return mapItem(data);
  }
  async move(organizationId: string, itemId: string, input: { quantityMinor: number; reason: string; idempotencyKey: string }): Promise<InventoryItem> {
    if (!Number.isInteger(input.quantityMinor) || input.quantityMinor === 0 || !input.reason.trim() || !input.idempotencyKey.trim()) throw new Error('INVENTORY_MOVEMENT_INVALID');
    const { data: item, error: itemError } = await supabase.from('inventory_items').select('*').eq('organization_id', organizationId).eq('id', itemId).single();
    if (itemError || !item) throw new Error('INVENTORY_ITEM_NOT_FOUND');
    const next = Number(item.quantity_minor) + input.quantityMinor;
    if (next < 0) throw new Error('INVENTORY_QUANTITY_NEGATIVE');
    const { error: movementError } = await supabase.from('inventory_movements').insert({ organization_id: organizationId, item_id: itemId, quantity_minor: input.quantityMinor, reason: input.reason.trim(), idempotency_key: input.idempotencyKey.trim() });
    if (movementError && movementError.code !== '23505') throw movementError;
    const { data, error } = await supabase.from('inventory_items').update({ quantity_minor: next, updated_at: new Date().toISOString() }).eq('organization_id', organizationId).eq('id', itemId).select('*').single();
    if (error) throw error;
    return mapItem(data);
  }
}
export const inventoryService = new InventoryService();
