import React, { useState } from 'react';
import { useForm } from 'react-hook-form';
import { useMutation } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { Mail, AlertCircle, CheckCircle, ArrowLeft } from 'lucide-react';
import { authAPI } from '../api/client';
import Button from '../components/ui/Button';
import Card from '../components/ui/Card';

interface ForgotPasswordForm {
  email: string;
}

const ForgotPassword: React.FC = () => {
  const [emailSent, setEmailSent] = useState(false);
  const { register, handleSubmit, formState: { errors }, getValues } = useForm<ForgotPasswordForm>();

  const forgotPasswordMutation = useMutation({
    mutationFn: ({ email }: ForgotPasswordForm) => authAPI.forgotPassword(email),
    onSuccess: () => {
      setEmailSent(true);
    },
  });

  const onSubmit = (data: ForgotPasswordForm) => {
    forgotPasswordMutation.mutate(data);
  };

  if (emailSent) {
    return (
      <div className="min-h-[80vh] flex items-center justify-center">
        <div className="w-full max-w-md">
          <Card className="p-6 md:p-8 text-center">
            <div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4">
              <CheckCircle size={32} className="text-green-600" />
            </div>
            <h1 className="text-2xl font-bold text-gray-900 mb-2">
              Check Your Email
            </h1>
            <p className="text-gray-600 mb-6">
              We've sent a password reset link to <strong>{getValues('email')}</strong>
            </p>
            <p className="text-sm text-gray-500 mb-6">
              Didn't receive the email? Check your spam folder or try again.
            </p>
            <div className="space-y-3">
              <Button
                onClick={() => setEmailSent(false)}
                variant="outline"
                className="w-full"
              >
                Try Different Email
              </Button>
              <Link to="/login" className="block">
                <Button variant="outline" className="w-full">
                  <ArrowLeft size={16} className="mr-2" />
                  Back to Login
                </Button>
              </Link>
            </div>
          </Card>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-[80vh] flex items-center justify-center">
      <div className="w-full max-w-md">
        <Card className="p-6 md:p-8">
          <div className="text-center mb-8">
            <div className="w-16 h-16 bg-primary-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <Mail size={32} className="text-white" />
            </div>
            <h1 className="text-2xl md:text-3xl font-bold text-gray-900 mb-2">
              Forgot Password?
            </h1>
            <p className="text-gray-600">
              Enter your email and we'll send you a reset link
            </p>
          </div>

          {forgotPasswordMutation.isError && (
            <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6 flex items-start">
              <AlertCircle size={20} className="text-red-500 mr-3 mt-0.5 flex-shrink-0" />
              <div>
                <p className="text-red-800 font-medium">Error</p>
                <p className="text-red-600 text-sm">
                  {(forgotPasswordMutation.error as any)?.response?.data?.error || 'Something went wrong'}
                </p>
              </div>
            </div>
          )}

          <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
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

            <Button
              type="submit"
              loading={forgotPasswordMutation.isPending}
              className="w-full"
              size="lg"
            >
              {forgotPasswordMutation.isPending ? 'Sending...' : 'Send Reset Link'}
            </Button>
          </form>

          <div className="mt-8 text-center">
            <Link to="/login" className="text-primary-600 hover:text-primary-700 font-medium flex items-center justify-center">
              <ArrowLeft size={16} className="mr-2" />
              Back to Login
            </Link>
          </div>
        </Card>
      </div>
    </div>
  );
};

export default ForgotPassword;
