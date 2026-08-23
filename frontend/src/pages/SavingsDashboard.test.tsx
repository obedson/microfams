import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import SavingsDashboard from './SavingsDashboard';
import { savingsAPI } from '../services/savingsAPI';

jest.mock('../services/savingsAPI', () => ({ savingsAPI: { listProducts: jest.fn(), listEnrolments: jest.fn(), enrol: jest.fn() } }));
const product = { product: { id: 'product-1', code: 'SAV.FLEX', name: 'Flexible Saver', currency: 'NGN', state: 'active' }, version: { id: 'version-1', version: 1, minimum_contribution_minor: 10000, maximum_contribution_minor: 1000000, contribution_frequency: 'monthly', default_target_minor: null, lock_period_days: 30, grace_period_days: 5, early_withdrawal_rule: 'allowed', early_withdrawal_fee_minor: 0, return_method: 'simple_interest', annual_rate_basis_points: 1200, day_count_convention: 'actual_365', disclosure_version: '2026.1', disclosure_content_hash: 'a'.repeat(64), eligibility: {} } };

describe('SavingsDashboard', () => {
  it('requires disclosure acceptance and submits the versioned hash', async () => {
    (savingsAPI.listProducts as jest.Mock).mockResolvedValue([product]);
    (savingsAPI.listEnrolments as jest.Mock).mockResolvedValue([]);
    (savingsAPI.enrol as jest.Mock).mockResolvedValue({});
    render(<SavingsDashboard />);
    await screen.findByText('Flexible Saver');
    fireEvent.click(screen.getByRole('button', { name: 'Review and enrol' }));
    expect(screen.getByRole('button', { name: 'Enrol' })).toBeDisabled();
    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.change(screen.getByLabelText('Target amount (optional)'), { target: { value: '10000' } });
    fireEvent.click(screen.getByRole('button', { name: 'Enrol' }));
    await waitFor(() => expect(savingsAPI.enrol).toHaveBeenCalledWith('product-1', { targetMinor: 1000000, disclosureVersion: '2026.1', disclosureContentHash: 'a'.repeat(64) }));
    expect(await screen.findByRole('status')).toHaveTextContent('Savings account enrolled successfully.');
  });
});
