import React, { useState } from 'react';
import { ChevronLeft, ChevronRight, Calendar as CalendarIcon } from 'lucide-react';

interface BookingCalendarProps {
  bookings: any[];
  bookedDates?: string[]; // New prop for specific booked dates
  onDateClick?: (date: Date, bookings: any[]) => void;
  propertyFilter?: string;
  properties?: Array<{ id: string; title: string }>;
  onPropertyFilterChange?: (propertyId: string) => void;
}

const BookingCalendar: React.FC<BookingCalendarProps> = ({
  bookings,
  bookedDates = [],
  onDateClick,
  propertyFilter,
  properties,
  onPropertyFilterChange
}) => {
  const [currentDate, setCurrentDate] = useState(new Date());

  // Get calendar data for current month
  const getCalendarData = () => {
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth();
    
    const firstDay = new Date(year, month, 1);
    const lastDay = new Date(year, month + 1, 0);
    const startDate = new Date(firstDay);
    startDate.setDate(startDate.getDate() - firstDay.getDay());
    
    const endDate = new Date(lastDay);
    endDate.setDate(endDate.getDate() + (6 - lastDay.getDay()));

    const days = [];
    const current = new Date(startDate);
    
    while (current <= endDate) {
      days.push(new Date(current));
      current.setDate(current.getDate() + 1);
    }
    
    return days;
  };

  // Filter bookings by property if specified
  const filteredBookings = propertyFilter && propertyFilter !== 'all'
    ? bookings.filter(b => b.property_id === propertyFilter)
    : bookings;

  // Get bookings for a specific date
  const getBookingsForDate = (date: Date) => {
    return filteredBookings.filter(booking => {
      const startDate = new Date(booking.start_date);
      const endDate = new Date(booking.end_date);
      return date >= startDate && date <= endDate;
    });
  };

  // Get status color for calendar display
  const getStatusColor = (status: string) => {
    switch (status) {
      case 'confirmed': return 'bg-green-500';
      case 'pending': return 'bg-yellow-500';
      case 'pending_payment': return 'bg-orange-500';
      case 'cancelled': return 'bg-red-500';
      case 'completed': return 'bg-blue-500';
      default: return 'bg-gray-500';
    }
  };

  const navigateMonth = (direction: 'prev' | 'next') => {
    const newDate = new Date(currentDate);
    newDate.setMonth(newDate.getMonth() + (direction === 'next' ? 1 : -1));
    setCurrentDate(newDate);
  };

  const calendarDays = getCalendarData();
  const monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  return (
    <div className="bg-white rounded-lg shadow p-6 text-gray-900">
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-2">
          <CalendarIcon size={24} className="text-gray-600" />
          <h2 className="text-xl font-semibold text-gray-900">Booking Calendar</h2>
        </div>
        
        {/* Property Filter */}
        {properties && onPropertyFilterChange && (
          <div className="flex items-center gap-2">
            <label className="text-sm font-medium text-gray-700">Property:</label>
            <select
              value={propertyFilter || 'all'}
              onChange={(e) => onPropertyFilterChange(e.target.value)}
              className="px-3 py-1 border border-gray-300 rounded focus:ring-2 focus:ring-green-500 focus:border-transparent text-gray-900"
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
      </div>

      {/* Month Navigation */}
      <div className="flex items-center justify-between mb-4">
        <button
          onClick={() => navigateMonth('prev')}
          className="p-2 hover:bg-gray-100 rounded-lg text-gray-600"
          aria-label="Previous month"
        >
          <ChevronLeft size={20} />
        </button>
        
        <h3 className="text-lg font-semibold">
          {monthNames[currentDate.getMonth()]} {currentDate.getFullYear()}
        </h3>
        
        <button
          onClick={() => navigateMonth('next')}
          className="p-2 hover:bg-gray-100 rounded-lg text-gray-600"
          aria-label="Next month"
        >
          <ChevronRight size={20} />
        </button>
      </div>

      {/* Calendar Grid */}
      <div className="grid grid-cols-7 gap-1 mb-2">
        {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map(day => (
          <div key={day} className="p-2 text-center text-sm font-medium text-gray-500">
            {day}
          </div>
        ))}
      </div>

      <div className="grid grid-cols-7 gap-1">
        {calendarDays.map((date, index) => {
          const dayBookings = getBookingsForDate(date);
          const dateStr = date.toISOString().split('T')[0];
          const isOccupied = bookedDates.includes(dateStr);
          const isCurrentMonth = date.getMonth() === currentDate.getMonth();
          const isToday = date.toDateString() === new Date().toDateString();

          return (
            <div
              key={index}
              onClick={() => onDateClick && onDateClick(date, dayBookings)}
              className={`
                relative p-2 min-h-[60px] border border-gray-200 cursor-pointer hover:bg-gray-50
                ${!isCurrentMonth ? 'text-gray-400 bg-gray-50' : ''}
                ${isToday ? 'bg-blue-50 border-blue-300 ring-1 ring-inset ring-blue-500' : ''}
                ${isOccupied ? 'bg-red-50 border-red-200' : ''}
              `}
            >
              <div className={`
                text-sm font-bold mb-1 w-7 h-7 flex items-center justify-center rounded-full
                ${isToday ? 'bg-blue-600 text-white' : ''}
                ${isOccupied ? 'text-red-600' : 'text-gray-700'}
              `}>
                {date.getDate()}
              </div>
              
              {/* Booking indicators */}
              <div className="space-y-1">
                {isOccupied && (
                  <div className="text-[10px] font-black text-red-500 uppercase tracking-tighter text-center">
                    Occupied
                  </div>
                )}
                {dayBookings.slice(0, 2).map((booking, bookingIndex) => (
                  <div
                    key={bookingIndex}
                    className={`
                      w-full h-1.5 rounded-full ${getStatusColor(booking.status)}
                    `}
                    title={`${booking.properties?.title || 'Property'} - ${booking.status}`}
                  />
                ))}
                {dayBookings.length > 2 && (
                  <div className="text-xs text-gray-500 text-center">
                    +{dayBookings.length - 2} more
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Legend */}
      <div className="mt-4 flex flex-wrap gap-4 text-sm">
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-red-50 border border-red-200 rounded-full"></div>
          <span className="text-red-600 font-bold">Occupied / Booked</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-blue-600 rounded-full"></div>
          <span className="text-blue-600 font-bold">Today</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-orange-500 rounded-full"></div>
          <span className="text-gray-700">Pending Payment</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-yellow-500 rounded-full"></div>
          <span className="text-gray-700">Pending</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-green-500 rounded-full"></div>
          <span className="text-gray-700">Confirmed</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-blue-500 rounded-full"></div>
          <span className="text-gray-700">Completed</span>
        </div>
        <div className="flex items-center gap-2">
          <div className="w-3 h-3 bg-red-500 rounded-full"></div>
          <span className="text-gray-700">Cancelled</span>
        </div>
      </div>
    </div>
  );
};

export default BookingCalendar;
