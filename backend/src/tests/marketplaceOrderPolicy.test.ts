import {
  expectedPaymentAmountInMinorUnits,
  isMarketplaceOrderStatus,
  normalizeOrderQuantity,
  paymentMatchesOrder,
} from '../services/marketplaceOrderPolicy.js';

describe('marketplace order policy', () => {
  it.each([
    [1, 1],
    ['2', 2],
    [0, null],
    [-1, null],
    [1.5, null],
    ['not-a-number', null],
  ])('normalizes safe positive whole-number quantities', (input, expected) => {
    expect(normalizeOrderQuantity(input)).toBe(expected);
  });

  it('accepts only registered order statuses', () => {
    expect(isMarketplaceOrderStatus('shipped')).toBe(true);
    expect(isMarketplaceOrderStatus('paid')).toBe(false);
    expect(isMarketplaceOrderStatus(undefined)).toBe(false);
  });

  it('converts the stored order total to provider minor units', () => {
    expect(expectedPaymentAmountInMinorUnits('2500.25')).toBe(250025);
    expect(() => expectedPaymentAmountInMinorUnits('invalid')).toThrow('Invalid order total');
  });

  it('requires reference, amount, and currency to match the stored payment intent', () => {
    const order = { payment_reference: 'ORDER-123', total_amount: '5000.00' };

    expect(paymentMatchesOrder(order, { reference: 'ORDER-123', amount: 500000, currency: 'NGN' })).toBe(true);
    expect(paymentMatchesOrder(order, { reference: 'ORDER-other', amount: 500000, currency: 'NGN' })).toBe(false);
    expect(paymentMatchesOrder(order, { reference: 'ORDER-123', amount: 499999, currency: 'NGN' })).toBe(false);
    expect(paymentMatchesOrder(order, { reference: 'ORDER-123', amount: 500000, currency: 'USD' })).toBe(false);
  });
});
