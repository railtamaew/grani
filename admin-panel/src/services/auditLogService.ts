import { api } from './api';

export interface AuditLogEntry {
  id: number;
  admin_user_id: number;
  admin_email?: string | null;
  action: string;
  entity_type: string;
  entity_id?: number | null;
  old_value?: any;
  new_value?: any;
  ip_address?: string | null;
  user_agent?: string | null;
  created_at: string;
}

class AuditLogService {
  async getAuditLogs(params: {
    admin_user_id?: number;
    entity_type?: string;
    entity_id?: number;
    start_date?: string;
    end_date?: string;
    skip?: number;
    limit?: number;
  }): Promise<AuditLogEntry[]> {
    const response = await api.get('/api/admin/audit-log', { params });
    return response.data;
  }
}

export const auditLogService = new AuditLogService();
