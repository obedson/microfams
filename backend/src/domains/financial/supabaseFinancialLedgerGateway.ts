import { supabase } from '../../utils/supabase.js';
import { FinancialJournalGateway, JournalPostingRecord } from './types.js';

export class FinancialPostingError extends Error {
  constructor(message: string) {
    super(`Financial journal posting failed: ${message}`);
    this.name = 'FinancialPostingError';
  }
}

export class SupabaseFinancialLedgerGateway implements FinancialJournalGateway {
  async post(record: JournalPostingRecord): Promise<string> {
    const { data, error } = await supabase.rpc('post_financial_journal', {
      p_organization_id: record.organizationId,
      p_currency: record.currency,
      p_effective_date: record.effectiveDate,
      p_source_domain: record.sourceDomain,
      p_source_record_id: record.sourceRecordId,
      p_idempotency_key: record.idempotencyKey,
      p_request_hash: record.requestHash,
      p_correlation_id: record.correlationId,
      p_description: record.description,
      p_actor_id: record.actorId || null,
      p_lines: record.lines.map((line) => ({
        account_id: line.accountId,
        line_number: line.lineNumber,
        side: line.side,
        amount_minor: line.amountMinor,
        memo: line.memo || null,
      })),
    });
    if (error) throw new FinancialPostingError(error.message);
    return data as string;
  }
}
