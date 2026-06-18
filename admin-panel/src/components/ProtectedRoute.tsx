import React, { useEffect } from 'react';
import { Navigate } from 'react-router-dom';
import { useSelector } from 'react-redux';
import { RootState } from '../store';
import { Role } from './RoleGuard';

interface ProtectedRouteProps {
  children: React.ReactNode;
  roles?: Role[];
}

const roleOrder: Record<Role, number> = {
  owner: 4,
  admin: 3,
  support: 2,
  read_only: 1,
};

const canAccess = (userRole: Role | undefined, requiredRoles: Role[]): boolean => {
  if (!userRole) return false;
  return requiredRoles.some((role) => roleOrder[userRole] >= roleOrder[role]);
};

const ProtectedRoute: React.FC<ProtectedRouteProps> = ({ children, roles }) => {
  const { isAuthenticated, user } = useSelector((state: RootState) => state.auth);

  useEffect(() => {
    const onUnauthorized = () => {
      // здесь можно диспатчить logout или показывать уведомление
    };
    const onForbidden = () => {
      // централизованная точка для UX при 403
    };
    window.addEventListener('auth:unauthorized', onUnauthorized);
    window.addEventListener('auth:forbidden', onForbidden);
    return () => {
      window.removeEventListener('auth:unauthorized', onUnauthorized);
      window.removeEventListener('auth:forbidden', onForbidden);
    };
  }, []);

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }

  if (roles && roles.length > 0 && !canAccess(user?.role, roles)) {
    window.dispatchEvent(new Event('auth:forbidden'));
    return <Navigate to="/dashboard" replace />;
  }

  return <>{children}</>;
};

export default ProtectedRoute;









