import { FeatureFlagDefinition } from '../types/featureFlags.js';

const flag = (
  key: string,
  domain: string,
  description: string,
  options: Partial<Pick<FeatureFlagDefinition, 'defaultEnabled' | 'failureMode' | 'risk'>> = {},
): FeatureFlagDefinition => ({
  key,
  domain,
  description,
  defaultEnabled: options.defaultEnabled ?? false,
  failureMode: options.failureMode ?? 'closed',
  risk: options.risk ?? 'standard',
});

export const FEATURE_FLAG_CATALOG: readonly FeatureFlagDefinition[] = [
  flag('financial.payments.accept_new', 'payments', 'Accept new customer payment attempts.', { risk: 'regulated' }),
  flag('financial.payments.service_existing', 'payments', 'Process callbacks, reconciliation, refunds, and reversals for existing payments.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.payouts.create', 'payments', 'Create new beneficiary payouts.', { risk: 'regulated' }),
  flag('financial.payouts.service_existing', 'payments', 'Continue status updates and reconciliation for submitted payouts.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.wallets.transact', 'wallets', 'Create wallet credits, debits, and transfers.', { risk: 'regulated' }),
  flag('financial.wallets.read', 'wallets', 'Read balances, statements, and transaction history.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.escrow.create', 'escrow', 'Create and fund new escrow contracts.', { risk: 'regulated' }),
  flag('financial.escrow.service_existing', 'escrow', 'Release, refund, dispute, and report existing escrow obligations.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.savings.enrol', 'savings', 'Open new savings enrolments.', { risk: 'regulated' }),
  flag('financial.savings.service_existing', 'savings', 'Service contributions, statements, and lawful withdrawals for existing savings.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.investments.subscribe', 'investments', 'Accept new investment subscriptions.', { risk: 'regulated' }),
  flag('financial.investments.service_existing', 'investments', 'Report, mature, settle, or write down existing investments.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.loans.originate', 'loans', 'Accept and decide new loan applications.', { risk: 'regulated' }),
  flag('financial.loans.service_existing', 'loans', 'Service, collect, restructure, and report existing loans.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.dividends.declare', 'dividends', 'Calculate and approve new distributions.', { risk: 'regulated' }),
  flag('financial.dividends.service_existing', 'dividends', 'Pay, reconcile, and correct approved distributions.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('financial.accounting.post', 'accounting', 'Post operational events to the tenant general ledger.', { risk: 'regulated' }),
  flag('financial.accounting.read', 'accounting', 'Read journals, statements, reconciliations, and reports.', { defaultEnabled: true, failureMode: 'open', risk: 'regulated' }),
  flag('integration.paystack.live', 'payments', 'Route Paystack operations to live mode.', { risk: 'provider' }),
  flag('integration.interswitch.live', 'payments', 'Route Interswitch operations to live mode.', { risk: 'provider' }),
  flag('integration.organization_verification', 'identity', 'Submit organization registration evidence to an approved verification provider.', { risk: 'provider' }),
  flag('integration.identity_verification', 'identity', 'Use a government or licensed identity verification provider.', { risk: 'provider' }),
  flag('integration.sms', 'communications', 'Send messages through the configured SMS provider.', { risk: 'provider' }),
  flag('integration.weather', 'intelligence', 'Retrieve provider weather observations and forecasts.', { risk: 'provider' }),
  flag('integration.satellite', 'intelligence', 'Retrieve and process satellite imagery.', { risk: 'provider' }),
  flag('integration.ai_assistant', 'intelligence', 'Use the configured AI provider for assisted workflows.', { risk: 'provider' }),
  flag('institutional.government_dashboard', 'institutional', 'Expose programme dashboards to authorized government tenants.'),
  flag('institutional.ngo_dashboard', 'institutional', 'Expose programme dashboards to authorized NGO tenants.'),
  flag('farm_erp.operations', 'farm_erp', 'Enable full farm planning, inventory, labour, production, and cost workflows.'),
] as const;

export const FEATURE_FLAGS = new Map(FEATURE_FLAG_CATALOG.map((definition) => [definition.key, definition]));
