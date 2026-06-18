import { api } from './api';

export interface User {
  id: number;
  email: string;
  username?: string;
  is_active: boolean;
  is_verified: boolean;
  created_at: string;
  last_login?: string | null;
  subscription?: {
    id: number;
    plan_name: string;
    is_active: boolean;
    expires_at: string;
  };
  devices_count?: number;
  notes?: string;
  country?: string;
  auth_provider?: string;
  last_seen_at?: string;
  current_subscription?: any;
  subscriptions?: any[];
  devices?: any[];
}

export interface UserDevice {
  id: number;
  name: string;
  platform: string;
  device_id: string;
  is_active: boolean;
  last_connected: string | null;
  ip_address: string | null;
}

class UsersService {
  async getUsers(params: {
    page?: number;
    limit?: number;
    search?: string;
    country?: string;
    auth_provider?: string;
    has_subscription?: boolean;
    has_errors?: boolean;
  }): Promise<{
    users: User[];
    total: number;
    page: number;
    limit: number;
  }> {
    const response = await api.get('/api/admin/users', { params });
    return response.data;
  }

  async getUser(userId: number): Promise<User> {
    const response = await api.get(`/api/admin/users/${userId}`);
    return response.data;
  }

  async getUserDevices(userId: number): Promise<UserDevice[]> {
    const response = await api.get(`/api/admin/users/${userId}/devices`);
    return response.data;
  }

  async blockUser(userId: number): Promise<void> {
    await api.post(`/api/admin/users/${userId}/block`);
  }

  async unblockUser(userId: number): Promise<void> {
    await api.post(`/api/admin/users/${userId}/unblock`);
  }

  async deleteUser(userId: number, reason: string = 'Admin request'): Promise<void> {
    await api.delete(`/api/admin/users/${userId}`, { params: { reason } });
  }

  async updateUser(userId: number, data: Partial<User>): Promise<User> {
    const response = await api.patch(`/api/admin/users/${userId}`, data);
    return response.data;
  }

  async getUserEvents(userId: number): Promise<any> {
    const response = await api.get(`/api/admin/users/${userId}/events`);
    return response.data;
  }

  async getUserDiagnostics(
    userId: number,
    params: { from_time?: string; to_time?: string; server_id?: number; limit?: number; include_server_logs?: boolean } = {}
  ): Promise<{ user_id: number; events: any[]; count: number }> {
    const response = await api.get(`/api/admin/users/${userId}/diagnostics`, {
      params: { ...params, limit: params.limit ?? 200 },
      timeout: 60000,
    });
    return response.data;
  }
}

export const usersService = new UsersService();


