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

export const formatNgnMinor = (minor: number | string): string => {
  if (typeof minor === 'number' && !Number.isSafeInteger(minor)) {
    throw new Error('Minor-unit number must be a safe integer');
  }
  const raw = String(minor);
  if (!/^-?\d+$/.test(raw)) throw new Error('Minor-unit value must be an integer');
  const negative = raw.startsWith('-');
  const unsigned = (negative ? raw.slice(1) : raw).replace(/^0+(?=\d)/, '');
  const padded = unsigned.padStart(3, '0');
  const whole = padded.slice(0, -2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const fraction = padded.slice(-2);
  return `${negative ? '-' : ''}₦${whole}.${fraction}`;
};
