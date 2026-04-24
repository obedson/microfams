import React from 'react';

interface MonthlyTrend {
  month: string;
  revenue: number;
  bookings: number;
}

interface PropertyPerformance {
  id: string;
  name: string;
  booking_count: number;
  revenue: number;
}

interface AnalyticsData {
  occupancy_rate: number;
  revenue_breakdown: {
    confirmed: number;
    pending: number;
    pending_payment: number;
  };
  average_booking_duration: number;
  cancellation_rate: number;
  monthly_trends: MonthlyTrend[];
  top_properties: PropertyPerformance[];
}

interface DateRange {
  start: Date;
  end: Date;
}

interface AnalyticsDashboardProps {
  propertyId?: string;
  dateRange: DateRange;
  data: AnalyticsData;
  loading: boolean;
}

const AnalyticsDashboard: React.FC<AnalyticsDashboardProps> = ({
  propertyId,
  dateRange,
  data,
  loading
}) => {
  if (loading) {
    return (
      <div className="analytics-dashboard loading">
        <div className="loading-spinner">Loading analytics...</div>
      </div>
    );
  }

  const formatCurrency = (amount: number) => {
    return new Intl.NumberFormat('en-NG', {
      style: 'currency',
      currency: 'NGN'
    }).format(amount);
  };

  const formatPercentage = (value: number) => {
    return `${(value * 100).toFixed(1)}%`;
  };

  return (
    <div className="analytics-dashboard">
      <div className="analytics-header">
        <h2>Analytics Dashboard</h2>
        {propertyId && <span className="property-filter">Property: {propertyId}</span>}
      </div>

      {/* Key Metrics Cards */}
      <div className="metrics-grid">
        <div className="metric-card occupancy">
          <h3>Occupancy Rate</h3>
          <div className="metric-value">{formatPercentage(data.occupancy_rate)}</div>
        </div>

        <div className="metric-card duration">
          <h3>Average Duration</h3>
          <div className="metric-value">{data.average_booking_duration} days</div>
        </div>

        <div className="metric-card cancellation">
          <h3>Cancellation Rate</h3>
          <div className="metric-value">{formatPercentage(data.cancellation_rate)}</div>
        </div>
      </div>

      {/* Revenue Breakdown */}
      <div className="revenue-section">
        <h3>Revenue Breakdown</h3>
        <div className="revenue-breakdown">
          <div className="revenue-item confirmed">
            <span className="label">Confirmed</span>
            <span className="amount">{formatCurrency(data.revenue_breakdown.confirmed)}</span>
          </div>
          <div className="revenue-item pending">
            <span className="label">Pending</span>
            <span className="amount">{formatCurrency(data.revenue_breakdown.pending)}</span>
          </div>
          <div className="revenue-item pending-payment">
            <span className="label">Pending Payment</span>
            <span className="amount">{formatCurrency(data.revenue_breakdown.pending_payment)}</span>
          </div>
        </div>
      </div>

      {/* Monthly Trends */}
      <div className="trends-section">
        <h3>Monthly Trends</h3>
        <div className="trend-chart">
          {data.monthly_trends.map((trend, index) => (
            <div key={index} className="trend-item">
              <div className="month">{trend.month}</div>
              <div className="revenue">{formatCurrency(trend.revenue)}</div>
              <div className="bookings">{trend.bookings} bookings</div>
            </div>
          ))}
        </div>
      </div>

      {/* Top Properties */}
      <div className="properties-section">
        <h3>Top Performing Properties</h3>
        <div className="properties-list">
          {data.top_properties.map((property, index) => (
            <div key={property.id} className="property-item">
              <div className="rank">#{index + 1}</div>
              <div className="property-info">
                <div className="name">{property.name}</div>
                <div className="stats">
                  {property.booking_count} bookings • {formatCurrency(property.revenue)}
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

export default AnalyticsDashboard;
