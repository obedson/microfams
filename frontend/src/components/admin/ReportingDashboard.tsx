import React, { useState, useEffect } from 'react';
import { reportAPI, BookingReportSummary, EngagementReport, RetentionBI } from '../../services/reportAPI';
import { BarChart3, Users, Download, Calendar, Filter, PieChart, TrendingUp, Loader2 } from 'lucide-react';
import toast from 'react-hot-toast';

const ReportingDashboard: React.FC = () => {
  const [activeTab, setActiveTab] = useState<'bookings' | 'engagement' | 'export'>('bookings');
  const [loading, setLoading] = useState(false);
  const [dateRange, setDateRange] = useState({
    start: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().split('T')[0],
    end: new Date().toISOString().split('T')[0]
  });

  const [bookingData, setBookingData] = useState<{ summary: BookingReportSummary; bookings: any[] } | null>(null);
  const [engagementData, setEngagementData] = useState<EngagementReport | null>(null);

  const fetchBookingReport = async () => {
    setLoading(true);
    try {
      const data = await reportAPI.getBookingReport(dateRange.start, dateRange.end);
      setBookingData(data);
    } catch (error: any) {
      toast.error('Failed to fetch booking report');
    } finally {
      setLoading(false);
    }
  };

  const fetchEngagementReport = async () => {
    setLoading(true);
    try {
      const data = await reportAPI.getEngagementReport(30);
      setEngagementData(data);
    } catch (error: any) {
      toast.error('Failed to fetch engagement report');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (activeTab === 'bookings') fetchBookingReport();
    if (activeTab === 'engagement') fetchEngagementReport();
  }, [activeTab]);

  const handleExport = async (table: string) => {
    const fieldsMap: any = {
      'users': ['id', 'email', 'name', 'role', 'created_at'],
      'properties': ['id', 'title', 'city', 'livestock_type', 'price_per_month'],
      'bookings': ['id', 'property_id', 'farmer_id', 'total_amount', 'status', 'payment_status']
    };

    try {
      const blob = await reportAPI.exportData(table, fieldsMap[table]);
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${table}-export-${new Date().toISOString().split('T')[0]}.csv`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      toast.success(`${table} exported successfully`);
    } catch (error) {
      toast.error(`Failed to export ${table}`);
    }
  };

  return (
    <div className="space-y-8">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-black text-gray-900 uppercase tracking-tight">Business Intelligence</h2>
          <p className="text-sm text-gray-500 font-medium">Reporting, analytics, and data exports</p>
        </div>
        <div className="flex bg-gray-100 p-1 rounded-xl">
          <button
            onClick={() => setActiveTab('bookings')}
            className={`px-4 py-2 rounded-lg text-sm font-bold transition-all ${activeTab === 'bookings' ? 'bg-white text-primary-600 shadow-sm' : 'text-gray-500 hover:text-gray-700'}`}
          >
            Bookings
          </button>
          <button
            onClick={() => setActiveTab('engagement')}
            className={`px-4 py-2 rounded-lg text-sm font-bold transition-all ${activeTab === 'engagement' ? 'bg-white text-primary-600 shadow-sm' : 'text-gray-500 hover:text-gray-700'}`}
          >
            Engagement
          </button>
          <button
            onClick={() => setActiveTab('export')}
            className={`px-4 py-2 rounded-lg text-sm font-bold transition-all ${activeTab === 'export' ? 'bg-white text-primary-600 shadow-sm' : 'text-gray-500 hover:text-gray-700'}`}
          >
            Export
          </button>
        </div>
      </div>

      {activeTab === 'bookings' && (
        <div className="space-y-6">
          <div className="bg-white p-6 rounded-2xl border border-gray-100 shadow-sm flex flex-wrap items-end gap-4">
            <div className="flex-1 min-w-[200px]">
              <label className="block text-xs font-black text-gray-400 uppercase mb-2">Start Date</label>
              <div className="relative">
                <Calendar className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" size={18} />
                <input
                  type="date"
                  value={dateRange.start}
                  onChange={(e) => setDateRange({ ...dateRange, start: e.target.value })}
                  className="w-full pl-10 pr-4 py-2.5 bg-gray-50 border-none rounded-xl focus:ring-2 focus:ring-primary-500 outline-none font-medium"
                />
              </div>
            </div>
            <div className="flex-1 min-w-[200px]">
              <label className="block text-xs font-black text-gray-400 uppercase mb-2">End Date</label>
              <div className="relative">
                <Calendar className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" size={18} />
                <input
                  type="date"
                  value={dateRange.end}
                  onChange={(e) => setDateRange({ ...dateRange, end: e.target.value })}
                  className="w-full pl-10 pr-4 py-2.5 bg-gray-50 border-none rounded-xl focus:ring-2 focus:ring-primary-500 outline-none font-medium"
                />
              </div>
            </div>
            <button
              onClick={fetchBookingReport}
              disabled={loading}
              className="px-6 py-2.5 bg-primary-600 text-white rounded-xl font-bold hover:bg-primary-700 transition-colors flex items-center gap-2"
            >
              {loading ? <Loader2 className="animate-spin" size={20} /> : <Filter size={20} />}
              Update
            </button>
          </div>

          {bookingData && (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              <div className="bg-white p-6 rounded-2xl border border-gray-100 shadow-sm">
                <p className="text-xs font-bold text-gray-400 uppercase">Total Revenue</p>
                <p className="text-2xl font-black text-primary-600 mt-1">₦{bookingData.summary.total_revenue.toLocaleString()}</p>
              </div>
              <div className="bg-white p-6 rounded-2xl border border-gray-100 shadow-sm">
                <p className="text-xs font-bold text-gray-400 uppercase">Total Bookings</p>
                <p className="text-2xl font-black text-gray-900 mt-1">{bookingData.summary.total_bookings}</p>
              </div>
              <div className="bg-white p-6 rounded-2xl border border-gray-100 shadow-sm">
                <p className="text-xs font-bold text-gray-400 uppercase">Avg. Booking</p>
                <p className="text-2xl font-black text-gray-900 mt-1">
                  ₦{bookingData.summary.total_bookings > 0 
                    ? (bookingData.summary.total_revenue / bookingData.summary.total_bookings).toLocaleString(undefined, { maximumFractionDigits: 0 }) 
                    : 0}
                </p>
              </div>
              <div className="bg-white p-6 rounded-2xl border border-gray-100 shadow-sm">
                <p className="text-xs font-bold text-gray-400 uppercase">Completion Rate</p>
                <p className="text-2xl font-black text-green-600 mt-1">
                  {bookingData.summary.total_bookings > 0
                    ? ((bookingData.summary.status_breakdown['completed'] || 0) / bookingData.summary.total_bookings * 100).toFixed(1)
                    : 0}%
                </p>
              </div>
            </div>
          )}
        </div>
      )}

      {activeTab === 'engagement' && engagementData && (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-1 space-y-6">
            <div className="bg-primary-600 p-8 rounded-3xl text-white shadow-xl shadow-primary-100">
              <Users size={40} className="mb-4 opacity-80" />
              <p className="text-primary-100 font-bold uppercase tracking-widest text-xs">Active Users (30d)</p>
              <p className="text-5xl font-black mt-2">{engagementData.unique_active_users}</p>
              <div className="mt-6 pt-6 border-t border-primary-500/50">
                <p className="text-xs font-medium opacity-80">Total interactions recorded</p>
                <p className="text-xl font-bold">{engagementData.total_actions.toLocaleString()}</p>
              </div>
            </div>
          </div>

          <div className="lg:col-span-2 bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
            <div className="p-6 border-b border-gray-100">
              <h3 className="font-bold text-gray-900 flex items-center gap-2">
                <TrendingUp size={20} className="text-primary-600" />
                Top User Actions
              </h3>
            </div>
            <div className="p-6">
              <div className="space-y-4">
                {engagementData.top_actions.map(([action, count], index) => (
                  <div key={action} className="space-y-2">
                    <div className="flex justify-between text-sm">
                      <span className="font-bold text-gray-700 capitalize">{action.replace(/[._]/g, ' ')}</span>
                      <span className="text-gray-500 font-medium">{count.toLocaleString()}</span>
                    </div>
                    <div className="w-full bg-gray-50 rounded-full h-2">
                      <div 
                        className="bg-primary-500 h-2 rounded-full"
                        style={{ width: `${(count / engagementData.total_actions * 100) * 2}%` }} // Scaled for visibility
                      ></div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {activeTab === 'export' && (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          {['users', 'properties', 'bookings'].map((table) => (
            <div key={table} className="bg-white p-8 rounded-2xl border border-gray-100 shadow-sm text-center space-y-4 group hover:border-primary-200 transition-colors">
              <div className="w-16 h-16 bg-gray-50 rounded-2xl flex items-center justify-center mx-auto text-gray-400 group-hover:text-primary-600 group-hover:bg-primary-50 transition-all">
                <Download size={32} />
              </div>
              <div>
                <h4 className="text-lg font-black text-gray-900 uppercase tracking-tight">{table}</h4>
                <p className="text-xs text-gray-500 font-medium">Download complete {table} data in CSV format.</p>
              </div>
              <button
                onClick={() => handleExport(table)}
                className="w-full py-3 bg-gray-900 text-white rounded-xl font-bold hover:bg-black transition-colors"
              >
                Export CSV
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default ReportingDashboard;
