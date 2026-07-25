import '@testing-library/jest-dom';
import React from 'react';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import SuspensionBanner from '../SuspensionBanner';

describe('SuspensionBanner', () => {
  it('explains membership scope and keeps the appeal path available', () => {
    render(<MemoryRouter><SuspensionBanner scope="membership" reason="Membership review required" appealHref="/trust/status" /></MemoryRouter>);
    expect(screen.getByRole('alert')).toHaveTextContent('Your membership in this organization is suspended.');
    expect(screen.getByText('Membership review required')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Request a review' })).toHaveAttribute('href', '/trust/status');
  });
});
