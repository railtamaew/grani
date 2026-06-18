import { api } from './api';

export interface Incident {
  id: number;
  timestamp: string | null;
  user_id: number | null;
  user_email?: string | null;
  device_id?: string | null;
  protocol_code?: string | null;
  server_id?: number | null;
  event_type?: string | null;
  error_code?: string | null;
  error_message?: string | null;
  country?: string | null;
  network_type?: string | null;
  status?: string | null;
  app_version?: string | null;
}

export interface IncidentDetail extends Incident {
  os_version?: string | null;
  platform?: string | null;
  timeline?: Array<{
    id: number;
    event_type: string;
    timestamp: string | null;
    error_code?: string | null;
    error_message?: string | null;
    duration_ms?: number | null;
  }>;
  recommended_action?: string | null;
}

class IncidentsService {
  async getIncidents(params: {
    user_id?: number;
    server_id?: number;
    protocol_code?: string;
    error_code?: string;
    app_version?: string;
    status?: string;
    skip?: number;
    limit?: number;
  }): Promise<Incident[]> {
    const response = await api.get('/api/admin/incidents', { params });
    return response.data;
  }

  async getIncidentDetail(incidentId: number): Promise<IncidentDetail> {
    const response = await api.get(`/api/admin/incidents/${incidentId}`);
    return response.data;
  }

  async updateIncident(incidentId: number, payload: { status?: string; comment?: string }): Promise<void> {
    await api.patch(`/api/admin/incidents/${incidentId}`, payload);
  }
}

export const incidentsService = new IncidentsService();
