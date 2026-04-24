import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { profileApi } from '../services/profileAPI';
import { useAuthStore } from '../store/authStore';
import { Camera, Shield, Mail, Phone, Calendar, User, Link as LinkIcon, AlertTriangle, CheckCircle } from 'lucide-react';
import toast from 'react-hot-toast';
import { Link } from 'react-router-dom';

export default function Profile() {
  const queryClient = useQueryClient();
  const { user: authUser } = useAuthStore();
  const [isUploading, setIsUploading] = useState(false);

  const { data: profile, isLoading } = useQuery({
    queryKey: ['profile'],
    queryFn: () => profileApi.getProfile().then((res: any) => res.data)
  });

  const uploadMutation = useMutation({
    mutationFn: profileApi.uploadProfilePicture,
    onSuccess: (res) => {
      toast.success('Profile picture updated');
      queryClient.invalidateQueries({ queryKey: ['profile'] });
      // Update local storage/store if needed
    },
    onError: (err: any) => toast.error(err.response?.data?.error || 'Upload failed')
  });

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      uploadMutation.mutate(file);
    }
  };

  if (isLoading) return <div className="p-8 text-center">Loading Profile...</div>;

  return (
    <div className="max-w-4xl mx-auto px-4 py-10">
      <h1 className="text-3xl font-bold text-gray-900 mb-8">My Profile</h1>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
        {/* Left Column: Avatar & Basic Info */}
        <div className="md:col-span-1 space-y-6">
          <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100 text-center">
            <div className="relative inline-block group">
              <div className="w-32 h-32 rounded-full bg-primary-100 flex items-center justify-center text-primary-600 text-4xl font-bold overflow-hidden border-4 border-white shadow-md">
                {profile?.profile_picture_url ? (
                  <img src={profile.profile_picture_url} alt="Avatar" className="w-full h-full object-cover" />
                ) : (
                  <span>{profile?.name?.split(' ').map((n: any) => n[0]).join('').toUpperCase()}</span>
                )}
              </div>
              <label className="absolute bottom-0 right-0 p-2 bg-white rounded-full shadow-lg border border-gray-100 cursor-pointer hover:bg-gray-50 transition-colors">
                <Camera size={20} className="text-gray-600" />
                <input type="file" className="hidden" accept="image/*" onChange={handleFileChange} />
              </label>
            </div>
            <h2 className="mt-4 text-xl font-bold text-gray-900">{profile?.name}</h2>
            <p className="text-gray-500 text-sm capitalize">{profile?.role}</p>
            
            <div className="mt-6 pt-6 border-t border-gray-50 space-y-3 text-left">
              <div className="flex items-center gap-3 text-sm text-gray-600">
                <Mail size={16} className="text-gray-400" />
                <span className="truncate">{profile?.email}</span>
              </div>
              <div className="flex items-center gap-3 text-sm text-gray-600">
                <Phone size={16} className="text-gray-400" />
                <span>{profile?.phone || 'Not set'}</span>
              </div>
              <div className="flex items-center gap-3 text-sm text-gray-600">
                <Calendar size={16} className="text-gray-400" />
                <span>Joined {new Date(profile?.created_at).toLocaleDateString()}</span>
              </div>
            </div>
          </div>

          <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100">
            <h3 className="font-bold text-gray-900 mb-4 flex items-center gap-2">
              <Shield size={18} className="text-primary-600" /> Identity Verification
            </h3>
            {profile?.nin_verified ? (
              <div className="bg-green-50 p-4 rounded-xl border border-green-100 flex items-center gap-3">
                <CheckCircle className="text-green-600" size={24} />
                <div>
                  <p className="text-green-800 font-semibold text-sm">NIN Verified</p>
                  <p className="text-green-600 text-xs">{profile.nin_number}</p>
                </div>
              </div>
            ) : (
              <div className="bg-yellow-50 p-4 rounded-xl border border-yellow-100 space-y-3">
                <div className="flex items-start gap-3">
                  <AlertTriangle className="text-yellow-600 shrink-0" size={20} />
                  <p className="text-yellow-800 text-sm">Your identity is not yet verified. Verification is required to join groups and use the wallet.</p>
                </div>
                <Link 
                  to="/verify-nin" 
                  className="block w-full text-center py-2 bg-yellow-600 text-white rounded-lg text-sm font-medium hover:bg-yellow-700 transition-colors"
                >
                  Verify Now
                </Link>
              </div>
            )}
          </div>
        </div>

        {/* Right Column: Detailed Info */}
        <div className="md:col-span-2 space-y-6">
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="px-6 py-4 bg-gray-50 border-b border-gray-100">
              <h3 className="font-bold text-gray-900">Personal Information</h3>
            </div>
            <div className="p-6 grid grid-cols-1 sm:grid-cols-2 gap-6">
              <div className="space-y-1">
                <p className="text-xs text-gray-500 uppercase font-semibold">Full Name (from NIN)</p>
                <p className="text-gray-900 font-medium">{profile?.nin_full_name || 'Not verified'}</p>
              </div>
              <div className="space-y-1">
                <p className="text-xs text-gray-500 uppercase font-semibold">Date of Birth</p>
                <p className="text-gray-900 font-medium">{profile?.nin_date_of_birth || 'Not verified'}</p>
              </div>
              <div className="space-y-1">
                <p className="text-xs text-gray-500 uppercase font-semibold">Gender</p>
                <p className="text-gray-900 font-medium capitalize">{profile?.nin_gender || 'Not verified'}</p>
              </div>
              <div className="space-y-1">
                <p className="text-xs text-gray-500 uppercase font-semibold">Phone (NIN Registered)</p>
                <p className="text-gray-900 font-medium">{profile?.nin_phone || 'Not verified'}</p>
              </div>
              <div className="sm:col-span-2 space-y-1">
                <p className="text-xs text-gray-500 uppercase font-semibold">Address (from NIN)</p>
                <p className="text-gray-900 font-medium leading-relaxed">{profile?.nin_address || 'Not verified'}</p>
              </div>
            </div>
          </div>

          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="px-6 py-4 bg-gray-50 border-b border-gray-100">
              <h3 className="font-bold text-gray-900">Platform Status</h3>
            </div>
            <div className="p-6 space-y-6">
              <div className="flex items-center justify-between">
                <div>
                  <p className="font-semibold text-gray-900">Membership Subscription</p>
                  <p className="text-sm text-gray-500">Premium platform features and group access</p>
                </div>
                {profile?.is_platform_subscriber ? (
                  <span className="px-3 py-1 bg-primary-100 text-primary-700 rounded-full text-xs font-bold uppercase tracking-wider">Active</span>
                ) : (
                  <Link 
                    to="/become-a-member" 
                    className="px-4 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
                  >
                    Subscribe
                  </Link>
                )}
              </div>

              <div className="flex items-center justify-between pt-6 border-t border-gray-50">
                <div>
                  <p className="font-semibold text-gray-900">Referral Program</p>
                  <p className="text-sm text-gray-500">Earn rewards by inviting others to the platform</p>
                </div>
                <div className="flex items-center gap-2">
                  <div className="bg-gray-100 px-3 py-1 rounded-lg text-sm font-mono text-gray-700">{profile?.referral_code}</div>
                  <button onClick={() => {
                    navigator.clipboard.writeText(profile?.referral_code || '');
                    toast.success('Code copied!');
                  }} className="p-2 text-gray-400 hover:text-primary-600 transition-colors">
                    <LinkIcon size={18} />
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
