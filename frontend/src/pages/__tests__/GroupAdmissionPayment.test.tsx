import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { apiClient } from '../../api/client';
import GroupDetail from '../GroupDetail';
import Payment from '../Payment';

jest.mock('@tanstack/react-query', () => ({ useQuery: jest.fn() }));
jest.mock('../../api/client', () => ({
  apiClient: { get: jest.fn(), post: jest.fn() },
}));
jest.mock('../../store/authStore', () => ({
  useAuthStore: () => ({
    user: { id: 'user-1', email: 'member@example.test', is_platform_subscriber: true, nin_verified: true },
  }),
}));

const group = {
  id: 'group-1', name: 'Growers Cooperative', description: 'A governed farm group.',
  entry_fee: 1000, member_count: 2, state: { name: 'Kaduna' }, lga: { name: 'Zaria' },
};

describe('governed group admission client', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    jest.spyOn(window, 'alert').mockImplementation(() => undefined);
  });

  it('does not offer direct join before an invitation exists', () => {
    (useQuery as jest.Mock).mockImplementation(({ queryKey }: { queryKey: string[] }) => {
      if (queryKey[0] === 'group') return { data: group, isLoading: false, error: null };
      if (queryKey[0] === 'group-members') return { data: [], error: null };
      return { data: { isMember: false } };
    });

    render(<MemoryRouter initialEntries={['/groups/group-1']}><Routes><Route path="/groups/:id" element={<GroupDetail />} /></Routes></MemoryRouter>);

    expect(screen.getByRole('note')).toHaveTextContent('Membership is by invitation');
    expect(screen.queryByRole('button', { name: 'Join Group' })).not.toBeInTheDocument();
  });

  it('offers payment only after admission reaches pending_payment', () => {
    (useQuery as jest.Mock).mockImplementation(({ queryKey }: { queryKey: string[] }) => {
      if (queryKey[0] === 'group') return { data: group, isLoading: false, error: null };
      if (queryKey[0] === 'group-members') return { data: [], error: null };
      return { data: { id: 'member-1', status: 'pending_payment', payment_status: 'pending' } };
    });

    render(<MemoryRouter initialEntries={['/groups/group-1']}><Routes><Route path="/groups/:id" element={<GroupDetail />} /></Routes></MemoryRouter>);

    expect(screen.getByRole('button', { name: 'Complete Payment' })).toBeInTheDocument();
  });

  it('initializes from server-owned group and membership amounts with idempotency', async () => {
    (apiClient.post as jest.Mock).mockResolvedValue({ data: { data: { state: 'processing' } } });

    render(<MemoryRouter initialEntries={['/payment?type=group&id=member-1&groupId=group-1']}><Routes><Route path="/payment" element={<Payment />} /></Routes></MemoryRouter>);
    fireEvent.click(await screen.findByRole('button', { name: 'Continue to Secure Checkout' }));

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith(
      '/payments/initialize-group',
      { group_id: 'group-1', member_id: 'member-1' },
      { headers: { 'Idempotency-Key': expect.stringMatching(/^group-payment-/) } },
    ));
  });
});
