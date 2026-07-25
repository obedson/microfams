import '@testing-library/jest-dom';
import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import TrustAppeal from './TrustAppeal';
import { trustAPI } from '../services/trustAPI';

jest.mock('../services/trustAPI', () => ({ trustAPI: { submitAppeal: jest.fn() } }));

describe('TrustAppeal', () => {
  it('submits a bounded statement for the route decision', async () => {
    (trustAPI.submitAppeal as jest.Mock).mockResolvedValue({ id: 'appeal-1' });
    render(<MemoryRouter initialEntries={['/trust/cases/case-1/appeal']}><Routes><Route path="/trust/cases/:caseId/appeal" element={<TrustAppeal />} /></Routes></MemoryRouter>);
    fireEvent.change(screen.getByLabelText('Appeal statement'), { target: { value: 'The verification evidence should be reviewed again.' } });
    fireEvent.click(screen.getByRole('button', { name: 'Submit appeal' }));
    await waitFor(() => expect(trustAPI.submitAppeal).toHaveBeenCalledWith('case-1', 'The verification evidence should be reviewed again.'));
    expect(await screen.findByRole('status')).toHaveTextContent('Appeal submitted');
  });
});
