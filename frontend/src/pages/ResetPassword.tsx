import React, { useState, useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { useMutation } from '@tanstack/react-query';
import { useNavigate, useSearchParams, Link } from 'react-router-dom';
import { Lock, AlertCircle, CheckCircle } from 'lucide-react';
import { authAPI } from '../api/client';
import Button from '../components/ui/Button';
import PasswordInput from '../components/ui/PasswordInput';
import Card from '../components/ui/Card';

interface ResetPasswordForm {
  password: string;
  confirmPassword: string;
}

const ResetPassword: React.FC = () => {
  const [searchParams] = useSearchParams();
  const [resetSuccess, setResetSuccess] = useState(false);
  const navigate = useNavigate();
  const token = searchParams.get('token');

  const { register, handleSubmit, formState: { errors }, watch } = useForm<ResetPasswordForm>();
  const password = watch('password');

  useEffect(() => {
    if (!token) {
      navigate('/login');
    }
  }, [token, navigate]);

  const resetPasswordMutation = useMutation({
    mutationFn: ({ password }: { password: string }) => 
      authAPI.resetPassword(token!, password),
    onSuccess: () => {
      setResetSuccess(true);
      setTimeout(() => navigate('/login'), 3000);
    },
  });

  const onSubmit = (data: ResetPasswordForm) => {
    resetPasswordMutation.mutate({ password: data.password });
  };

  if (resetSuccess) {
    return (
      <div className="min-h-[80vh] flex items-center justify-center">
        <div className="w-full max-w-md">
          <Card className="p-6 md:p-8 text-center">
            <div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4">
              <CheckCircle size={32} className="text-green-600" />
            </div>
            <h1 className="text-2xl font-bold text-gray-900 mb-2">
              Password Reset Successfully
            </h1>
            <p className="text-gray-600 mb-6">
              Your password has been updated. You'll be redirected to login shortly.
            </p>
            <Link to="/login">
              <Button className="w-full">
                Go to Login
              </Button>
            </Link>
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
              <Lock size={32} className="text-white" />
            </div>
            <h1 className="text-2xl md:text-3xl font-bold text-gray-900 mb-2">
              Reset Password
            </h1>
            <p className="text-gray-600">
              Enter your new password below
            </p>
          </div>

          {resetPasswordMutation.isError && (
            <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6 flex items-start">
              <AlertCircle size={20} className="text-red-500 mr-3 mt-0.5 flex-shrink-0" />
              <div>
                <p className="text-red-800 font-medium">Reset Failed</p>
                <p className="text-red-600 text-sm">
                  {(resetPasswordMutation.error as any)?.response?.data?.error || 'Invalid or expired token'}
                </p>
              </div>
            </div>
          )}

          <form onSubmit={handleSubmit(onSubmit)} className="space-y-6">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                New Password
              </label>
              <PasswordInput
                {...register('password', { 
                  required: 'Password is required',
                  minLength: {
                    value: 6,
                    message: 'Password must be at least 6 characters'
                  }
                })}
                placeholder="Enter new password"
                error={!!errors.password}
              />
              {errors.password && (
                <p className="mt-1 text-sm text-red-600">{errors.password.message}</p>
              )}
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Confirm Password
              </label>
              <PasswordInput
                {...register('confirmPassword', { 
                  required: 'Please confirm your password',
                  validate: value => value === password || 'Passwords do not match'
                })}
                placeholder="Confirm new password"
                error={!!errors.confirmPassword}
              />
              {errors.confirmPassword && (
                <p className="mt-1 text-sm text-red-600">{errors.confirmPassword.message}</p>
              )}
            </div>

            <Button
              type="submit"
              loading={resetPasswordMutation.isPending}
              className="w-full"
              size="lg"
            >
              {resetPasswordMutation.isPending ? 'Resetting...' : 'Reset Password'}
            </Button>
          </form>

          <div className="mt-8 text-center">
            <Link to="/login" className="text-primary-600 hover:text-primary-700 font-medium">
              Back to Login
            </Link>
          </div>
        </Card>
      </div>
    </div>
  );
};

export default ResetPassword;
