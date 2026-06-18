import { api } from './api';

export interface SubscriptionInfo {
  id: number;
  user_id: number;
  user_email: string;
  plan_id: number;
  plan_name?: string | null;
  status?: string | null;
  start_date?: string | null;
  end_date?: string | null;
  auto_renew: boolean;
  source?: string | null;
  external_id?: string | null;
}

export interface SubscriptionsResponse {
  subscriptions: SubscriptionInfo[];
  total: number;
  page: number;
  limit: number;
}

class SubscriptionsService {
  async getSubscriptions(params: {
    page?: number;
    limit?: number;
    status?: string;
    user_id?: number;
    plan_id?: number;
    start_date_from?: string;
    start_date_to?: string;
    end_date_from?: string;
    end_date_to?: string;
  }): Promise<SubscriptionsResponse> {
    const response = await api.get('/api/admin/subscriptions', { params });
    return response.data;
  }
}

export const subscriptionsService = new SubscriptionsService();
