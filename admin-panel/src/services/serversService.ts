import { api } from './api';

export interface Server {
  id: number;
  name: string;
  country: string;
  city: string | null;
  ip_address: string;
  port: number;
  current_users: number;
  max_users: number;
  is_active: boolean;
  health_status: string;
  status?: string;
  created_at: string;
  // Дополнительные поля для мониторинга
  load_percentage?: number;
  bandwidth_used_mbps?: number;
  bandwidth_limit_mbps?: number;
  ping_ms?: number;
  supported_protocols?: string[];
  provider?: string;
  provider_region?: string;
  uptime_percentage?: number;
  last_health_check?: string;
  wireguard_port?: number;
  xray_port?: number;
  openvpn_port?: number;
  ssh_host?: string | null;
  ssh_port?: number | null;
  ssh_user?: string | null;
  has_ssh_key?: boolean;
}

export interface CreateServerData {
  name: string;
  country: string;
  city?: string;
  ip_address: string;
  port?: number;
  wireguard_port?: number;
  max_users: number;
  ssh_host?: string;
  ssh_port?: number;
  ssh_user?: string;
  ssh_key_path?: string;
  ssh_key_content?: string;
}

export interface ServersListResponse {
  servers: Server[];
  total: number;
  page: number;
  limit: number;
}

class ServersService {
  async getServers(params?: { page?: number; limit?: number }): Promise<Server[]> {
    const response = await api.get<ServersListResponse>('/api/admin/servers', { params });
    return response.data.servers;
  }

  async getServer(serverId: number): Promise<Server> {
    const response = await api.get<Server>(`/api/admin/servers/${serverId}`);
    return response.data;
  }

  async createServer(data: CreateServerData): Promise<Server> {
    const response = await api.post<Server>('/api/admin/servers', data);
    return response.data;
  }

  async updateServer(serverId: number, data: Partial<Server>): Promise<Server> {
    const response = await api.put<Server>(`/api/admin/servers/${serverId}`, data);
    return response.data;
  }

  async deleteServer(serverId: number): Promise<void> {
    await api.delete(`/api/admin/servers/${serverId}`);
  }

  async toggleServerStatus(serverId: number): Promise<Server> {
    const response = await api.post<Server>(`/api/admin/servers/${serverId}/toggle`);
    return response.data;
  }

  async getServerStats(serverId: number): Promise<any> {
    const response = await api.get(`/api/admin/servers/${serverId}/stats`);
    return response.data;
  }

  async changeServerStatus(serverId: number, status: string): Promise<any> {
    const response = await api.post(`/api/admin/servers/${serverId}/status`, { status });
    return response.data;
  }

  async getServerActiveSessions(serverId: number): Promise<any[]> {
    const response = await api.get(`/api/admin/servers/${serverId}/active-sessions`);
    return response.data;
  }

  async getServerLoad(serverId: number): Promise<any> {
    const response = await api.get(`/api/admin/servers/${serverId}/load`);
    return response.data;
  }

  async getServerProtocols(serverId: number): Promise<any> {
    const response = await api.get(`/api/admin/servers/${serverId}/protocols`);
    return response.data;
  }

  async getServerUsers(serverId: number): Promise<any[]> {
    const response = await api.get(`/api/admin/servers/${serverId}/users`);
    return response.data;
  }

  /** Логи сервера (XRay или WireGuard) — только для админов */
  async getServerLogs(
    serverId: number,
    params: { protocol?: 'xray' | 'wireguard'; log_type?: string; lines?: number } = {}
  ): Promise<{ server_id: number; server_name: string; protocol: string; log_type?: string; lines_count: number; logs: string[] }> {
    const { protocol = 'xray', log_type = 'access', lines = 200 } = params;
    const response = await api.get(`/api/vpn/server/${serverId}/logs`, {
      params: { protocol, log_type, lines },
      timeout: 60000,
    });
    return response.data;
  }
}

export const serversService = new ServersService();


