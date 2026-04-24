import React, { useState } from 'react';
import { Filter, Search, X, Calendar } from 'lucide-react';

interface BookingFiltersProps {
  statusFilter: string;
  onStatusChange: (status: string) => void;
  propertyFilter?: string;
  onPropertyChange?: (propertyId: string) => void;
  properties?: Array<{ id: string; title: string }>;
  type: 'farmer' | 'owner';
  // Task 5.3: Advanced filtering props
  paymentStatusFilter?: string;
  onPaymentStatusChange?: (status: string) => void;
  dateRangeFilter?: { start: string; end: string };
  onDateRangeChange?: (range: { start: string; end: string }) => void;
  searchQuery?: string;
  onSearchChange?: (query: string) => void;
  onClearFilters?: () => void;
}

const BookingFilters: React.FC<BookingFiltersProps> = ({
  statusFilter,
  onStatusChange,
  propertyFilter,
  onPropertyChange,
  properties,
  type,
  paymentStatusFilter,
  onPaymentStatusChange,
  dateRangeFilter,
  onDateRangeChange,
  searchQuery,
  onSearchChange,
  onClearFilters
}) => {
  const [showAdvanced, setShowAdvanced] = useState(false);

  const statusOptions = [
    { value: 'all', label: 'All Bookings' },
    { value: 'pending_payment', label: 'Pending Payment' },
    { value: 'pending', label: 'Pending Approval' },
    { value: 'confirmed', label: 'Confirmed' },
    { value: 'completed', label: 'Completed' },
    { value: 'cancelled', label: 'Cancelled' }
  ];

  const paymentStatusOptions = [
    { value: 'all', label: 'All Payment Status' },
    { value: 'pending', label: 'Pending' },
    { value: 'paid', label: 'Paid' },
    { value: 'failed', label: 'Failed' }
  ];

  // Check if any advanced filters are active
  const hasActiveFilters = 
    statusFilter !== 'all' ||
    (propertyFilter && propertyFilter !== 'all') ||
    (paymentStatusFilter && paymentStatusFilter !== 'all') ||
    (dateRangeFilter && (dateRangeFilter.start || dateRangeFilter.end)) ||
    (searchQuery && searchQuery.trim());

  return (
    <div className="bg-white rounded-lg shadow p-4 mb-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2">
          <Filter size={20} className="text-gray-600" />
          <h3 className="text-lg font-semibold text-gray-900">Filters</h3>
          {hasActiveFilters && (
            <span className="bg-green-100 text-green-800 text-xs px-2 py-1 rounded-full">
              Active
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowAdvanced(!showAdvanced)}
            className="text-sm text-blue-600 hover:text-blue-800"
          >
            {showAdvanced ? 'Simple' : 'Advanced'}
          </button>
          {hasActiveFilters && onClearFilters && (
            <button
              onClick={onClearFilters}
              className="flex items-center gap-1 text-sm text-red-600 hover:text-red-800"
            >
              <X size={16} />
              Clear All
            </button>
          )}
        </div>
      </div>

      {/* Search Bar */}
      {onSearchChange && (
        <div className="mb-4">
          <div className="relative">
            <Search size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" role="img" aria-label="Search icon" />
            <input
              id="search-input"
              type="text"
              placeholder="Search by farmer name or booking reference..."
              value={searchQuery || ''}
              onChange={(e) => onSearchChange(e.target.value)}
              className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
              aria-label="Search bookings"
            />
          </div>
        </div>
      )}

      <div className={`grid gap-4 ${showAdvanced ? 'grid-cols-1 md:grid-cols-2 lg:grid-cols-4' : 'grid-cols-1 md:grid-cols-2 lg:grid-cols-3'}`}>
        {/* Status Filter */}
        <div>
          <label htmlFor="status-filter" className="block text-sm font-medium text-gray-700 mb-2">
            Status
          </label>
          <select
            id="status-filter"
            value={statusFilter}
            onChange={(e) => onStatusChange(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
          >
            {statusOptions.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </div>

        {/* Property Filter (Owner only) */}
        {type === 'owner' && properties && onPropertyChange && (
          <div>
            <label htmlFor="property-filter" className="block text-sm font-medium text-gray-700 mb-2">
              Property
            </label>
            <select
              id="property-filter"
              value={propertyFilter || 'all'}
              onChange={(e) => onPropertyChange(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
            >
              <option value="all">All Properties</option>
              {properties.map((property) => (
                <option key={property.id} value={property.id}>
                  {property.title}
                </option>
              ))}
            </select>
          </div>
        )}

        {/* Payment Status Filter */}
        {showAdvanced && onPaymentStatusChange && (
          <div>
            <label htmlFor="payment-status-filter" className="block text-sm font-medium text-gray-700 mb-2">
              Payment Status
            </label>
            <select
              id="payment-status-filter"
              value={paymentStatusFilter || 'all'}
              onChange={(e) => onPaymentStatusChange(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
            >
              {paymentStatusOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </div>
        )}

        {/* Date Range Filter */}
        {showAdvanced && onDateRangeChange && (
          <>
            <div>
              <label htmlFor="start-date-filter" className="block text-sm font-medium text-gray-700 mb-2">
                Start Date
              </label>
              <div className="relative">
                <Calendar size={16} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" role="img" aria-label="Calendar icon" />
                <input
                  id="start-date-filter"
                  type="date"
                  value={dateRangeFilter?.start || ''}
                  onChange={(e) => onDateRangeChange({
                    start: e.target.value,
                    end: dateRangeFilter?.end || ''
                  })}
                  className="w-full pl-10 pr-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
                />
              </div>
            </div>
            <div>
              <label htmlFor="end-date-filter" className="block text-sm font-medium text-gray-700 mb-2">
                End Date
              </label>
              <div className="relative">
                <Calendar size={16} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" role="img" aria-label="Calendar icon" />
                <input
                  id="end-date-filter"
                  type="date"
                  value={dateRangeFilter?.end || ''}
                  onChange={(e) => onDateRangeChange({
                    start: dateRangeFilter?.start || '',
                    end: e.target.value
                  })}
                  className="w-full pl-10 pr-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-green-500 focus:border-transparent"
                />
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
};

export default BookingFilters;
