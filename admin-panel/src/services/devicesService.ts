import { api } from './api';

export interface DeviceInfo {
  id: number;
  user_id: number;
  user_email?: string | null;
  device_id: string;
  device_name?: string | null;
  platform?: string | null;
  model?: string | null;
  app_version?: string | null;
  is_active: boolean;
  last_connected?: string | null;
  last_ip?: string | null;
  created_at: string;
}

export interface DevicesResponse {
  devices: DeviceInfo[];
  total: number;
  page: number;
  limit: number;
}

export const devicesService = {
  async getDevices(params: {
    page?: number;
    limit?: number;
    user_id?: number;
    platform?: string;
    is_active?: boolean;
    search?: string;
  }): Promise<DevicesResponse> {
    const response = await api.get('/api/admin/devices', { params });
    return response.data;
  },
  async deleteDevice(deviceId: number): Promise<void> {
    await api.delete(`/api/admin/devices/${deviceId}`);
  },
  async bulkDisable(deviceIds: number[]): Promise<{ updated: number }> {
    const response = await api.post('/api/admin/devices/bulk-disable', { device_ids: deviceIds });
    return response.data;
  },
  async bulkDelete(deviceIds: number[]): Promise<{ deleted: number }> {
    const response = await api.post('/api/admin/devices/bulk-delete', { device_ids: deviceIds });
    return response.data;
  },
};
