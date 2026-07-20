export const REPORT_EXPORT_FIELDS: Readonly<Record<string, readonly string[]>> = {
  bookings: ['id', 'property_id', 'farmer_id', 'start_date', 'end_date', 'total_amount', 'status', 'payment_status', 'created_at'],
  properties: ['id', 'owner_id', 'title', 'livestock_type', 'space_type', 'size', 'size_unit', 'city', 'price_per_month', 'is_active', 'created_at'],
  groups: ['id', 'name', 'group_type', 'member_count', 'contribution_amount', 'contribution_enabled', 'created_at'],
  farm_records: ['id', 'farmer_id', 'property_id', 'livestock_type', 'livestock_count', 'expenses', 'record_date', 'created_at'],
  orders: ['id', 'buyer_id', 'product_id', 'quantity', 'unit_price', 'total_amount', 'status', 'payment_status', 'created_at'],
  courses: ['id', 'title', 'description', 'duration', 'level', 'category', 'created_at'],
  member_contributions: ['id', 'cycle_id', 'member_id', 'expected_amount', 'paid_amount', 'penalty_amount', 'payment_status', 'created_at'],
  wallet_transactions: ['id', 'wallet_id', 'group_id', 'type', 'direction', 'amount', 'status', 'reference', 'created_at'],
  audit_logs: ['id', 'user_id', 'action', 'resource_type', 'resource_id', 'created_at'],
};

export const validateReportExport = (table: unknown, fields: unknown): { table: string; fields: string[] } => {
  if (typeof table !== 'string' || !Array.isArray(fields) || fields.length === 0) {
    throw new Error('Table and a non-empty fields array are required');
  }
  const allowed = REPORT_EXPORT_FIELDS[table];
  if (!allowed) throw new Error('Export table is not allowed');
  if (!fields.every((field): field is string => typeof field === 'string' && allowed.includes(field))) {
    throw new Error('One or more export fields are not allowed');
  }
  return { table, fields: [...new Set(fields)] };
};

const csvCell = (value: unknown): string => {
  if (value === null || value === undefined) return '';
  let text = typeof value === 'object' ? JSON.stringify(value) : String(value);
  if (/^[=+@]/.test(text) || /^-[^0-9]/.test(text)) text = `'${text}`;
  return `"${text.replace(/"/g, '""')}"`;
};

export const buildCsv = (fields: readonly string[], rows: readonly Record<string, unknown>[]): string => [
  fields.map(csvCell).join(','),
  ...rows.map((row) => fields.map((field) => csvCell(row[field])).join(',')),
].join('\n');
