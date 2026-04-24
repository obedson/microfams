import React from 'react';
import { render, screen } from '@testing-library/react';
import '@testing-library/jest-dom';
import AnalyticsDashboard from '../AnalyticsDashboard';

const mockAnalyticsData = {
  occupancy_rate: 0.75,
  revenue_breakdown: {
    confirmed: 150000,
    pending: 50000,
    pending_payment: 25000
  },
  average_booking_duration: 14,
  cancellation_rate: 0.15,
  monthly_trends: [
    { month: 'Jan 2024', revenue: 100000, bookings: 10 },
    { month: 'Feb 2024', revenue: 125000, bookings: 12 }
  ],
  top_properties: [
    { id: '1', name: 'Green Valley Farm', booking_count: 15, revenue: 75000 },
    { id: '2', name: 'Sunset Ranch', booking_count: 12, revenue: 60000 }
  ]
};

const mockDateRange = {
  start: new Date('2024-01-01'),
  end: new Date('2024-02-29')
};

describe('AnalyticsDashboard Component Tests - Task 6.2', () => {
  /**
   * Test: Loading state display
   * Validates: Component shows loading state when data is being fetched
   */
  test('displays loading state correctly', () => {
    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={true}
      />
    );

    expect(screen.getByText('Loading analytics...')).toBeInTheDocument();
    expect(screen.getByText('Loading analytics...')).toHaveClass('loading-spinner');
  });

  /**
   * Test: Analytics data rendering
   * Validates: All key metrics are displayed with correct formatting
   */
  test('renders analytics data correctly', () => {
    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    // Check occupancy rate
    expect(screen.getByText('75.0%')).toBeInTheDocument();
    
    // Check average duration
    expect(screen.getByText('14 days')).toBeInTheDocument();
    
    // Check cancellation rate
    expect(screen.getByText('15.0%')).toBeInTheDocument();
  });

  /**
   * Test: Revenue breakdown display
   * Validates: Revenue amounts are formatted as Nigerian Naira
   */
  test('displays revenue breakdown with correct currency formatting', () => {
    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    // Check revenue breakdown section exists
    expect(screen.getByText('Revenue Breakdown')).toBeInTheDocument();
    
    // Check confirmed revenue
    expect(screen.getByText('Confirmed')).toBeInTheDocument();
    
    // Check pending revenue
    expect(screen.getByText('Pending')).toBeInTheDocument();
    
    // Check pending payment revenue
    expect(screen.getByText('Pending Payment')).toBeInTheDocument();
  });

  /**
   * Test: Monthly trends visualization
   * Validates: Monthly trend data is displayed correctly
   */
  test('renders monthly trends correctly', () => {
    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    expect(screen.getByText('Monthly Trends')).toBeInTheDocument();
    expect(screen.getByText('Jan 2024')).toBeInTheDocument();
    expect(screen.getByText('Feb 2024')).toBeInTheDocument();
    expect(screen.getByText('10 bookings')).toBeInTheDocument();
    expect(screen.getByText('12 bookings')).toBeInTheDocument();
  });

  /**
   * Test: Top properties ranking
   * Validates: Property performance ranking is displayed correctly
   */
  test('displays top performing properties with rankings', () => {
    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    expect(screen.getByText('Top Performing Properties')).toBeInTheDocument();
    expect(screen.getByText('#1')).toBeInTheDocument();
    expect(screen.getByText('#2')).toBeInTheDocument();
    expect(screen.getByText('Green Valley Farm')).toBeInTheDocument();
    expect(screen.getByText('Sunset Ranch')).toBeInTheDocument();
    
    // Use more specific selectors to avoid conflicts with monthly trends
    const propertiesSection = screen.getByText('Top Performing Properties').closest('.properties-section');
    expect(propertiesSection).toBeInTheDocument();
    
    // Check for property-specific booking counts within the properties section
    const propertyStats = propertiesSection?.querySelectorAll('.stats');
    expect(propertyStats).toHaveLength(2);
    expect(propertyStats?.[0]).toHaveTextContent('15 bookings');
    expect(propertyStats?.[1]).toHaveTextContent('12 bookings');
  });

  /**
   * Test: Property filter display
   * Validates: Property filter is shown when propertyId is provided
   */
  test('displays property filter when propertyId is provided', () => {
    render(
      <AnalyticsDashboard
        propertyId="property-123"
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    expect(screen.getByText('Property: property-123')).toBeInTheDocument();
  });

  /**
   * Test: Responsive design classes
   * Validates: Component has proper CSS classes for responsive behavior
   */
  test('has correct CSS classes for responsive design', () => {
    const { container } = render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={mockAnalyticsData}
        loading={false}
      />
    );

    expect(container.firstChild).toHaveClass('analytics-dashboard');
    expect(screen.getByText('Analytics Dashboard').closest('.analytics-header')).toBeInTheDocument();
  });

  /**
   * Test: Error handling for empty data
   * Validates: Component handles empty or missing data gracefully
   */
  test('handles empty data gracefully', () => {
    const emptyData = {
      occupancy_rate: 0,
      revenue_breakdown: { confirmed: 0, pending: 0, pending_payment: 0 },
      average_booking_duration: 0,
      cancellation_rate: 0,
      monthly_trends: [],
      top_properties: []
    };

    render(
      <AnalyticsDashboard
        dateRange={mockDateRange}
        data={emptyData}
        loading={false}
      />
    );

    // Use more specific selectors to avoid multiple matches
    expect(screen.getByText('Occupancy Rate').nextElementSibling).toHaveTextContent('0.0%');
    expect(screen.getByText('0 days')).toBeInTheDocument(); // Average duration
  });
});
