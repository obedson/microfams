import { formatNgnMinor, parseNgnMinor } from './walletMoney';

describe('wallet minor-unit input', () => {
  it('parses naira input exactly into kobo', () => {
    expect(parseNgnMinor('1000.05')).toBe(100005);
    expect(parseNgnMinor('0.01')).toBe(1);
  });

  it.each(['1.001', '01.00', '-1', ''])('rejects invalid input %s', (value) => {
    expect(() => parseNgnMinor(value)).toThrow();
  });

  it('formats minor units as NGN', () => {
    expect(formatNgnMinor(100005)).toContain('1,000.05');
  });
});
