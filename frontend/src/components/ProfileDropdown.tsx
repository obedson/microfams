import React, { useState, useEffect, useRef } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuthStore } from '../store/authStore';
import { User, LogOut, Wallet, MessageSquare, LayoutDashboard, Settings } from 'lucide-react';

export default function ProfileDropdown() {
  const { user, logout } = useAuthStore();
  const [isOpen, setIsOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    };

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('keydown', handleEscape);
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('keydown', handleEscape);
    };
  }, []);

  if (!user) return null;

  const getInitials = (name: string) => {
    return name
      .split(' ')
      .map((n) => n[0])
      .join('')
      .toUpperCase();
  };

  const menuItems = [
    { label: 'Dashboard', icon: LayoutDashboard, path: '/dashboard' },
    { label: 'Profile', icon: User, path: '/profile' },
    { label: 'Wallet', icon: Wallet, path: '/wallet' },
    { label: 'Messages', icon: MessageSquare, path: '/messages' },
    { label: 'Referrals', icon: User, path: '/referrals' },
    { label: 'Settings', icon: Settings, path: '/settings' },
  ];

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center gap-2 focus:outline-none"
      >
        <div className="w-10 h-10 rounded-full bg-primary-600 flex items-center justify-center text-white font-bold overflow-hidden border-2 border-white shadow-sm hover:border-primary-200 transition-all">
          {user.profile_picture_url ? (
            <img 
              src={user.profile_picture_url} 
              alt={user.name} 
              className="w-full h-full object-cover"
            />
          ) : (
            <span>{getInitials(user.name)}</span>
          )}
        </div>
      </button>

      {isOpen && (
        <div className="absolute right-0 mt-2 w-64 bg-white rounded-xl shadow-xl py-2 z-50 border border-gray-100 transform origin-top-right transition-all">
          <div className="px-4 py-3 border-b border-gray-50">
            <p className="text-sm font-semibold text-gray-900 truncate">{user.name}</p>
            <p className="text-xs text-gray-500 truncate">{user.email}</p>
          </div>

          <div className="py-1">
            {menuItems.map((item) => (
              <button
                key={item.label}
                onClick={() => {
                  setIsOpen(false);
                  navigate(item.path);
                }}
                className="w-full flex items-center gap-3 px-4 py-2 text-sm text-gray-700 hover:bg-gray-50 transition-colors"
              >
                <item.icon size={18} className="text-gray-400" />
                {item.label}
              </button>
            ))}
          </div>

          <div className="border-t border-gray-50 mt-1 pt-1">
            <button
              onClick={() => {
                setIsOpen(false);
                logout();
                navigate('/login');
              }}
              className="w-full flex items-center gap-3 px-4 py-2 text-sm text-red-600 hover:bg-red-50 transition-colors"
            >
              <LogOut size={18} />
              Logout
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
