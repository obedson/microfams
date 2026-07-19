import React, { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Menu, X, Home, Search, User, LogOut, BookOpen, Package, Users, Calendar, Wallet } from 'lucide-react';
import { useAuthStore } from '../store/authStore';
import { MessageNotificationIcon } from './communication';
import Button from './ui/Button';
import ProfileDropdown from './ProfileDropdown';
import OrganizationSwitcher from './OrganizationSwitcher';

const Header: React.FC = () => {
  const [isMenuOpen, setIsMenuOpen] = useState(false);
  const { isAuthenticated, user, logout } = useAuthStore();
  const navigate = useNavigate();

  const handleLogout = () => {
    logout();
    navigate('/');
    setIsMenuOpen(false);
  };

  const navItems = [
    { to: '/', label: 'Home', icon: Home },
    { to: '/properties', label: 'Farms', icon: Search },
    { to: '/marketplace', label: 'Marketplace', icon: Package },
    { to: '/courses', label: 'Courses', icon: BookOpen },
    { to: '/groups', label: 'Groups', icon: Users },
  ];

  return (
    <header className="bg-white shadow-sm border-b border-gray-100 sticky top-0 z-50">
      <div className="container">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <Link to="/" className="flex items-center space-x-2">
            <div className="w-8 h-8 bg-primary-600 rounded-lg flex items-center justify-center">
              <span className="text-white font-bold text-lg">MF</span>
            </div>
            <span className="font-bold text-xl text-gray-900 hidden sm:block">
              Micro Fams
            </span>
          </Link>

          {/* Desktop Navigation */}
          <nav className="hidden md:flex items-center space-x-8">
            {navItems.map((item) => (
              <Link
                key={item.to}
                to={item.to}
                className="text-gray-600 hover:text-primary-600 font-medium transition-colors"
              >
                {item.label}
              </Link>
            ))}
          </nav>

          {/* Desktop Auth */}
          <div className="hidden md:flex items-center space-x-4">
            {isAuthenticated ? (
              <>
                <OrganizationSwitcher />
                <Link
                  to="/dashboard"
                  className="text-gray-600 hover:text-primary-600 font-medium transition-colors"
                >
                  Dashboard
                </Link>
                {user && <MessageNotificationIcon currentUserId={user.id} />}
                <ProfileDropdown />
              </>
            ) : (
              <>
                <Link to="/register">
                  <Button size="sm">Register</Button>
                </Link>
              </>
            )}
          </div>

          {/* Mobile Message Icon */}
          {isAuthenticated && user && (
            <div className="md:hidden flex items-center space-x-4">
              <MessageNotificationIcon currentUserId={user.id} />
              <ProfileDropdown />
            </div>
          )}

          {/* Mobile Menu Button */}
          <button
            className="md:hidden p-2 rounded-lg hover:bg-gray-100 transition-colors"
            onClick={() => setIsMenuOpen(!isMenuOpen)}
            aria-label="Toggle menu"
          >
            {isMenuOpen ? <X size={24} /> : <Menu size={24} />}
          </button>
        </div>

        {/* Mobile Menu */}
        {isMenuOpen && (
          <div className="md:hidden border-t border-gray-100 py-4 animate-fade-in">
            <nav className="space-y-2">
              {navItems.map((item) => {
                const Icon = item.icon;
                return (
                  <Link
                    key={item.to}
                    to={item.to}
                    className="flex items-center space-x-3 px-4 py-3 text-gray-600 hover:text-primary-600 hover:bg-gray-50 rounded-lg transition-colors"
                    onClick={() => setIsMenuOpen(false)}
                  >
                    <Icon size={20} />
                    <span>{item.label}</span>
                  </Link>
                );
              })}
              {isAuthenticated && (
                <div className="px-4 py-3"><OrganizationSwitcher /></div>
              )}
              
              {!isAuthenticated && (
                <Link
                  to="/register"
                  className="flex items-center space-x-3 px-4 py-3 text-gray-600 hover:text-primary-600 hover:bg-gray-50 rounded-lg transition-colors"
                  onClick={() => setIsMenuOpen(false)}
                >
                  <User size={20} />
                  <span>Register</span>
                </Link>
              )}
            </nav>
          </div>
        )}
      </div>
    </header>
  );
};

export default Header;
