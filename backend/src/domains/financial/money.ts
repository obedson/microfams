const MINOR_PATTERN = /^-?\d+$/;
const MAJOR_PATTERN = /^(0|[1-9]\d*)(?:\.(\d{1,2}))?$/;

export const assertMinorUnits = (value: number, label = 'Amount'): number => {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${label} must be a positive safe integer in minor units`);
  }
  return value;
};

export const minorToMajorDecimal = (minor: number | string): string => {
  const text = String(minor);
  if (!MINOR_PATTERN.test(text)) throw new Error('Minor-unit amount must be an integer');
  const value = BigInt(text);
  const sign = value < 0n ? '-' : '';
  const absolute = value < 0n ? -value : value;
  return `${sign}${absolute / 100n}.${(absolute % 100n).toString().padStart(2, '0')}`;
};

export const majorDecimalToMinor = (major: string | number): number => {
  const text = String(major);
  const match = MAJOR_PATTERN.exec(text);
  if (!match) throw new Error('Major-unit compatibility amount has invalid precision');
  const value = BigInt(match[1]) * 100n + BigInt((match[2] || '').padEnd(2, '0'));
  const numberValue = Number(value);
  if (!Number.isSafeInteger(numberValue)) throw new Error('Amount exceeds the application safe-integer range');
  return numberValue;
};

export const formatNgnMinor = (minor: number): string => {
  assertMinorUnits(minor);
  return new Intl.NumberFormat('en-NG', { style: 'currency', currency: 'NGN' }).format(minor / 100);
};
