import { createSlice, createAsyncThunk } from '@reduxjs/toolkit';
import { serversService } from '../../services/serversService';

interface Server {
  id: number;
  name: string;
  country: string;
  city: string | null;
  ip_address: string;
  port: number;
  current_users: number;
  max_users: number;
  is_active: boolean;
  health_status: string;
  created_at: string;
  // Дополнительные поля для мониторинга
  load_percentage?: number;
  bandwidth_used_mbps?: number;
  bandwidth_limit_mbps?: number;
  ping_ms?: number;
  supported_protocols?: string[];
  provider?: string;
  provider_region?: string;
  status?: string;
  wireguard_port?: number;
  xray_port?: number;
  openvpn_port?: number;
}

interface ServersState {
  servers: Server[];
  loading: boolean;
  error: string | null;
}

const initialState: ServersState = {
  servers: [],
  loading: false,
  error: null,
};

export const fetchServers = createAsyncThunk(
  'servers/fetchServers',
  async (_, { rejectWithValue }) => {
    try {
      const servers = await serversService.getServers();
      return servers;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка загрузки серверов');
    }
  }
);

export const createServer = createAsyncThunk(
  'servers/createServer',
  async (serverData: {
    name: string;
    country: string;
    city?: string;
    ip_address: string;
    port: number;
    max_users: number;
  }, { rejectWithValue }) => {
    try {
      const server = await serversService.createServer(serverData);
      return server;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка создания сервера');
    }
  }
);

export const updateServer = createAsyncThunk(
  'servers/updateServer',
  async ({ id, data }: { id: number; data: Partial<Server> }, { rejectWithValue }) => {
    try {
      const server = await serversService.updateServer(id, data);
      return server;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка обновления сервера');
    }
  }
);

export const toggleServerStatus = createAsyncThunk(
  'servers/toggleServerStatus',
  async (serverId: number, { rejectWithValue }) => {
    try {
      const server = await serversService.toggleServerStatus(serverId);
      return server;
    } catch (error: any) {
      return rejectWithValue(error.response?.data?.message || 'Ошибка переключения статуса сервера');
    }
  }
);

const serversSlice = createSlice({
  name: 'servers',
  initialState,
  reducers: {
    clearError: (state) => {
      state.error = null;
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchServers.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(fetchServers.fulfilled, (state, action) => {
        state.loading = false;
        state.servers = action.payload;
      })
      .addCase(fetchServers.rejected, (state, action) => {
        state.loading = false;
        state.error = action.error.message || 'Ошибка загрузки серверов';
      })
      .addCase(createServer.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(createServer.fulfilled, (state, action) => {
        state.loading = false;
        state.servers.push(action.payload);
      })
      .addCase(createServer.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка создания сервера';
      })
      .addCase(updateServer.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(updateServer.fulfilled, (state, action) => {
        state.loading = false;
        const index = state.servers.findIndex(s => s.id === action.payload.id);
        if (index !== -1) {
          state.servers[index] = action.payload;
        }
      })
      .addCase(updateServer.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка обновления сервера';
      })
      .addCase(toggleServerStatus.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(toggleServerStatus.fulfilled, (state, action) => {
        state.loading = false;
        const index = state.servers.findIndex(s => s.id === action.payload.id);
        if (index !== -1) {
          state.servers[index] = action.payload;
        }
      })
      .addCase(toggleServerStatus.rejected, (state, action) => {
        state.loading = false;
        state.error = action.payload as string || 'Ошибка переключения статуса сервера';
      });
  },
});

export const { clearError } = serversSlice.actions;
export default serversSlice.reducer;
