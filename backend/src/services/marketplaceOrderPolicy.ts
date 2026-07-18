export const MARKETPLACE_ORDER_STATUSES = ['pending', 'confirmed', 'shipped', 'delivered', 'cancelled'] as const;

export type MarketplaceOrderStatus = typeof MARKETPLACE_ORDER_STATUSES[number];

export const normalizeOrderQuantity = (value: unknown): number | null => {
  const quantity = typeof value === 'number' ? value : Number(value);
  return Number.isSafeInteger(quantity) && quantity > 0 ? quantity : null;
};

export const isMarketplaceOrderStatus = (value: unknown): value is MarketplaceOrderStatus =>
  typeof value === 'string' && MARKETPLACE_ORDER_STATUSES.includes(value as MarketplaceOrderStatus);

export const expectedPaymentAmountInMinorUnits = (totalAmount: number | string): number => {
  const amount = Number(totalAmount);
  if (!Number.isFinite(amount) || amount < 0) throw new Error('Invalid order total');
  return Math.round(amount * 100);
};

export const paymentMatchesOrder = (
  order: { payment_reference?: string | null; total_amount: number | string },
  provider: { reference?: string; amount?: number; currency?: string },
): boolean => provider.reference === order.payment_reference
  && provider.amount === expectedPaymentAmountInMinorUnits(order.total_amount)
  && provider.currency === 'NGN';
