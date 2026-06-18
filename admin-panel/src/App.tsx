import React, { useEffect } from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { useDispatch, useSelector } from 'react-redux';
import { AppDispatch, RootState } from './store';
import { getCurrentUser } from './store/slices/authSlice';

// Components
import ProtectedRoute from './components/ProtectedRoute';
import Layout from './components/Layout/Layout';

// Pages
import LoginPage from './pages/LoginPage';
import DashboardPage from './pages/DashboardPage';
import UsersPage from './pages/UsersPage';
import UserDetailPage from './pages/UserDetailPage';
import ServersPage from './pages/ServersPage';
import PaymentsPage from './pages/PaymentsPage';
import AuthCodesPage from './pages/AuthCodesPage';
import SubscriptionsPage from './pages/SubscriptionsPage';
import ProtocolsPage from './pages/ProtocolsPage';
import IncidentsPage from './pages/IncidentsPage';
import AuditLogPage from './pages/AuditLogPage';
import SettingsPage from './pages/SettingsPage';
import ClientLogsPage from './pages/ClientLogsPage';
import ConnectionLogsPage from './pages/ConnectionLogsPage';
import UserLogsPage from './pages/UserLogsPage';
import SupportDiagnosticsPage from './pages/SupportDiagnosticsPage';
import DevicesPage from './pages/DevicesPage';
import TrialsPage from './pages/TrialsPage';
import ObservabilityPage from './pages/ObservabilityPage';
import ProductTimelinePage from './pages/ProductTimelinePage';
import ApiTester from './components/ApiTester';

function App() {
  const dispatch = useDispatch<AppDispatch>();
  const { isAuthenticated, isLoading } = useSelector((state: RootState) => state.auth);

  useEffect(() => {
    // Проверяем токен при загрузке приложения
    if (localStorage.getItem('token')) {
      dispatch(getCurrentUser());
    }
  }, [dispatch]);

  if (isLoading) {
    return <div>Loading...</div>;
  }

  return (
        <Routes>
          <Route path="/login" element={
            isAuthenticated ? <Navigate to="/dashboard" replace /> : <LoginPage />
          } />
          
          <Route path="/" element={<Navigate to="/dashboard" replace />} />
          
          <Route path="/dashboard" element={
            <ProtectedRoute>
              <Layout>
                <DashboardPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/users" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <UsersPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/users/:id" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <UserDetailPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/protocols" element={
            <ProtectedRoute roles={['admin', 'owner']}>
              <Layout>
                <ProtocolsPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/incidents" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <IncidentsPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/audit-log" element={
            <ProtectedRoute roles={['owner']}>
              <Layout>
                <AuditLogPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/settings" element={
            <ProtectedRoute roles={['owner']}>
              <Layout>
                <SettingsPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/servers" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <ServersPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/payments" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <PaymentsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/subscriptions" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <SubscriptionsPage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/auth-codes" element={
            <ProtectedRoute roles={['admin', 'owner']}>
              <Layout>
                <AuthCodesPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/client-logs" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <ClientLogsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/connection-logs" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <ConnectionLogsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/user-logs" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <UserLogsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/support-diagnostics" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <SupportDiagnosticsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/devices" element={
            <ProtectedRoute roles={['read_only', 'support', 'admin', 'owner']}>
              <Layout>
                <DevicesPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/trials" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <TrialsPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/observability" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <ObservabilityPage />
              </Layout>
            </ProtectedRoute>
          } />

          <Route path="/product-timeline" element={
            <ProtectedRoute roles={['support', 'admin', 'owner']}>
              <Layout>
                <ProductTimelinePage />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="/api-test" element={
            <ProtectedRoute>
              <Layout>
                <ApiTester />
              </Layout>
            </ProtectedRoute>
          } />
          
          <Route path="*" element={<Navigate to="/dashboard" replace />} />
        </Routes>
  );
}

export default App;
