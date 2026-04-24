import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import toast from 'react-hot-toast';
import { LoadingSpinner } from '../components/Loading';
import { adminAPI } from '../services/adminAPI';
import { ShieldAlert, Activity, Users, Home, Calendar, DollarSign, ChevronRight, BarChart3 } from 'lucide-react';
import ReportingDashboard from '../components/admin/ReportingDashboard';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3001/api';

export default function AdminDashboard() {
  const [stats, setStats] = useState({
    totalUsers: 0,
    totalProperties: 0,
    totalBookings: 0,
    totalRevenue: 0,
  });
  const [securityAlerts, setSecurityAlerts] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    fetchStats();
    fetchAlerts();
  }, []);

  const fetchStats = async () => {
    setLoading(true);
    try {
      const token = localStorage.getItem('token');
      const { data } = await axios.get(`${API_URL}/admin/stats`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      setStats(data);
    } catch (error) {
      toast.error('Failed to load stats');
    } finally {
      setLoading(false);
    }
  };

  const fetchAlerts = async () => {
    try {
      const alerts = await adminAPI.getSecurityAlerts();
      setSecurityAlerts(alerts);
    } catch (error) {
      console.error('Failed to load security alerts');
    }
  };

  if (loading) return <LoadingSpinner size="lg" />;

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">Admin Dashboard</h1>

      <div className="grid grid-cols-1 md:grid-cols-4 gap-6 mb-8">
        <StatCard title="Total Users" value={stats.totalUsers} color="blue" />
        <StatCard title="Properties" value={stats.totalProperties} color="green" />
        <StatCard title="Bookings" value={stats.totalBookings} color="purple" />
        <StatCard title="Revenue" value={`₦${stats.totalRevenue?.toLocaleString()}`} color="yellow" />
      </div>

      <div className="mb-12">
        <ReportingDashboard />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div className="lg:col-span-2">
          <div className="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="p-6 border-b border-gray-100 flex items-center justify-between">
              <h2 className="text-xl font-bold text-gray-900 flex items-center gap-2">
                <Activity className="text-primary-600" size={20} />
                Quick Actions
              </h2>
            </div>
            <div className="p-6 grid grid-cols-1 md:grid-cols-2 gap-4">
              <QuickAction icon={<Users size={20} />} title="Manage Users" onClick={() => navigate('/admin/users')} />
              <QuickAction icon={<Home size={20} />} title="Manage Properties" onClick={() => navigate('/admin/properties')} />
              <QuickAction icon={<Calendar size={20} />} title="View Bookings" onClick={() => navigate('/admin/bookings')} />
              <QuickAction icon={<Activity size={20} />} title="Audit Logs" onClick={() => navigate('/admin/audit-logs')} />
            </div>
          </div>
        </div>

        <div>
          <div className="bg-white rounded-xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="p-6 border-b border-gray-100 bg-red-50">
              <h2 className="text-lg font-bold text-red-800 flex items-center gap-2">
                <ShieldAlert size={20} />
                Security Alerts
              </h2>
            </div>
            <div className="divide-y divide-gray-100">
              {securityAlerts.length > 0 ? (
                securityAlerts.map((alert) => (
                  <div key={alert.id} className="p-4 hover:bg-gray-50 transition-colors">
                    <div className="flex items-start justify-between">
                      <div>
                        <p className="text-sm font-bold text-gray-900">{alert.action?.replace('_', ' ').toUpperCase()}</p>
                        <p className="text-xs text-gray-500 mt-0.5">{alert.users?.email || 'Unknown User'}</p>
                      </div>
                      <span className="text-[10px] font-medium text-gray-400">
                        {new Date(alert.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </span>
                    </div>
                    <p className="text-xs text-gray-600 mt-2 line-clamp-2">
                      {alert.details?.reason || 'Suspicious activity detected'}
                    </p>
                  </div>
                ))
              ) : (
                <div className="p-8 text-center">
                  <p className="text-sm text-gray-400">No active security alerts</p>
                </div>
              )}
            </div>
            {securityAlerts.length > 0 && (
              <button 
                onClick={() => navigate('/admin/audit-logs?status=warning')}
                className="w-full p-4 text-sm font-bold text-primary-600 hover:bg-primary-50 transition-colors border-t border-gray-100 flex items-center justify-center gap-1"
              >
                View all alerts <ChevronRight size={16} />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

const StatCard = ({ title, value, color }: { title: string; value: string | number; color: string }) => {
  const colorMap: any = {
    blue: 'text-blue-600 bg-blue-50',
    green: 'text-green-600 bg-green-50',
    purple: 'text-purple-600 bg-purple-50',
    yellow: 'text-amber-600 bg-amber-50'
  };
  
  const iconMap: any = {
    "Total Users": <Users size={20} />,
    "Properties": <Home size={20} />,
    "Bookings": <Calendar size={20} />,
    "Revenue": <DollarSign size={20} />
  };

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-100 p-6 flex items-start justify-between">
      <div>
        <p className="text-gray-500 text-sm font-medium">{title}</p>
        <p className="text-2xl font-black text-gray-900 mt-1">{value}</p>
      </div>
      <div className={`p-3 rounded-lg ${colorMap[color] || 'bg-gray-50'}`}>
        {iconMap[title]}
      </div>
    </div>
  );
};

const QuickAction = ({ title, icon, onClick }: { title: string; icon: React.ReactNode; onClick: () => void }) => (
  <button
    onClick={onClick}
    className="flex items-center justify-between p-4 rounded-xl border border-gray-100 hover:border-primary-200 hover:bg-primary-50 transition-all group"
  >
    <div className="flex items-center gap-3">
      <div className="text-gray-400 group-hover:text-primary-600 transition-colors">
        {icon}
      </div>
      <p className="font-bold text-gray-700 group-hover:text-primary-700">{title}</p>
    </div>
    <ChevronRight size={18} className="text-gray-300 group-hover:text-primary-400" />
  </button>
);
