import '@testing-library/jest-dom';
import React from 'react';
import { render, screen } from '@testing-library/react';
import FarmRecommendations from './FarmRecommendations';
import { farmRecordAPI } from '../../services/farmRecordAPI';

jest.mock('../../services/farmRecordAPI', () => ({ farmRecordAPI: { getRecommendations: jest.fn() } }));

test('renders recommendation confidence and provenance evidence', async () => {
  (farmRecordAPI.getRecommendations as jest.Mock).mockResolvedValue([{
    type: 'warning', title: 'High mortality rate detected', message: 'Review protocols.',
    ruleId: 'LIVESTOCK_MORTALITY_OVER_5_PERCENT_V1', confidence: 0.81,
    provenance: { source: 'farm_records', recordIds: ['record-1', 'record-2'], generatedAt: '2026-08-25T00:00:00.000Z' },
  }]);
  render(<FarmRecommendations />);
  expect(await screen.findByText('81% confidence')).toBeInTheDocument();
  expect(screen.getByText(/2 source records/)).toBeInTheDocument();
});

test('shows a controlled unavailable state when the feature is disabled', async () => {
  (farmRecordAPI.getRecommendations as jest.Mock).mockRejectedValue(new Error('FEATURE_DISABLED'));
  render(<FarmRecommendations />);
  expect(await screen.findByRole('alert')).toHaveTextContent('not available');
});
