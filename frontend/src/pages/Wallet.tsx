import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { walletApi } from '../api/wallet';
import { Wallet, Send, ArrowDownCircle, RefreshCw, Clock, ShieldAlert } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuthStore } from '../store/authStore';
import { useNavigate } from 'react-router-dom';
import { formatNgnMinor, parseNgnMinor } from '../utils/walletMoney';

export default function WalletPage() {
  const today = new Date().toISOString().slice(0, 10);
  const queryClient = useQueryClient();
  const { user } = useAuthStore();
  const navigate = useNavigate();
  const [p2pData, setP2pData] = useState({ recipientEmail: '', amount: '' });
  const [p2pCommandKey, setP2pCommandKey] = useState('');
  const [recipientInfo, setRecipientInfo] = useState<{name: string, nin_verified: boolean} | null>(null);
  const [withdrawData, setWithdrawData] = useState({ accountNumber: '', bankCode: '044', amount: '' });
  const [preview, setPreview] = useState<any>(null);
  const [statementDates, setStatementDates] = useState({
    from: `${today.slice(0, 7)}-01`,
    to: today,
  });
  const [statementRequest, setStatementRequest] = useState({
    from: `${today.slice(0, 7)}-01`,
    to: today,
    cutoff: new Date().toISOString(),
  });

  const { data: walletData, isLoading } = useQuery({
    queryKey: ['wallet'],
    queryFn: () => walletApi.getWallet().then(res => res.data)
  });

  const { data: statement, isLoading: statementLoading, isError: statementError } = useQuery({
    queryKey: ['wallet-statement', statementRequest],
    queryFn: () => walletApi.getStatement(
      statementRequest.from,
      statementRequest.to,
      statementRequest.cutoff,
    ).then(res => res.data),
  });

  const lookupMutation = useMutation({
    mutationFn: (email: string) => walletApi.lookupP2PRecipient(email),
    onSuccess: (res) => {
      setRecipientInfo(res.data);
    },
    onError: (err: any) => {
      toast.error(err.response?.data?.error || 'User not found');
      setRecipientInfo(null);
    }
  });

  const p2pMutation = useMutation({
    mutationFn: (data: typeof p2pData) => walletApi.initiateP2P(
      data.recipientEmail,
      parseNgnMinor(data.amount),
      p2pCommandKey,
    ),
    onSuccess: () => {
      toast.success('P2P Transfer Successful');
      queryClient.invalidateQueries({ queryKey: ['wallet'] });
      setP2pData({ recipientEmail: '', amount: '' });
      setP2pCommandKey('');
      setRecipientInfo(null);
    },
    onError: (err: any) => {
      const errorMsg = err.response?.data?.error || err.message || 'Transfer failed';
      // Clean up backend error class prefixes to make it user friendly
      const cleanMsg = errorMsg.replace('InsufficientFundsError: ', '').replace('LedgerTransactionError: ', '');
      toast.error(cleanMsg, { duration: 6000 });
      setRecipientInfo(null);
    }
  });

  const handleVerifyP2P = () => {
    if (!p2pData.recipientEmail) {
      return toast.error('Please enter a recipient email');
    }
    try {
      if (parseNgnMinor(p2pData.amount) < 10000) return toast.error('Minimum transfer amount is ₦100');
    } catch (error: any) {
      return toast.error(error.message);
    }
    setP2pCommandKey(crypto.randomUUID());
    lookupMutation.mutate(p2pData.recipientEmail);
  };

  const previewMutation = useMutation({
    mutationFn: walletApi.previewWithdrawal,
    onSuccess: (res) => setPreview(res.data),
    onError: (err: any) => toast.error(err.response?.data?.error || 'Preview failed')
  });

  const confirmMutation = useMutation({
    mutationFn: walletApi.confirmWithdrawal,
    onSuccess: () => {
      toast.success('Withdrawal Initiated');
      setPreview(null);
      queryClient.invalidateQueries({ queryKey: ['wallet'] });
    },
    onError: (err: any) => toast.error(err.response?.data?.error || 'Confirmation failed')
  });

  const syncMutation = useMutation({
    mutationFn: (txId: string) => walletApi.syncWithdrawal(txId),
    onSuccess: () => {
      toast.success('Status Synced');
      queryClient.invalidateQueries({ queryKey: ['wallet'] });
    },
    onError: (err: any) => toast.error(err.response?.data?.error || 'Sync failed')
  });

  if (isLoading) return <div className="p-8 text-center">Loading Wallet...</div>;

  const wallet = walletData?.wallet;
  const transactions = walletData?.transactions || [];

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      {!user?.nin_verified && (
        <div className="mb-8 bg-amber-50 border border-amber-200 rounded-2xl p-6 shadow-sm flex flex-col md:flex-row items-center justify-between gap-4">
          <div className="flex items-center gap-4">
            <div className="p-3 bg-amber-100 text-amber-600 rounded-xl">
              <ShieldAlert size={24} />
            </div>
            <div>
              <p className="font-bold text-amber-900">Identity Verification Required</p>
              <p className="text-amber-700 text-sm">Verify your NIN to unlock P2P transfers and bank withdrawals.</p>
            </div>
          </div>
          <button 
            onClick={() => navigate('/verify-nin')}
            className="px-6 py-2 bg-amber-600 text-white rounded-lg font-bold hover:bg-amber-700 transition-colors whitespace-nowrap"
          >
            Verify Now
          </button>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
        {/* Sidebar: Balance & Actions */}
        <div className="md:col-span-1 space-y-6">
          <div className="bg-green-600 text-white rounded-2xl p-8 shadow-lg">
            <div className="flex items-center gap-3 mb-4">
              <Wallet size={24} />
              <span className="font-medium">Total Balance</span>
            </div>
            <h2 className="text-4xl font-bold">{formatNgnMinor(wallet?.availableBalanceMinor || 0)}</h2>
            <p className="mt-2 text-green-100 text-xs">Ledger: {formatNgnMinor(wallet?.ledgerBalanceMinor || 0)}</p>
            <p className="mt-2 text-green-100 text-sm">Status: {wallet?.status}</p>
          </div>

          {/* P2P Section */}
          <div className={`bg-white rounded-xl p-6 shadow-sm border border-gray-100 ${!user?.nin_verified ? 'opacity-50 pointer-events-none grayscale' : ''}`}>
            <h3 className="text-lg font-bold mb-4 flex items-center gap-2">
              <Send size={18} className="text-blue-600" /> P2P Transfer
            </h3>
            
            {!recipientInfo ? (
              <div className="space-y-3">
                <input 
                  placeholder="Recipient Email Address" 
                  type="email"
                  className="w-full p-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 outline-none"
                  value={p2pData.recipientEmail}
                  onChange={e => {
                    setP2pData({...p2pData, recipientEmail: e.target.value});
                    setRecipientInfo(null);
                    setP2pCommandKey('');
                  }}
                />
                <input 
                  type="number" 
                  placeholder="Amount (Min ₦100)" 
                  className="w-full p-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 outline-none"
                  value={p2pData.amount}
                  onChange={e => {
                    setP2pData({...p2pData, amount: e.target.value});
                    setRecipientInfo(null);
                    setP2pCommandKey('');
                  }}
                />
                <button 
                  className="w-full bg-blue-600 text-white py-2.5 rounded-lg font-medium hover:bg-blue-700 transition disabled:opacity-70"
                  onClick={handleVerifyP2P}
                  disabled={lookupMutation.isPending}
                >
                  {lookupMutation.isPending ? 'Verifying...' : 'Verify Recipient'}
                </button>
              </div>
            ) : (
              <div className="space-y-4">
                <div className="bg-gray-50 border border-gray-200 rounded-lg p-4 space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-500">Recipient Name:</span>
                    <span className="font-bold flex items-center gap-1">
                      {recipientInfo.name} 
                      {recipientInfo.nin_verified ? (
                        <ShieldAlert size={14} className="text-green-600" aria-label="Verified User" />
                      ) : null}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-500">Amount:</span>
                    <span className="font-bold text-lg">{formatNgnMinor(parseNgnMinor(p2pData.amount))}</span>
                  </div>
                </div>
                
                <div className="flex gap-3">
                  <button 
                    className="flex-1 bg-gray-200 text-gray-800 py-2.5 rounded-lg font-medium hover:bg-gray-300 transition"
                    onClick={() => setRecipientInfo(null)}
                    disabled={p2pMutation.isPending}
                  >
                    Cancel
                  </button>
                  <button 
                    className="flex-1 bg-blue-600 text-white py-2.5 rounded-lg font-medium hover:bg-blue-700 transition disabled:opacity-70"
                    onClick={() => p2pMutation.mutate(p2pData)}
                    disabled={p2pMutation.isPending}
                  >
                    {p2pMutation.isPending ? 'Processing...' : 'Confirm Transfer'}
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Withdrawal Section */}
          <div className={`bg-white rounded-xl p-6 shadow-sm border border-gray-100 ${!user?.nin_verified ? 'opacity-50 pointer-events-none grayscale' : ''}`}>
            <h3 className="text-lg font-bold mb-4 flex items-center gap-2">
              <ArrowDownCircle size={18} className="text-orange-600" /> Withdraw to Bank
            </h3>
            {!preview ? (
              <div className="space-y-3">
                <input 
                  placeholder="Account Number" 
                  className="w-full p-2 border rounded"
                  value={withdrawData.accountNumber}
                  onChange={e => setWithdrawData({...withdrawData, accountNumber: e.target.value})}
                />
                <select 
                  className="w-full p-2 border rounded"
                  value={withdrawData.bankCode}
                  onChange={e => setWithdrawData({...withdrawData, bankCode: e.target.value})}
                >
                  <option value="044">Access Bank</option>
                  <option value="011">First Bank</option>
                  <option value="058">GTBank</option>
                  <option value="033">UBA</option>
                </select>
                <input 
                  type="number" 
                  placeholder="Amount (min ₦1,000)" 
                  className="w-full p-2 border rounded"
                  value={withdrawData.amount}
                  onChange={e => setWithdrawData({...withdrawData, amount: e.target.value})}
                />
                <button 
                  className="w-full bg-orange-600 text-white py-2 rounded font-medium"
                  onClick={() => {
                    try {
                      const amountMinor = parseNgnMinor(withdrawData.amount);
                      if (amountMinor < 100000) return toast.error('Minimum withdrawal amount is ₦1,000');
                      previewMutation.mutate({
                        accountNumber: withdrawData.accountNumber,
                        bankCode: withdrawData.bankCode,
                        amountMinor,
                        currency: 'NGN',
                        idempotencyKey: crypto.randomUUID(),
                      });
                    } catch (error: any) {
                      toast.error(error.message);
                    }
                  }}
                  disabled={previewMutation.isPending}
                >
                  {previewMutation.isPending ? 'Checking...' : 'Preview Withdrawal'}
                </button>
              </div>
            ) : (
              <div className="space-y-4 bg-orange-50 p-4 rounded-lg border border-orange-100">
                <div>
                  <p className="text-xs text-gray-500 uppercase">Beneficiary</p>
                  <p className="font-bold text-gray-800">{preview.accountName}</p>
                </div>
                <div>
                  <p className="text-xs text-gray-500 uppercase">Transfer Fee</p>
                  <p className="font-bold text-gray-800">{formatNgnMinor(preview.feeMinor)}</p>
                </div>
                <div className="flex gap-2">
                  <button 
                    className="flex-1 bg-gray-200 text-gray-800 py-2 rounded"
                    onClick={() => setPreview(null)}
                  >
                    Cancel
                  </button>
                  <button 
                    className="flex-1 bg-orange-600 text-white py-2 rounded font-medium"
                    onClick={() => confirmMutation.mutate({ previewToken: preview.previewToken })}
                    disabled={confirmMutation.isPending}
                  >
                    Confirm
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Main Content: History */}
        <div className="md:col-span-2">
          <section className="mb-6 rounded-2xl border border-gray-100 bg-white p-6 shadow-sm" aria-labelledby="wallet-statement-heading">
            <div className="flex flex-col justify-between gap-4 md:flex-row md:items-end">
              <div>
                <h3 id="wallet-statement-heading" className="text-xl font-bold">Journal statement</h3>
                <p className="mt-1 text-sm text-gray-500">Reproducible from posted journals at the displayed cutoff time.</p>
              </div>
              <form
                className="flex flex-wrap items-end gap-3"
                onSubmit={(event) => {
                  event.preventDefault();
                  setStatementRequest({ ...statementDates, cutoff: new Date().toISOString() });
                }}
              >
                <label className="text-sm font-medium text-gray-700">
                  From
                  <input aria-label="Statement from" type="date" value={statementDates.from} max={statementDates.to}
                    onChange={event => setStatementDates({ ...statementDates, from: event.target.value })}
                    className="mt-1 block rounded-lg border-gray-300" />
                </label>
                <label className="text-sm font-medium text-gray-700">
                  To
                  <input aria-label="Statement to" type="date" value={statementDates.to} min={statementDates.from} max={today}
                    onChange={event => setStatementDates({ ...statementDates, to: event.target.value })}
                    className="mt-1 block rounded-lg border-gray-300" />
                </label>
                <button className="rounded-lg bg-gray-900 px-4 py-2 text-sm font-bold text-white">Apply</button>
              </form>
            </div>
            {statementLoading ? <p role="status" className="mt-6 text-gray-500">Loading statement…</p>
              : statementError ? <p role="alert" className="mt-6 text-red-700">The journal statement could not be loaded.</p>
              : statement ? (
                <>
                  <div className="mt-5 grid grid-cols-1 gap-3 text-sm sm:grid-cols-3">
                    <p className="rounded-lg bg-gray-50 p-3">Opening <strong className="block text-lg">{formatNgnMinor(statement.openingBalanceMinor)}</strong></p>
                    <p className="rounded-lg bg-gray-50 p-3">Closing <strong className="block text-lg">{formatNgnMinor(statement.closingBalanceMinor)}</strong></p>
                    <p className="rounded-lg bg-gray-50 p-3">Cutoff <strong className="block text-xs">{new Date(statement.period.cutoff).toLocaleString()}</strong></p>
                  </div>
                  <div className="mt-4 overflow-x-auto">
                    <table className="w-full text-left text-sm">
                      <thead><tr className="border-b text-gray-500"><th className="py-2">Date</th><th>Description</th><th className="text-right">Movement</th><th className="text-right">Balance</th></tr></thead>
                      <tbody>
                        {statement.entries.map((entry: any) => (
                          <tr key={entry.id} className="border-b border-gray-50">
                            <td className="py-3">{entry.effectiveDate}</td>
                            <td>{entry.description}</td>
                            <td className="text-right">{formatNgnMinor(entry.movementMinor)}</td>
                            <td className="text-right font-medium">{formatNgnMinor(entry.balanceMinor)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {!statement.entries.length && <p className="py-6 text-center text-gray-400">No posted movements in this period.</p>}
                  </div>
                </>
              ) : null}
          </section>
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="p-6 border-b border-gray-50 flex justify-between items-center">
              <h3 className="text-xl font-bold">Transaction History</h3>
              <button 
                className="p-2 hover:bg-gray-100 rounded-full"
                onClick={() => queryClient.invalidateQueries({ queryKey: ['wallet'] })}
              >
                <RefreshCw size={18} className="text-gray-400" />
              </button>
            </div>
            <div className="divide-y divide-gray-50">
              {transactions.length === 0 ? (
                <div className="p-12 text-center text-gray-400">No transactions yet</div>
              ) : transactions.map((tx: any) => (
                <div key={tx.id} className="p-6 flex justify-between items-center hover:bg-gray-50 transition">
                  <div className="flex items-center gap-4">
                    <div className={`p-3 rounded-full ${
                      tx.direction === 'CREDIT' ? 'bg-green-100 text-green-600' : 'bg-red-100 text-red-600'
                    }`}>
                      {tx.direction === 'CREDIT' ? <ArrowDownCircle size={20} /> : <Send size={20} />}
                    </div>
                    <div>
                      <p className="font-bold text-gray-800">{tx.type.replace('_', ' ')}</p>
                      <p className="text-xs text-gray-400 flex items-center gap-1">
                        <Clock size={12} /> {new Date(tx.created_at).toLocaleString()}
                      </p>
                      {tx.type === 'WITHDRAWAL' && tx.status === 'PENDING' && (
                        <button 
                          className="mt-2 text-xs bg-blue-50 text-blue-600 px-2 py-1 rounded flex items-center gap-1 hover:bg-blue-100"
                          onClick={() => syncMutation.mutate(tx.id)}
                        >
                          <RefreshCw size={10} /> Sync Status (Sandbox)
                        </button>
                      )}
                    </div>
                  </div>
                  <div className="text-right">
                    <p className={`text-lg font-bold ${
                      tx.direction === 'CREDIT' ? 'text-green-600' : 'text-red-600'
                    }`}>
                      {tx.direction === 'CREDIT' ? '+' : '-'}{formatNgnMinor(tx.amountMinor)}
                    </p>
                    <p className={`text-xs px-2 py-0.5 rounded-full inline-block ${
                      tx.status === 'SUCCESS' ? 'bg-green-100 text-green-700' : 
                      tx.status === 'PENDING' ? 'bg-yellow-100 text-yellow-700' : 'bg-red-100 text-red-700'
                    }`}>
                      {tx.status}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
