import { api } from './api';

export interface AuthCode {
  id: number;
  email: string;
  code_hash: string;
  expires_at: string;
  is_expired: boolean;
  attempts_count: number;
  created_at: string;
  ip_address: string | null;
  time_left_seconds: number;
}

export interface AuthCodesResponse {
  codes: AuthCode[];
  total: number;
  email_filter: string | null;
}

export const authCodesService = {
  getAuthCodes: async (email?: string, skip: number = 0, limit: number = 100): Promise<AuthCodesResponse> => {
    const params = new URLSearchParams();
    if (email) params.append('email', email);
    params.append('skip', skip.toString());
    params.append('limit', limit.toString());
    
    const response = await api.get(`/api/admin/auth-codes?${params.toString()}`);
    return response.data;
  },

  getAuthCodeDetail: async (codeId: number) => {
    const response = await api.get(`/api/admin/auth-codes/${codeId}`);
    return response.data;
  },
};





