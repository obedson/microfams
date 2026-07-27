import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import WalletPage from './Wallet';
import { walletApi } from '../api/wallet';

jest.mock('../api/wallet', () => ({
  walletApi: {
    getWallet: jest.fn(),
    getStatement: jest.fn(),
    lookupP2PRecipient: jest.fn(),
    initiateP2P: jest.fn(),
    previewWithdrawal: jest.fn(),
    confirmWithdrawal: jest.fn(),
    syncWithdrawal: jest.fn(),
  },
}));

jest.mock('../store/authStore', () => ({
  useAuthStore: () => ({ user: { id: 'user-1', nin_verified: true } }),
}));

describe('Wallet page minor-unit balances', () => {
  beforeEach(() => {
    (walletApi.getStatement as jest.Mock).mockResolvedValue({
      data: {
        openingBalanceMinor: '10000',
        closingBalanceMinor: '12500',
        period: { from: '2026-07-01', to: '2026-07-31', cutoff: '2026-07-27T12:00:00.000Z' },
        entries: [{
          id: 'line-1', effectiveDate: '2026-07-02', description: 'Confirmed funding',
          movementMinor: '2500', balanceMinor: '12500',
        }],
      },
    });
  });

  it('renders available and ledger balances from integer minor units', async () => {
    (walletApi.getWallet as jest.Mock).mockResolvedValue({
      data: {
        wallet: {
          id: 'wallet-1', status: 'ACTIVE', currency: 'NGN',
          availableBalanceMinor: 12345, ledgerBalanceMinor: 15000,
          pendingDebitsMinor: 2655, pendingCreditsMinor: 0,
        },
        transactions: [],
      },
    });
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });

    render(
      <MemoryRouter>
        <QueryClientProvider client={queryClient}>
          <WalletPage />
        </QueryClientProvider>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/123\.45/)).toBeTruthy();
    expect(screen.getByText(/Ledger:.*150\.00/)).toBeTruthy();
    expect(await screen.findByText('Journal statement')).toBeTruthy();
    expect(screen.getByText('Confirmed funding')).toBeTruthy();
    expect(screen.getAllByText(/125\.00/).length).toBeGreaterThan(0);
  });
});
