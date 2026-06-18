import { api } from './api';

export interface ObservabilityEvent {
  id: number;
  event_time: string | null;
  event_name: string;
  severity: string;
  source: string;
  vpn_session_id?: string | null;
  request_id?: string | null;
  user_id?: number | null;
  device_id?: number | null;
  server_id?: number | null;
  protocol?: string | null;
  reason_code?: string | null;
  message?: string | null;
  attrs?: Record<string, unknown>;
  user_context?: {
    id: number;
    email: string;
    role?: string | null;
    is_active: boolean;
    is_verified: boolean;
    country?: string | null;
    last_seen_at?: string | null;
  } | null;
  device_context?: {
    id: number;
    device_id: string;
    platform?: string | null;
    model?: string | null;
    app_version?: string | null;
    last_ip?: string | null;
    last_country?: string | null;
  } | null;
  server_context?: {
    id: number;
    name: string;
    country?: string | null;
    city?: string | null;
    provider?: string | null;
    status?: string | null;
    health_status?: string | null;
  } | null;
  related_logs?: {
    client_log?: {
      id: number;
      created_at?: string | null;
      event_type?: string | null;
      protocol?: string | null;
      error_code?: string | null;
      message?: string | null;
      app_version?: string | null;
      platform?: string | null;
    } | null;
    vpn_server_log?: {
      id: number;
      connected_at?: string | null;
      disconnected_at?: string | null;
      connection_type?: string | null;
      ip_address?: string | null;
      duration_seconds?: number | null;
    } | null;
    telemetry_log?: {
      id: number;
      timestamp?: string | null;
      event_type?: string | null;
      error_code?: string | null;
      error_message?: string | null;
      network_type?: string | null;
      app_version?: string | null;
      platform?: string | null;
    } | null;
  };
}

export interface ObservabilityIncident {
  id: number;
  incident_key: string;
  incident_type: string;
  severity: string;
  status: string;
  title: string;
  summary?: string | null;
  first_seen_at?: string | null;
  last_seen_at?: string | null;
  assignee_user_id?: number | null;
  sla?: {
    age_minutes: number;
    sla_target_minutes: number;
    sla_breached: boolean;
  };
}

export interface ObservabilityIncidentComment {
  id: number;
  incident_id: number;
  author_user_id?: number | null;
  comment: string;
  created_at?: string | null;
}

export interface ProductTimelinePoint {
  bucket: string;
  connection_attempts: number;
  connection_success: number;
  traffic_confirmed: number;
  connection_errors: number;
  verify_warnings: number;
  new_users: number;
  login_seen: number;
  payments_total: number;
  payments_completed: number;
  payments_failed: number;
}

export interface ProductTimelineResponse {
  from_time: string;
  to_time: string;
  grain: 'minute' | 'hour' | 'day';
  items: ProductTimelinePoint[];
  totals: Omit<ProductTimelinePoint, 'bucket'>;
  notes?: Record<string, string>;
}

class ObservabilityService {
  async getProductTimeline(params: {
    from_time?: string;
    to_time?: string;
    grain?: 'minute' | 'hour' | 'day';
  }): Promise<ProductTimelineResponse> {
    const response = await api.get('/api/admin/observability/metrics/product-timeline', {
      params,
    });
    return response.data;
  }

  async getConnectivitySummary(hours = 24): Promise<{
    window_hours: number;
    duration_by_protocol: Record<string, { samples: number; p50_ms: number; p95_ms: number; avg_ms: number }>;
    stage_errors: Record<string, Record<string, number>>;
    degraded_rate: Record<string, { degraded_count: number; starts_count: number; degraded_rate_pct: number }>;
    success_rate: Record<string, { success_count: number; starts_count: number; success_rate_pct: number }>;
    network_split: Record<string, Record<string, { errors: number; starts: number }>>;
    signals: { dataplane_not_ready_after_apply: number };
  }> {
    const response = await api.get('/api/admin/observability/metrics/connectivity-summary', {
      params: { hours },
    });
    return response.data;
  }

  async getEvents(params: {
    from_time?: string;
    to_time?: string;
    user_id?: number;
    server_id?: number;
    vpn_session_id?: string;
    event_name?: string;
    severity?: string;
    detail_level?: 'basic' | 'enriched';
    correlation_window_seconds?: number;
    cursor_direction?: 'next' | 'prev';
    cursor?: string;
    limit?: number;
  }): Promise<{
    items: ObservabilityEvent[];
    next_cursor: string | null;
    prev_cursor: string | null;
    detail_level?: 'basic' | 'enriched';
    analytics_backend?: string;
  }> {
    const response = await api.get('/api/admin/observability/events', { params });
    return response.data;
  }

  async getIncidents(params: {
    status?: string;
    severity?: string;
    incident_type?: string;
    assignee_user_id?: number;
    server_id?: number;
    from_time?: string;
    to_time?: string;
    cursor_direction?: 'next' | 'prev';
    cursor?: string;
    breached_only?: boolean;
    sort_by?: string;
    sort_dir?: 'asc' | 'desc';
    limit?: number;
  }): Promise<{ items: ObservabilityIncident[]; next_cursor: string | null; prev_cursor: string | null }> {
    const response = await api.get('/api/admin/observability/incidents', { params });
    return response.data;
  }

  async getIncident(incidentId: number): Promise<{
    incident: ObservabilityIncident;
    comments: ObservabilityIncidentComment[];
    related_filters?: {
      vpn_session_id?: string | null;
      request_id?: string | null;
      server_id?: number | null;
    };
    related_events?: ObservabilityEvent[];
  }> {
    const response = await api.get(`/api/admin/observability/incidents/${incidentId}`);
    return response.data;
  }

  async updateIncidentStatus(incidentId: number, status: string): Promise<{ ok: boolean }> {
    const response = await api.post(`/api/admin/observability/incidents/${incidentId}/status`, { status });
    return response.data;
  }

  async assignIncident(incidentId: number, assignee_user_id: number | null): Promise<{ ok: boolean }> {
    const response = await api.post(`/api/admin/observability/incidents/${incidentId}/assign`, { assignee_user_id });
    return response.data;
  }

  async addIncidentComment(incidentId: number, comment: string): Promise<{ ok: boolean }> {
    const response = await api.post(`/api/admin/observability/incidents/${incidentId}/comment`, { comment });
    return response.data;
  }

  async getIncidentMetrics(params: { from_time?: string; to_time?: string } = {}): Promise<{
    open_total: number;
    by_severity: Record<string, number>;
    by_status: Record<string, number>;
  }> {
    const response = await api.get('/api/admin/observability/metrics/incidents', { params });
    return response.data;
  }

  async generateTestIncident(payload: {
    incident_type?: string;
    severity?: string;
    user_id?: number;
    server_id?: number;
    vpn_session_id?: string;
    request_id?: string;
    message?: string;
  }): Promise<{ ok: boolean; event_id: number; incident_id: number }> {
    const response = await api.post('/api/admin/observability/testing/generate', payload);
    return response.data;
  }
}

export const observabilityService = new ObservabilityService();
