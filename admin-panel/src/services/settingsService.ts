import { api } from './api';

export interface SystemSettings {
  feature_flags: Record<string, boolean>;
  min_versions: Record<string, string>;
  feature_flags_override?: Record<string, boolean>;
  min_versions_override?: Record<string, string>;
  updated_at?: string;
}

export interface AdminUser {
  id: number;
  email: string;
  role: string;
  is_active: boolean;
  last_login_at?: string | null;
  created_at?: string | null;
}

class SettingsService {
  async getSettings(): Promise<SystemSettings> {
    const response = await api.get('/api/admin/settings');
    return response.data;
  }

  async updateSettings(payload: {
    feature_flags?: Record<string, boolean>;
    min_versions?: Record<string, string>;
  }): Promise<void> {
    await api.put('/api/admin/settings', payload);
  }

  async getAdmins(): Promise<AdminUser[]> {
    const response = await api.get('/api/admin/settings/admins');
    return response.data;
  }

  async createAdmin(payload: { email: string; password: string; role: string }): Promise<AdminUser> {
    const response = await api.post('/api/admin/settings/admins', payload);
    return response.data;
  }

  async updateAdmin(adminId: number, payload: { role?: string; is_active?: boolean }): Promise<AdminUser> {
    const response = await api.patch(`/api/admin/settings/admins/${adminId}`, payload);
    return response.data;
  }

  async changePassword(current_password: string, new_password: string): Promise<void> {
    await api.post('/api/admin/auth/change-password', {
      current_password,
      new_password,
    });
  }
}

export const settingsService = new SettingsService();
