import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import SuspendedAccountRecovery from './SuspendedAccountRecovery';
import { trustAPI } from '../services/trustAPI';

jest.mock('../services/trustAPI', () => ({ trustAPI: {
  requestSuspendedRecovery: jest.fn(),
  inspectSuspendedRecovery: jest.fn(),
  submitSuspendedRecoveryAppeal: jest.fn(),
} }));

const token = 'A'.repeat(43);
const renderToken = () => render(
  <MemoryRouter initialEntries={[`/trust/recovery?token=${token}`]}>
    <SuspendedAccountRecovery />
  </MemoryRouter>,
);

describe('SuspendedAccountRecovery', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses the same neutral response for a recovery request', async () => {
    (trustAPI.requestSuspendedRecovery as jest.Mock).mockResolvedValue({});
    render(<MemoryRouter><SuspendedAccountRecovery /></MemoryRouter>);
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'user@example.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send recovery link' }));
    expect(await screen.findByRole('status')).toHaveTextContent('If the account is eligible');
  });

  it('inspects a token and submits one appeal', async () => {
    (trustAPI.inspectSuspendedRecovery as jest.Mock).mockResolvedValue({
      caseId: 'c1', suspended: true,
      expiresAt: new Date(Date.now() + 60000).toISOString(), appealStatus: null,
    });
    (trustAPI.submitSuspendedRecoveryAppeal as jest.Mock).mockResolvedValue({});
    renderToken();
    await screen.findByText(/Your account is suspended/);
    fireEvent.change(screen.getByLabelText('Appeal statement'), { target: { value: 'Material evidence was not considered.' } });
    fireEvent.click(screen.getByRole('button', { name: 'Submit appeal' }));
    await waitFor(() => expect(trustAPI.submitSuspendedRecoveryAppeal).toHaveBeenCalled());
    expect(await screen.findByRole('status')).toHaveTextContent('Appeal submitted');
  });

  it('shows one safe message for invalid and expired links without exposing the appeal form', async () => {
    (trustAPI.inspectSuspendedRecovery as jest.Mock).mockRejectedValue(new Error('expired token digest'));
    renderToken();
    expect(await screen.findByRole('alert')).toHaveTextContent('invalid or has expired');
    expect(screen.queryByLabelText('Appeal statement')).not.toBeInTheDocument();
    expect(document.body.textContent).not.toMatch(/digest|database/i);
  });

  it('keeps a failed consumed-token appeal generic and retry-safe', async () => {
    (trustAPI.inspectSuspendedRecovery as jest.Mock).mockResolvedValue({
      caseId: 'c1', suspended: true,
      expiresAt: new Date(Date.now() + 60000).toISOString(), appealStatus: null,
    });
    (trustAPI.submitSuspendedRecoveryAppeal as jest.Mock).mockRejectedValue(new Error('consumed token row'));
    renderToken();
    await screen.findByText(/Your account is suspended/);
    fireEvent.change(screen.getByLabelText('Appeal statement'), { target: { value: 'Material evidence was not considered.' } });
    fireEvent.click(screen.getByRole('button', { name: 'Submit appeal' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('invalid or expired');
    expect(screen.getByLabelText('Appeal statement')).toBeInTheDocument();
    expect(document.body.textContent).not.toMatch(/consumed token row/i);
  });
});