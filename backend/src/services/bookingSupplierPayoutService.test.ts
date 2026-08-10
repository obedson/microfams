import {
  BookingSupplierPayoutError,
  decryptBookingPayoutDestination,
  encryptBookingPayoutDestination,
} from './bookingSupplierPayoutService.js';

describe('booking supplier payout destination protection', () => {
  const key = Buffer.alloc(32, 7).toString('base64');
  const destination = {
    accountNumber: '0123456789',
    bankCode: '044',
    accountName: 'Verified Supplier',
  };

  it('encrypts with authenticated random nonces and decrypts exactly', () => {
    const first = encryptBookingPayoutDestination(destination, key);
    const second = encryptBookingPayoutDestination(destination, key);
    expect(first).not.toBe(second);
    expect(first).not.toContain(destination.accountNumber);
    expect(decryptBookingPayoutDestination(first, key)).toEqual(destination);
  });

  it('rejects tampering and invalid key material', () => {
    const encrypted = encryptBookingPayoutDestination(destination, key);
    const parts = encrypted.split('.');
    const ciphertext = parts[3];
    parts[3] = `${ciphertext[0] === 'A' ? 'B' : 'A'}${ciphertext.slice(1)}`;
    const tampered = parts.join('.');
    expect(() => decryptBookingPayoutDestination(tampered, key))
      .toThrow(BookingSupplierPayoutError);
    expect(() => encryptBookingPayoutDestination(destination, 'invalid'))
      .toThrow('BOOKING_PAYOUT_ENCRYPTION_NOT_CONFIGURED');
  });
});
