import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import EscrowContracts from './EscrowContracts';
import { escrowContractAPI } from '../services/escrowContractAPI';
jest.mock('../services/escrowContractAPI', () => ({ escrowContractAPI: { create: jest.fn(), activate: jest.fn() } }));
test('creates an escrow draft with integer minor-unit amount', async () => { (escrowContractAPI.create as jest.Mock).mockResolvedValue({ id: 'contract-1' }); render(<EscrowContracts />); fireEvent.change(screen.getByLabelText('Payer ID'), { target: { value: 'payer-1' } }); fireEvent.change(screen.getByLabelText('Beneficiary ID'), { target: { value: 'beneficiary-1' } }); fireEvent.change(screen.getByLabelText('Amount (minor units)'), { target: { value: '250000' } }); fireEvent.change(screen.getByLabelText('Purpose'), { target: { value: 'Farm input escrow' } }); fireEvent.click(screen.getByRole('button', { name: 'Create draft' })); await waitFor(() => expect(escrowContractAPI.create).toHaveBeenCalledWith(expect.objectContaining({ amountMinor: 250000, currency: 'NGN' }))); });
test('activates a selected contract', async () => { (escrowContractAPI.activate as jest.Mock).mockResolvedValue({ state: 'active' }); render(<EscrowContracts />); fireEvent.change(screen.getByLabelText('Contract ID'), { target: { value: 'contract-1' } }); fireEvent.click(screen.getByRole('button', { name: 'Activate' })); await waitFor(() => expect(escrowContractAPI.activate).toHaveBeenCalledWith('contract-1')); });
