import React from 'react';
import { render, screen } from '@testing-library/react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router-dom';
import Login from './pages/Login';

describe('V1 accessibility smoke', () => {
  it('exposes labelled authentication controls and a submit action', () => {
    const client = new QueryClient();
    render(<QueryClientProvider client={client}><MemoryRouter><Login /></MemoryRouter></QueryClientProvider>);
    expect(screen.getByRole('heading', { name: /welcome back/i })).toBeInTheDocument();
    expect(screen.getByLabelText(/email address/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /sign in/i })).toBeInTheDocument();
  });
});
