import React from 'react';
import { useSelector } from 'react-redux';
import { RootState } from '../store';

export type Role = 'owner' | 'admin' | 'support' | 'read_only';

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

interface RoleGuardProps {
  roles: Role[];
  children: React.ReactNode;
  fallback?: React.ReactNode;
}

const RoleGuard: React.FC<RoleGuardProps> = ({ roles, children, fallback = null }) => {
  const { user } = useSelector((state: RootState) => state.auth);
  if (!canAccess(user?.role, roles)) {
    return <>{fallback}</>;
  }
  return <>{children}</>;
};

export default RoleGuard;
