import { createSlice, createAsyncThunk, PayloadAction } from '@reduxjs/toolkit';
import { authService } from '../../services/authService';

export interface User {
  id: number;
  email: string;
  username?: string;
  role: 'owner' | 'admin' | 'support' | 'read_only';
  isActive: boolean;
  createdAt: string;
}

export interface AuthState {
  user: User | null;
  token: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  error: string | null;
}

const initialState: AuthState = {
  user: null,
  token: localStorage.getItem('token'),
  isAuthenticated: !!localStorage.getItem('token'),
  isLoading: false,
  error: null,
};

// Async thunks for real API calls
export const loginUser = createAsyncThunk(
  'auth/login',
  async (credentials: { email: string; password: string }, { rejectWithValue }) => {
    try {
      const response = await authService.login(credentials);
      return response;
    } catch (error: any) {
      const msg = (error as any).normalized?.message
        || error.response?.data?.error?.message
        || error.response?.data?.detail
        || 'Login failed';
      return rejectWithValue(typeof msg === 'string' ? msg : 'Login failed');
    }
  }
);

export const logoutUser = createAsyncThunk(
  'auth/logout',
  async (_, { rejectWithValue }) => {
    try {
      await authService.logout();
      return null;
    } catch (error: any) {
      const msg = (error as any).normalized?.message
        || error.response?.data?.error?.message
        || error.response?.data?.detail
        || 'Logout failed';
      return rejectWithValue(typeof msg === 'string' ? msg : 'Logout failed');
    }
  }
);

export const getCurrentUser = createAsyncThunk(
  'auth/getCurrentUser',
  async (_, { rejectWithValue }) => {
    try {
      const response = await authService.getCurrentUser();
      return response;
    } catch (error: any) {
      const msg = (error as any).normalized?.message
        || error.response?.data?.error?.message
        || error.response?.data?.detail
        || 'Failed to get user';
      return rejectWithValue(typeof msg === 'string' ? msg : 'Failed to get user');
    }
  }
);

const authSlice = createSlice({
  name: 'auth',
  initialState,
  reducers: {
    clearError: (state) => {
      state.error = null;
    },
    setToken: (state, action: PayloadAction<string>) => {
      state.token = action.payload;
      state.isAuthenticated = true;
      localStorage.setItem('token', action.payload);
    },
  },
  extraReducers: (builder) => {
    builder
      // Login
      .addCase(loginUser.pending, (state) => {
        state.isLoading = true;
        state.error = null;
      })
      .addCase(loginUser.fulfilled, (state, action) => {
        state.isLoading = false;
        // Создаем пользователя из ответа API
        const userData = action.payload.user;
        const rawRole = userData.role;
        const normalizedRole = (rawRole === 'owner' || rawRole === 'admin' || rawRole === 'support' || rawRole === 'read_only')
          ? rawRole
          : 'admin';
        state.user = {
          id: userData.id,
          email: userData.email,
          username: userData.email.split('@')[0],
          role: normalizedRole,
          isActive: userData.is_active !== false,
          createdAt: new Date().toISOString()
        };
        state.token = action.payload.access_token;
        state.isAuthenticated = true;
        localStorage.setItem('token', action.payload.access_token);
      })
      .addCase(loginUser.rejected, (state, action) => {
        state.isLoading = false;
        state.error = action.payload as string;
      })
      // Logout
      .addCase(logoutUser.fulfilled, (state) => {
        state.user = null;
        state.token = null;
        state.isAuthenticated = false;
        localStorage.removeItem('token');
      })
      // Get current user
      .addCase(getCurrentUser.fulfilled, (state, action) => {
        state.user = action.payload;
        state.isAuthenticated = true;
      })
      .addCase(getCurrentUser.rejected, (state) => {
        state.user = null;
        state.token = null;
        state.isAuthenticated = false;
        localStorage.removeItem('token');
      });
  },
});

export const { clearError, setToken } = authSlice.actions;
export default authSlice.reducer;
