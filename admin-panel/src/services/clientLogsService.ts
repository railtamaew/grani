import { api } from './api';

export interface ClientLogEntry {
  id: number;
  user_id: number;
  device_id: number;
  server_id?: number | null;
  event_type: string;
  protocol?: string | null;
  client_id?: string | null;
  message?: string | null;
  error_code?: string | null;
  error_details?: any;
  app_version?: string | null;
  platform?: string | null;
  os_version?: string | null;
  connection_duration_ms?: number | null;
  bytes_sent?: number | null;
  bytes_received?: number | null;
  created_at: string;
}

export interface SupportDiagnosticReport extends ClientLogEntry {
  user_email?: string | null;
  report_id?: string | null;
  build_number?: string | number | null;
  access_status?: string | null;
  vpn_state?: string | null;
  server?: string | null;
  last_error?: string | null;
  context_minutes?: number | null;
  context_events?: ClientLogEntry[];
}

class ClientLogsService {
  async getClientLogs(params: {
    page?: number;
    limit?: number;
    user_id?: number;
    device_id?: number;
    server_id?: number;
    event_type?: string;
    error_code?: string;
    protocol?: string;
    platform?: string;
  }): Promise<{ logs: ClientLogEntry[]; total: number; page: number; limit: number }> {
    const response = await api.get('/api/admin/logs/clients', { params });
    return response.data;
  }

  async getSupportDiagnostics(params: {
    page?: number;
    limit?: number;
    user_id?: number;
    device_id?: number;
    email?: string;
    report_id?: string;
    context_minutes?: number;
    context_limit?: number;
  }): Promise<{ reports: SupportDiagnosticReport[]; total: number; page: number; limit: number }> {
    const response = await api.get('/api/admin/support/diagnostics', { params });
    return response.data;
  }
}

export const clientLogsService = new ClientLogsService();
