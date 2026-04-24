import React, { useState } from 'react';
import { adminAPI } from '../../services/adminAPI';
import { Shield, Smartphone, CheckCircle2, AlertCircle, Loader2 } from 'lucide-react';
import toast from 'react-hot-toast';

const MFASetup: React.FC = () => {
  const [step, setSetupStep] = useState<'initial' | 'setup' | 'verify' | 'completed'>('initial');
  const [qrCode, setQrCode] = useState<string>('');
  const [secret, setSecret] = useState<string>('');
  const [token, setToken] = useState<string>('');
  const [loading, setLoading] = useState(false);

  const handleStartSetup = async () => {
    setLoading(true);
    try {
      const data = await adminAPI.setupMFA();
      setQrCode(data.qrCode);
      setSecret(data.secret);
      setSetupStep('setup');
    } catch (error: any) {
      toast.error('Failed to initialize MFA setup');
    } finally {
      setLoading(false);
    }
  };

  const handleVerify = async (e: React.FormEvent) => {
    e.preventDefault();
    if (token.length !== 6) {
      toast.error('Please enter a 6-digit code');
      return;
    }

    setLoading(true);
    try {
      await adminAPI.verifyMFA(token);
      setSetupStep('completed');
      toast.success('MFA enabled successfully!');
    } catch (error: any) {
      toast.error(error.message || 'Invalid verification code');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
      <div className="bg-primary-600 px-6 py-4 flex items-center gap-3">
        <Shield className="text-white" size={24} />
        <h3 className="text-white font-bold">Account Security</h3>
      </div>

      <div className="p-6">
        {step === 'initial' && (
          <div className="text-center space-y-4 py-4">
            <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center mx-auto text-primary-600">
              <Shield size={32} />
            </div>
            <div>
              <h4 className="text-lg font-bold text-gray-900">Multi-Factor Authentication</h4>
              <p className="text-sm text-gray-500 max-w-xs mx-auto mt-1">
                Add an extra layer of security to your account by requiring a code from your phone.
              </p>
            </div>
            <button
              onClick={handleStartSetup}
              disabled={loading}
              className="w-full bg-primary-600 text-white py-3 rounded-xl font-bold hover:bg-primary-700 transition-colors flex items-center justify-center gap-2"
            >
              {loading ? <Loader2 className="animate-spin" size={20} /> : 'Enable MFA Now'}
            </button>
          </div>
        )}

        {step === 'setup' && (
          <div className="space-y-6">
            <div className="flex items-center gap-3 p-4 bg-blue-50 text-blue-700 rounded-xl text-sm border border-blue-100">
              <Smartphone className="flex-shrink-0" size={20} />
              <p>Scan this QR code with an authenticator app like Google Authenticator or Authy.</p>
            </div>
            
            <div className="flex justify-center p-4 bg-gray-50 rounded-xl border border-dashed border-gray-200">
              <img src={qrCode} alt="MFA QR Code" className="w-48 h-48" />
            </div>

            <div className="text-center">
              <p className="text-xs text-gray-400 font-bold uppercase tracking-widest">Manual Entry Code</p>
              <p className="text-sm font-mono text-gray-700 mt-1 select-all">{secret}</p>
            </div>

            <button
              onClick={() => setSetupStep('verify')}
              className="w-full bg-gray-900 text-white py-3 rounded-xl font-bold hover:bg-black transition-colors"
            >
              I've scanned the code
            </button>
          </div>
        )}

        {step === 'verify' && (
          <form onSubmit={handleVerify} className="space-y-6">
            <div className="text-center">
              <h4 className="text-lg font-bold text-gray-900">Verify MFA</h4>
              <p className="text-sm text-gray-500 mt-1">Enter the 6-digit code from your app.</p>
            </div>

            <input
              type="text"
              value={token}
              onChange={(e) => setToken(e.target.value.replace(/\D/g, '').slice(0, 6))}
              placeholder="000000"
              className="w-full text-center text-3xl font-black tracking-[0.5em] py-4 border-2 border-gray-100 rounded-xl focus:border-primary-500 focus:ring-0 outline-none transition-all"
              required
            />

            <div className="flex gap-3">
              <button
                type="button"
                onClick={() => setSetupStep('setup')}
                className="flex-1 bg-gray-100 text-gray-600 py-3 rounded-xl font-bold hover:bg-gray-200 transition-colors"
              >
                Back
              </button>
              <button
                type="submit"
                disabled={loading || token.length !== 6}
                className="flex-2 bg-primary-600 text-white px-8 py-3 rounded-xl font-bold hover:bg-primary-700 disabled:bg-gray-200 disabled:text-gray-400 transition-all flex items-center justify-center gap-2"
              >
                {loading ? <Loader2 className="animate-spin" size={20} /> : 'Verify & Enable'}
              </button>
            </div>
          </form>
        )}

        {step === 'completed' && (
          <div className="text-center space-y-4 py-4">
            <div className="w-16 h-16 bg-green-50 rounded-full flex items-center justify-center mx-auto text-green-600">
              <CheckCircle2 size={32} />
            </div>
            <div>
              <h4 className="text-lg font-bold text-gray-900">MFA is Active</h4>
              <p className="text-sm text-gray-500 mt-1">
                Your account is now protected with multi-factor authentication.
              </p>
            </div>
            <div className="p-4 bg-gray-50 rounded-xl text-left border border-gray-100">
              <div className="flex items-start gap-3">
                <AlertCircle className="text-amber-500 flex-shrink-0 mt-0.5" size={16} />
                <p className="text-xs text-gray-600 leading-relaxed">
                  Make sure you have your authenticator app handy whenever you sign in or perform high-value transactions.
                </p>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default MFASetup;
