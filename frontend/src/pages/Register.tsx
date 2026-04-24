import React from 'react';
import { useForm } from 'react-hook-form';
import { useMutation } from '@tanstack/react-query';
import { useNavigate, Link } from 'react-router-dom';
import { User, Mail, Lock, Phone, AlertCircle, UserCheck, Users } from 'lucide-react';
import { authAPI } from '../api/client';
import { useAuthStore } from '../store/authStore';
import Button from '../components/ui/Button';
import Card from '../components/ui/Card';

interface RegisterForm {
  name: string;
  email: string;
  password: string;
  role: 'farmer' | 'owner';
  phone?: string;
  referral_code?: string;
}

const Register: React.FC = () => {
  const { register, handleSubmit, formState: { errors }, watch } = useForm<RegisterForm>();
  const { login } = useAuthStore();
  const navigate = useNavigate();
  const selectedRole = watch('role');

  const registerMutation = useMutation(
    (data: RegisterForm) => authAPI.register(data),
    {
      onSuccess: (response) => {
        const { user, token, refreshToken } = response.data.data;
        login(user, token, refreshToken);
        navigate('/dashboard');
      },
      onError: (error: any) => {
        console.error('Registration error:', error);
        console.error('Error response:', error.response?.data);
      }
    }
  );

  const onSubmit = (data: RegisterForm) => {
    registerMutation.mutate(data);
  };

  return (
    <div className="min-h-[80vh] flex items-center justify-center py-8">
      <div className="w-full max-w-md">
        <Card className="p-6 md:p-8">
          {/* Header */}
          <div className="text-center mb-8">
            <div className="w-16 h-16 bg-primary-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <span className="text-white font-bold text-2xl">MF</span>
            </div>
            <h1 className="text-2xl md:text-3xl font-bold text-gray-900 mb-2">
              Join Micro Fams
            </h1>
            <p className="text-gray-600">
              Create your account to get started
            </p>
          </div>

          {/* Error Message */}
          {registerMutation.isError && (
            <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6 flex items-start">
              <AlertCircle size={20} className="text-red-500 mr-3 mt-0.5 flex-shrink-0" />
              <div>
                <p className="text-red-800 font-medium">Registration Failed</p>
                <p className="text-red-600 text-sm">
                  {(registerMutation.error as any)?.response?.data?.error || 'Please check your information and try again'}
                </p>
              </div>
            </div>
          )}

          {/* Form */}
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
            {/* Full Name */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Full Name
              </label>
              <div className="relative">
                <User size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
                <input
                  {...register('name', { 
                    required: 'Full name is required',
                    minLength: {
                      value: 2,
                      message: 'Name must be at least 2 characters'
                    }
                  })}
                  type="text"
                  placeholder="Enter your full name"
                  className={`w-full pl-10 pr-4 py-3 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors ${
                    errors.name ? 'border-red-300' : 'border-gray-300'
                  }`}
                />
              </div>
              {errors.name && (
                <p className="mt-1 text-sm text-red-600">{errors.name.message}</p>
              )}
            </div>

            {/* Email */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Email Address
              </label>
              <div className="relative">
                <Mail size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
                <input
                  {...register('email', { 
                    required: 'Email is required',
                    pattern: {
                      value: /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i,
                      message: 'Invalid email address'
                    }
                  })}
                  type="email"
                  placeholder="Enter your email"
                  className={`w-full pl-10 pr-4 py-3 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors ${
                    errors.email ? 'border-red-300' : 'border-gray-300'
                  }`}
                />
              </div>
              {errors.email && (
                <p className="mt-1 text-sm text-red-600">{errors.email.message}</p>
              )}
            </div>

            {/* Password */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Password
              </label>
              <div className="relative">
                <Lock size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
                <input
                  {...register('password', { 
                    required: 'Password is required',
                    minLength: {
                      value: 6,
                      message: 'Password must be at least 6 characters'
                    }
                  })}
                  type="password"
                  placeholder="Create a password"
                  className={`w-full pl-10 pr-4 py-3 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors ${
                    errors.password ? 'border-red-300' : 'border-gray-300'
                  }`}
                />
              </div>
              {errors.password && (
                <p className="mt-1 text-sm text-red-600">{errors.password.message}</p>
              )}
            </div>

            {/* Phone */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Phone Number <span className="text-gray-400">(Optional)</span>
              </label>
              <div className="relative">
                <Phone size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
                <input
                  {...register('phone')}
                  type="tel"
                  placeholder="Enter your phone number"
                  className="w-full pl-10 pr-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors"
                />
              </div>
            </div>

            {/* Referral Code */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Referral Code <span className="text-gray-400">(Optional)</span>
              </label>
              <div className="relative">
                <Users size={20} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
                <input
                  {...register('referral_code')}
                  type="text"
                  placeholder="Enter referral code"
                  className="w-full pl-10 pr-4 py-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent transition-colors"
                />
              </div>
            </div>

            {/* Role Selection */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-3">
                I am a...
              </label>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label className={`relative flex items-center p-4 border-2 rounded-lg cursor-pointer transition-colors ${
                  selectedRole === 'farmer' ? 'border-primary-500 bg-primary-50' : 'border-gray-200 hover:border-gray-300'
                }`}>
                  <input
                    {...register('role', { required: 'Please select your role' })}
                    type="radio"
                    value="farmer"
                    className="sr-only"
                  />
                  <div className="flex items-center">
                    <UserCheck size={20} className={`mr-3 ${selectedRole === 'farmer' ? 'text-primary-600' : 'text-gray-400'}`} />
                    <div>
                      <div className={`font-medium ${selectedRole === 'farmer' ? 'text-primary-900' : 'text-gray-900'}`}>
                        Farmer
                      </div>
                      <div className="text-sm text-gray-500">
                        Looking for space
                      </div>
                    </div>
                  </div>
                </label>

                <label className={`relative flex items-center p-4 border-2 rounded-lg cursor-pointer transition-colors ${
                  selectedRole === 'owner' ? 'border-primary-500 bg-primary-50' : 'border-gray-200 hover:border-gray-300'
                }`}>
                  <input
                    {...register('role', { required: 'Please select your role' })}
                    type="radio"
                    value="owner"
                    className="sr-only"
                  />
                  <div className="flex items-center">
                    <UserCheck size={20} className={`mr-3 ${selectedRole === 'owner' ? 'text-primary-600' : 'text-gray-400'}`} />
                    <div>
                      <div className={`font-medium ${selectedRole === 'owner' ? 'text-primary-900' : 'text-gray-900'}`}>
                        Property Owner
                      </div>
                      <div className="text-sm text-gray-500">
                        Renting out space
                      </div>
                    </div>
                  </div>
                </label>
              </div>
              {errors.role && (
                <p className="mt-2 text-sm text-red-600">{errors.role.message}</p>
              )}
            </div>

            <Button
              type="submit"
              loading={registerMutation.isLoading}
              className="w-full"
              size="lg"
            >
              {registerMutation.isLoading ? 'Creating Account...' : 'Create Account'}
            </Button>
          </form>

          {/* Footer */}
          <div className="mt-8 text-center">
            <p className="text-gray-600">
              Already have an account?{' '}
              <Link to="/login" className="text-primary-600 hover:text-primary-700 font-medium">
                Sign in here
              </Link>
            </p>
          </div>
        </Card>
      </div>
    </div>
  );
};

export default Register;
