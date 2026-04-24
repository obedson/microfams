import React from 'react';
import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import ProtectedRoute from './components/ProtectedRoute';
import Home from './pages/Home';
import Login from './pages/Login';
import Register from './pages/Register';
import ForgotPassword from './pages/ForgotPassword';
import ResetPassword from './pages/ResetPassword';
import Properties from './pages/Properties';
import PropertyDetails from './pages/PropertyDetails';
import Dashboard from './pages/Dashboard';
import CreateProperty from './pages/CreateProperty';
import EditProperty from './pages/EditProperty';
import MyBookings from './pages/MyBookings';
import MyProperties from './pages/MyProperties';
import MyOrders from './pages/MyOrders';
import MySales from './pages/MySales';
import MyMarketplaceProducts from './pages/MyMarketplaceProducts';
import OwnerBookings from './pages/OwnerBookings';
import FarmRecords from './pages/FarmRecords';
import Courses from './pages/Courses';
import CourseDetail from './pages/CourseDetail';
import AddCourse from './pages/AddCourse';
import EditCourse from './pages/EditCourse';
import Marketplace from './pages/Marketplace';
import AddProduct from './pages/AddProduct';
import EditProduct from './pages/EditProduct';
import ProductDetail from './pages/ProductDetail';
import PaymentCallback from './pages/PaymentCallback';
import Groups from './pages/Groups';
import CreateGroup from './pages/CreateGroup';
import GroupDetail from './pages/GroupDetail';
import Wallet from './pages/Wallet';
import Profile from './pages/Profile';
import VerifyNIN from './pages/VerifyNIN';
import BecomeAMember from './pages/BecomeAMember';
import GroupAdminDashboard from './pages/GroupAdminDashboard';
import GroupMemberDashboard from './pages/GroupMemberDashboard';
import ReferralDashboard from './pages/ReferralDashboard';
import ContributionSettings from './pages/ContributionSettings';
import ContributionDashboard from './pages/ContributionDashboard';
import MakeContribution from './pages/MakeContribution';
import ContributionHistory from './pages/ContributionHistory';
import Payment from './pages/Payment';
import MessagesPage from './pages/MessagesPage';
import AdminLogin from './pages/AdminLogin';
import AdminDashboard from './pages/AdminDashboard';
import AuditLogs from './pages/AuditLogs';

function App() {
  return (
    <Layout>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/properties" element={<Properties />} />
        <Route path="/properties/:id" element={<PropertyDetails />} />
        <Route path="/courses" element={<Courses />} />
        <Route path="/courses/:id" element={<CourseDetail />} />
        <Route path="/marketplace" element={<Marketplace />} />
        <Route path="/marketplace/products/:id" element={<ProductDetail />} />
        <Route path="/groups" element={<Groups />} />
        <Route path="/groups/:id" element={<GroupDetail />} />
        <Route path="/groups/:id/contributions" element={<ContributionDashboard />} />
        <Route path="/groups/:id/contributions/settings" element={<ContributionSettings />} />
        <Route path="/contributions/:contributionId/pay" element={<MakeContribution />} />
        <Route path="/contributions/history" element={<ContributionHistory />} />
        <Route path="/create-group" element={<CreateGroup />} />
        <Route path="/add-course" element={<AddCourse />} />
        <Route path="/login" element={<Login />} />
        <Route path="/register" element={<Register />} />
        <Route path="/forgot-password" element={<ForgotPassword />} />
        <Route path="/reset-password" element={<ResetPassword />} />
        <Route path="/payment/callback" element={<PaymentCallback />} />
        <Route path="/payment/:bookingId" element={<ProtectedRoute><Payment /></ProtectedRoute>} />
        <Route path="/payment" element={<Payment />} />
        <Route path="/dashboard" element={<ProtectedRoute><Dashboard /></ProtectedRoute>} />
        <Route path="/create-property" element={<ProtectedRoute><CreateProperty /></ProtectedRoute>} />
        <Route path="/properties/:id/edit" element={<ProtectedRoute><EditProperty /></ProtectedRoute>} />
        <Route path="/courses/:id/edit" element={<ProtectedRoute><EditCourse /></ProtectedRoute>} />
        <Route path="/marketplace/add-product" element={<ProtectedRoute><AddProduct /></ProtectedRoute>} />
        <Route path="/marketplace/products/:id/edit" element={<ProtectedRoute><EditProduct /></ProtectedRoute>} />
        <Route path="/my-bookings" element={<ProtectedRoute><MyBookings /></ProtectedRoute>} />
        <Route path="/messages" element={<ProtectedRoute><MessagesPage /></ProtectedRoute>} />
        <Route path="/my-properties" element={<ProtectedRoute><MyProperties /></ProtectedRoute>} />
        <Route path="/my-orders" element={<ProtectedRoute><MyOrders /></ProtectedRoute>} />
        <Route path="/my-sales" element={<ProtectedRoute><MySales /></ProtectedRoute>} />
        <Route path="/my-marketplace-products" element={<ProtectedRoute><MyMarketplaceProducts /></ProtectedRoute>} />
        <Route path="/owner/bookings" element={<ProtectedRoute><OwnerBookings /></ProtectedRoute>} />
        <Route path="/farm-records" element={<ProtectedRoute><FarmRecords /></ProtectedRoute>} />
        <Route path="/referrals" element={<ProtectedRoute><ReferralDashboard /></ProtectedRoute>} />
        <Route path="/wallet" element={<ProtectedRoute><Wallet /></ProtectedRoute>} />
        <Route path="/profile" element={<ProtectedRoute><Profile /></ProtectedRoute>} />
        <Route path="/verify-nin" element={<ProtectedRoute><VerifyNIN /></ProtectedRoute>} />
        <Route path="/become-a-member" element={<ProtectedRoute><BecomeAMember /></ProtectedRoute>} />
        <Route path="/groups/:id/admin" element={<ProtectedRoute><GroupAdminDashboard /></ProtectedRoute>} />
        <Route path="/groups/:id/member" element={<ProtectedRoute><GroupMemberDashboard /></ProtectedRoute>} />
      </Routes>
    </Layout>
  );
}

export default App;
