import { api } from './api';

export interface ServerLogsResponse {
  server_id: number;
  server_name: string;
  protocol: string;
  log_type?: string;
  lines_count: number;
  logs: string[];
}

class ServerLogsService {
  async getServerLogs(
    serverId: number,
    params: { protocol?: 'xray' | 'wireguard'; log_type?: string; lines?: number }
  ): Promise<ServerLogsResponse> {
    const { protocol = 'xray', log_type = 'access', lines = 100 } = params;
    const response = await api.get<ServerLogsResponse>(`/api/vpn/server/${serverId}/logs`, {
      params: { protocol, log_type, lines },
      timeout: 60000,
    });
    return response.data;
  }
}

export const serverLogsService = new ServerLogsService();
