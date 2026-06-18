import { api } from './api';

export interface Protocol {
  id: number;
  name: string;
  code: string;
  status: string; // enabled, disabled, deprecated, testing
  app_supported?: string[];
  config_schema?: any;
  release_notes?: string;
  active_users_24h?: number;
  created_at?: string;
  updated_at?: string;
}

export interface ProtocolStats {
  protocol_id: number;
  protocol_code: string;
  active_users: {
    '24h': number;
    '7d': number;
    '30d': number;
  };
  errors_count: number;
  period_days: number;
}

export interface ProtocolServer {
  id: number;
  name: string;
  country: string;
  status: string;
  is_active: boolean;
}

export interface ProtocolPerformance {
  protocol: string;
  average_speed_mbps: number;
  average_ping_ms: number;
  success_rate: number;
  total_connections: number;
  total_traffic_gb: number;
  uptime_percentage: number;
}

class ProtocolsService {
  async getProtocols(): Promise<Protocol[]> {
    const response = await api.get<Protocol[]>('/api/admin/protocols');
    return response.data;
  }

  async getProtocol(protocolId: number): Promise<Protocol | null> {
    try {
      const protocols = await this.getProtocols();
      const protocol = protocols.find(p => p.id === protocolId);
      return protocol || null;
    } catch (error) {
      console.error('Ошибка получения протокола:', error);
      return null;
    }
  }

  async getProtocolStats(protocolId: number, days: number = 30): Promise<ProtocolStats> {
    const response = await api.get<ProtocolStats>(`/api/admin/protocols/${protocolId}/stats`, {
      params: { days }
    });
    return response.data;
  }

  async getProtocolServers(protocolId: number): Promise<ProtocolServer[]> {
    const response = await api.get<ProtocolServer[]>(`/api/admin/protocols/${protocolId}/servers`);
    return response.data;
  }

  async getProtocolsStats(days: number = 7): Promise<any> {
    const response = await api.get('/api/admin/protocols/stats', {
      params: { days }
    });
    return response.data;
  }

  async getProtocolPerformance(protocolName: string, days: number = 7): Promise<ProtocolPerformance> {
    const response = await api.get<ProtocolPerformance>(`/api/admin/protocols/${protocolName}/performance`, {
      params: { days }
    });
    return response.data;
  }

  async enableProtocol(protocolId: number): Promise<void> {
    await api.post(`/api/admin/protocols/${protocolId}/enable`);
  }

  async disableProtocol(protocolId: number): Promise<void> {
    await api.post(`/api/admin/protocols/${protocolId}/disable`);
  }

  async updateProtocol(protocolId: number, data: Partial<Protocol>): Promise<void> {
    await api.patch(`/api/admin/protocols/${protocolId}`, data);
  }
}

export const protocolsService = new ProtocolsService();
