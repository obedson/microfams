const NGN_INPUT = /^(0|[1-9]\d*)(?:\.(\d{1,2}))?$/;

export const parseNgnMinor = (value: string): number => {
  const match = NGN_INPUT.exec(value.trim());
  if (!match) throw new Error('Enter an amount with no more than two decimal places');
  const whole = Number(match[1]);
  const fraction = Number((match[2] || '').padEnd(2, '0'));
  if (!Number.isSafeInteger(whole) || whole > Math.floor((Number.MAX_SAFE_INTEGER - fraction) / 100)) {
    throw new Error('Amount exceeds the supported range');
  }
  const result = whole * 100 + fraction;
  if (!Number.isSafeInteger(result) || result <= 0) throw new Error('Enter a valid positive amount');
  return result;
};

export const formatNgnMinor = (minor: number): string => new Intl.NumberFormat('en-NG', {
  style: 'currency',
  currency: 'NGN',
}).format(minor / 100);
