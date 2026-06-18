import { api } from './api';

export interface DashboardStats {
  total_users: number;
  active_subscriptions: number;
  total_revenue: number;
  active_connections: number;
  server_count: number;
}

export interface ConnectionLog {
  id: number;
  user_id: number;
  device_id: number;
  server_id: number;
  connection_type: string;
  ip_address: string;
  connected_at: string;
  disconnected_at: string | null;
  duration_seconds: number | null;
}

class DashboardService {
  async getStats(): Promise<DashboardStats> {
    const response = await api.get<DashboardStats>('/api/admin/dashboard');
    return response.data;
  }

  async getAuthProviderStats(): Promise<{ providers: Record<string, number>; total_users: number }> {
    const response = await api.get('/api/admin/stats/auth-providers');
    return response.data;
  }

  async getConnectionLogs(params: {
    page?: number;
    limit?: number;
    user_id?: number;
    server_id?: number;
    connection_type?: string;
  }): Promise<{
    logs: ConnectionLog[];
    total: number;
  }> {
    const response = await api.get('/api/admin/logs/connections', { params });
    return response.data;
  }

  async getSystemStats(): Promise<any> {
    const response = await api.get('/api/vpn/system/stats');
    return response.data;
  }

  async getLoadAlerts(threshold: number = 80): Promise<{ alerts: any[]; count: number }> {
    const response = await api.get('/api/admin/load/alerts', { params: { threshold } });
    return response.data;
  }

  async cleanupInactiveConnections(): Promise<{ cleaned_count: number }> {
    const response = await api.post('/api/vpn/system/cleanup');
    return response.data;
  }

  async getMetrics(): Promise<any> {
    const response = await api.get('/api/admin/metrics');
    return response.data;
  }

  async getDiagnosticsPing(): Promise<{
    api: Array<{ url: string; elapsed_ms: number; ok: boolean; status_code?: number; error?: string }>;
    xray_servers: Array<{
      host: string;
      port: number;
      elapsed_ms: number;
      ok: boolean;
      server_id?: number;
      name?: string;
      error?: string;
      protocol?: string;
      transport?: string;
      check?: string;
    }>;
  }> {
    const response = await api.get('/api/admin/diagnostics/ping-upstreams');
    return response.data;
  }
}

export const dashboardService = new DashboardService();

