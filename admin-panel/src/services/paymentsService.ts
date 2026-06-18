import { api } from './api';

export interface Payment {
  id: number;
  user_id: number;
  user_email: string;
  amount: number;
  currency: string;
  payment_method: string;
  status: string;
  created_at: string;
  updated_at: string;
  subscription_id?: number;
  plan_name?: string;
}

export interface PaymentStats {
  total_revenue: number;
  monthly_revenue: number;
  total_payments: number;
  successful_payments: number;
  failed_payments: number;
  pending_payments: number;
}

class PaymentsService {
  async getPayments(params: {
    page?: number;
    limit?: number;
    status?: string;
    search?: string;
    created_from?: string;
    created_to?: string;
  }): Promise<{
    payments: Payment[];
    total: number;
  }> {
    const response = await api.get('/api/admin/payments', { params });
    return response.data;
  }

  async getPayment(paymentId: number): Promise<Payment> {
    const response = await api.get<Payment>(`/api/admin/payments/${paymentId}`);
    return response.data;
  }

  async getStats(): Promise<PaymentStats> {
    const response = await api.get<PaymentStats>('/api/admin/payments/stats');
    return response.data;
  }

  async getPaymentHistory(userId: number): Promise<Payment[]> {
    const response = await api.get<Payment[]>(`/api/admin/payments/user/${userId}`);
    return response.data;
  }
}

export const paymentsService = new PaymentsService();


