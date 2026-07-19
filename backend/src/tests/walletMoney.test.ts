import { assertMinorUnits, majorDecimalToMinor, minorToMajorDecimal } from '../domains/financial/money.js';

describe('financial money contracts', () => {
  it('converts compatibility decimals without binary floating-point arithmetic', () => {
    expect(majorDecimalToMinor('1000.05')).toBe(100005);
    expect(minorToMajorDecimal(100005)).toBe('1000.05');
    expect(minorToMajorDecimal('1')).toBe('0.01');
  });

  it.each(['1.001', '01.00', 'NaN', '-1'])('rejects invalid major-unit compatibility value %s', (value) => {
    expect(() => majorDecimalToMinor(value)).toThrow();
  });

  it('requires positive safe integer minor-unit commands', () => {
    expect(assertMinorUnits(100)).toBe(100);
    expect(() => assertMinorUnits(1.5)).toThrow();
    expect(() => assertMinorUnits(0)).toThrow();
    expect(() => assertMinorUnits(Number.MAX_SAFE_INTEGER + 1)).toThrow();
  });
});
