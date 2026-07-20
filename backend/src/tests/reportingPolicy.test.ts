import { buildCsv, validateReportExport } from '../services/reportingPolicy.js';

describe('tenant reporting policy', () => {
  it('rejects arbitrary tables and fields', () => {
    expect(() => validateReportExport('users', ['email'])).toThrow('not allowed');
    expect(() => validateReportExport('bookings', ['id', 'password'])).toThrow('not allowed');
  });

  it('deduplicates approved fields without changing their order', () => {
    expect(validateReportExport('bookings', ['id', 'status', 'id']).fields).toEqual(['id', 'status']);
  });

  it('quotes CSV values and neutralizes spreadsheet formulas', () => {
    const csv = buildCsv(['name', 'amount'], [{ name: '=HYPERLINK("bad")', amount: 12 }]);
    expect(csv).toContain("'=HYPERLINK");
    expect(csv).toContain('"12"');
  });
});
