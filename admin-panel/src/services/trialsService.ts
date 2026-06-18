import { api } from './api';

export interface TrialInfo {
  user_id: number;
  email: string;
  status: 'active' | 'expired' | 'not_started';
  trial_active: boolean;
  trial_started_at?: string | null;
  trial_seconds_left: number;
  trial_ends_at?: string | null;
}

export interface TrialsResponse {
  trials: TrialInfo[];
  total: number;
  page: number;
  limit: number;
}

export const trialsService = {
  async getTrials(params: {
    page?: number;
    limit?: number;
    status?: 'active' | 'expired' | 'not_started';
    user_id?: number;
    search?: string;
  }): Promise<TrialsResponse> {
    const response = await api.get('/api/admin/trials', { params });
    return response.data;
  },
  async setTrial(userId: number, durationMinutes: number): Promise<void> {
    await api.post(`/api/admin/users/${userId}/trial`, { duration_minutes: durationMinutes });
  },
};
