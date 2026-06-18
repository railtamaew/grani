import { createSlice, createAsyncThunk } from '@reduxjs/toolkit';
import { usersService } from '../../services/usersService';

interface User {
  id: number;
  email: string;
  is_active: boolean;
  is_verified: boolean;
  created_at: string;
  subscription_status?: string;
  subscription_end_date?: string;
  devices_count?: number;
  country?: string;
  auth_provider?: string;
  last_seen_at?: string;
}

interface UsersState {
  users: User[];
  loading: boolean;
  error: string | null;
  total: number;
  page: number;
  limit: number;
}

const initialState: UsersState = {
  users: [],
  loading: false,
  error: null,
  total: 0,
  page: 1,
  limit: 20,
};

export const fetchUsers = createAsyncThunk(
  'users/fetchUsers',
  async (params: { 
    page?: number; 
    limit?: number; 
    search?: string;
    country?: string;
    auth_provider?: string;
    has_subscription?: boolean;
    has_errors?: boolean;
  }, { rejectWithValue }) => {
    try {
      const response = await usersService.getUsers(params);
      return response;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка загрузки пользователей');
    }
  }
);

export const blockUser = createAsyncThunk(
  'users/blockUser',
  async (userId: number, { rejectWithValue }) => {
    try {
      await usersService.blockUser(userId);
      return userId;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка блокировки пользователя');
    }
  }
);

export const unblockUser = createAsyncThunk(
  'users/unblockUser',
  async (userId: number, { rejectWithValue }) => {
    try {
      await usersService.unblockUser(userId);
      return userId;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка разблокировки пользователя');
    }
  }
);

const usersSlice = createSlice({
  name: 'users',
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
      .addCase(fetchUsers.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(fetchUsers.fulfilled, (state, action) => {
        state.loading = false;
        state.users = action.payload.users;
        state.total = action.payload.total;
        if (action.payload.page) state.page = action.payload.page;
        if (action.payload.limit) state.limit = action.payload.limit;
      })
      .addCase(fetchUsers.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка загрузки пользователей';
      })
      .addCase(blockUser.fulfilled, (state, action) => {
        const user = state.users.find(u => u.id === action.payload);
        if (user) {
          user.is_active = false;
        }
      })
      .addCase(unblockUser.fulfilled, (state, action) => {
        const user = state.users.find(u => u.id === action.payload);
        if (user) {
          user.is_active = true;
        }
      });
  },
});

export const { clearError, setPage } = usersSlice.actions;
export default usersSlice.reducer;
