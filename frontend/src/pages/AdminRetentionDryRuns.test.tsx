import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import AdminRetentionDryRuns from './AdminRetentionDryRuns';
import { trustAPI } from '../services/trustAPI';

jest.mock('../services/trustAPI', () => ({ trustAPI: {
  createRetentionDryRun: jest.fn(),
  selectRetentionItems: jest.fn(),
} }));

describe('AdminRetentionDryRuns', () => {
  it('creates and classifies a non-destructive preview', async () => {
    (trustAPI.createRetentionDryRun as jest.Mock).mockResolvedValue({ runId: 'run-1', mode: 'dry_run', status: 'planned' });
    (trustAPI.selectRetentionItems as jest.Mock).mockResolvedValue({
      runId: 'run-1', mode: 'dry_run', status: 'completed',
      summary: { total: 3, held: 1, retained: 0, wouldAnonymize: 0, wouldDelete: 2, excluded: 0, dataClass: 'trust.case_metadata', cutoffAt: '2026-01-01T00:00:00Z' },
    });
    render(<AdminRetentionDryRuns />);
    fireEvent.change(screen.getByLabelText('Policy ID'), { target: { value: 'policy-1' } });
    fireEvent.change(screen.getByLabelText('Organization ID'), { target: { value: 'org-1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Run safe preview' }));
    await waitFor(() => expect(trustAPI.createRetentionDryRun).toHaveBeenCalledWith({ policyId: 'policy-1', organizationId: 'org-1' }));
    expect(trustAPI.selectRetentionItems).toHaveBeenCalledWith('run-1');
    expect(await screen.findByText('Completed preview')).toBeInTheDocument();
    expect(screen.getByText('trust.case_metadata')).toBeInTheDocument();
    expect(screen.getByText(/never anonymizes or deletes/i)).toBeInTheDocument();
  });
});