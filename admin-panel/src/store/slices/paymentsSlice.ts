import { createSlice, createAsyncThunk } from '@reduxjs/toolkit';
import { paymentsService } from '../../services/paymentsService';

interface Payment {
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

interface PaymentsState {
  payments: Payment[];
  loading: boolean;
  error: string | null;
  total: number;
  page: number;
  limit: number;
}

const initialState: PaymentsState = {
  payments: [],
  loading: false,
  error: null,
  total: 0,
  page: 1,
  limit: 20,
};

export const fetchPayments = createAsyncThunk(
  'payments/fetchPayments',
  async (params: { page?: number; limit?: number; status?: string; search?: string; created_from?: string; created_to?: string }, { rejectWithValue }) => {
    try {
      const response = await paymentsService.getPayments(params);
      return response;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка загрузки платежей');
    }
  }
);

export const getPaymentStats = createAsyncThunk(
  'payments/getStats',
  async (_, { rejectWithValue }) => {
    try {
      const response = await paymentsService.getStats();
      return response;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка загрузки статистики платежей');
    }
  }
);

const paymentsSlice = createSlice({
  name: 'payments',
  initialState,
  reducers: {
    clearError: (state) => {
      state.error = null;
    },
    setPage: (state, action) => {
      state.page = action.payload;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchPayments.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(fetchPayments.fulfilled, (state, action) => {
        state.loading = false;
        state.payments = action.payload.payments;
        state.total = action.payload.total;
      })
      .addCase(fetchPayments.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка загрузки платежей';
      })
      .addCase(getPaymentStats.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(getPaymentStats.fulfilled, (state) => {
        state.loading = false;
      })
      .addCase(getPaymentStats.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка загрузки статистики платежей';
      });
  },
});

export const { clearError, setPage } = paymentsSlice.actions;
export default paymentsSlice.reducer;
