import { FinancialStatementGateway, StatementOwnerType, StatementQuery } from './statementTypes.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const isCalendarDate = (value: string) => {
  if (!DATE.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
};

export class StatementValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StatementValidationError';
  }
}

export interface StatementRequest {
  organizationId: string;
  actorId: string;
  ownerType: StatementOwnerType;
  ownerId: string;
  currency?: string;
  from?: string;
  to?: string;
  cutoff?: string;
  page?: number;
  limit?: number;
}

const signedMovement = (normalSide: 'debit' | 'credit', side: 'debit' | 'credit', amount: bigint) =>
  normalSide === side ? amount : -amount;

export class FinancialStatementService {
  constructor(private readonly gateway: FinancialStatementGateway, private readonly now = () => new Date()) {}

  async getStatement(request: StatementRequest) {
    const query = this.validate(request);
    await this.gateway.assertOwnerAccess(query, request.actorId);
    const result = await this.gateway.read(query);
    let running = BigInt(result.pageOpeningBalanceMinor);
    const entries = result.lines.map((line) => {
      const movement = signedMovement(result.account.normalSide, line.side, BigInt(line.amountMinor));
      running += movement;
      return { ...line, movementMinor: movement.toString(), balanceMinor: running.toString() };
    });
    return {
      account: result.account,
      period: { from: query.from, to: query.to, cutoff: query.cutoff },
      openingBalanceMinor: result.openingBalanceMinor,
      closingBalanceMinor: result.closingBalanceMinor,
      entries,
      pagination: {
        page: query.page,
        limit: query.limit,
        total: result.total,
        totalPages: Math.ceil(result.total / query.limit),
      },
    };
  }

  private validate(request: StatementRequest): StatementQuery {
    if (!UUID.test(request.organizationId) || !UUID.test(request.actorId) || !UUID.test(request.ownerId)) {
      throw new StatementValidationError('Valid organization, actor, and owner identifiers are required.');
    }
    if (request.ownerType !== 'user' && request.ownerType !== 'group') {
      throw new StatementValidationError('Statement owner type is invalid.');
    }
    const currentTime = this.now();
    const today = currentTime.toISOString().slice(0, 10);
    const from = request.from ?? `${today.slice(0, 7)}-01`;
    const to = request.to ?? today;
    if (!isCalendarDate(from) || !isCalendarDate(to) || from > to) {
      throw new StatementValidationError('Statement dates must be a valid ascending YYYY-MM-DD range.');
    }
    const cutoff = request.cutoff ?? currentTime.toISOString();
    const cutoffDate = new Date(cutoff);
    if (Number.isNaN(cutoffDate.getTime()) || cutoffDate > currentTime) {
      throw new StatementValidationError('Statement cutoff must be a valid time that is not in the future.');
    }
    const page = request.page ?? 1;
    const limit = request.limit ?? 25;
    if (!Number.isSafeInteger(page) || page < 1 || !Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new StatementValidationError('Statement pagination is invalid.');
    }
    const currency = request.currency ?? 'NGN';
    if (!/^[A-Z]{3}$/.test(currency)) throw new StatementValidationError('Currency must be an uppercase ISO code.');
    return { ...request, currency, from, to, cutoff: cutoffDate.toISOString(), page, limit };
  }
}
