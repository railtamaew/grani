import React, { useCallback, useEffect, useState } from 'react';
import {
  Box,
  Typography,
  Grid,
  TextField,
  Button,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  CircularProgress,
  Alert,
} from '@mui/material';
import { Refresh, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { dashboardService, ConnectionLog } from '../services/dashboardService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const ConnectionLogsPage: React.FC = () => {
  const [logs, setLogs] = useState<ConnectionLog[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState({
    user_id: '',
    server_id: '',
    connection_type: '',
  });
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');

  const loadLogs = useCallback(async (overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = { page: 1, limit: 200 };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.server_id) params.server_id = Number(activeFilters.server_id);
      if (activeFilters.connection_type) params.connection_type = activeFilters.connection_type;
      const data = await dashboardService.getConnectionLogs(params);
      setLogs(data.logs);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки логов подключений');
    } finally {
      setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    loadLogs();
  }, [loadLogs]);

  const formatDateTime = (value?: string | null) => {
    if (!value) return '-';
    return new Date(value).toLocaleString('ru-RU');
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('desc'); }
  };
  const sortedLogs = [...logs].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'connected_at' || sortField === 'disconnected_at') {
      aVal = aVal ? new Date(aVal).getTime() : 0;
      bVal = bVal ? new Date(bVal).getTime() : 0;
    } else if (typeof aVal === 'string') {
      aVal = (aVal || '').toLowerCase();
      bVal = (bVal || '').toLowerCase();
    }
    if (aVal < bVal) return sortDirection === 'asc' ? -1 : 1;
    if (aVal > bVal) return sortDirection === 'asc' ? 1 : -1;
    return 0;
  });
  const SortableHeader = ({ field, children }: { field: string; children: React.ReactNode }) => (
    <TableCell sx={{ cursor: 'pointer', userSelect: 'none' }} onClick={() => handleSort(field)}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
        {children}
        {sortField === field && (sortDirection === 'asc' ? <ArrowUpward fontSize="small" /> : <ArrowDownward fontSize="small" />)}
      </Box>
    </TableCell>
  );

  const handleExport = () => {
    downloadCsv(
      'connection-logs-export.csv',
      ['ID', 'User ID', 'Device ID', 'Server ID', 'Type', 'IP', 'Connected', 'Disconnected', 'Duration (s)'],
      logs.map((log) => [
        log.id,
        log.user_id,
        log.device_id,
        log.server_id,
        log.connection_type || '',
        log.ip_address || '',
        log.connected_at || '',
        log.disconnected_at || '',
        log.duration_seconds ?? '',
      ])
    );
  };

  return (
    <Box>
      <PageHeader
        title="Логи подключений"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={logs.length === 0}>
              Экспорт CSV
            </Button>
            <Button variant="outlined" startIcon={<Refresh />} onClick={() => loadLogs()} disabled={loading}>
              Обновить
            </Button>
          </Box>
        )}
      />

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <FilterCard>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="User ID"
              value={filters.user_id}
              onChange={(e) => setFilters({ ...filters, user_id: e.target.value })}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="Server ID"
              value={filters.server_id}
              onChange={(e) => setFilters({ ...filters, server_id: e.target.value })}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="Тип подключения"
              value={filters.connection_type}
              onChange={(e) => setFilters({ ...filters, connection_type: e.target.value })}
              size="small"
              fullWidth
              placeholder="connect / disconnect"
            />
          </Grid>
          <Grid item xs={12}>
            <Box display="flex" gap={2}>
              <Button variant="contained" onClick={() => loadLogs()}>
                Применить
              </Button>
              <Button
                variant="outlined"
                onClick={() => {
                  const nextFilters = {
                    user_id: '',
                    server_id: '',
                    connection_type: '',
                  };
                  setFilters(nextFilters);
                  loadLogs(nextFilters);
                }}
              >
                Сбросить
              </Button>
            </Box>
          </Grid>
        </Grid>
      </FilterCard>

      {loading ? (
        <Box display="flex" justifyContent="center" alignItems="center" minHeight="200px">
          <CircularProgress />
        </Box>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <SortableHeader field="id">ID</SortableHeader>
                <SortableHeader field="connected_at">Подключено</SortableHeader>
                <SortableHeader field="user_id">User</SortableHeader>
                <SortableHeader field="device_id">Device</SortableHeader>
                <SortableHeader field="server_id">Server</SortableHeader>
                <SortableHeader field="connection_type">Тип</SortableHeader>
                <SortableHeader field="ip_address">IP</SortableHeader>
                <SortableHeader field="disconnected_at">Отключено</SortableHeader>
                <SortableHeader field="duration_seconds">Длительность</SortableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {logs.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={9} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Логи не найдены
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sortedLogs.map((log) => (
                  <TableRow key={log.id}>
                    <TableCell>{log.id}</TableCell>
                    <TableCell>{formatDateTime(log.connected_at)}</TableCell>
                    <TableCell>{log.user_id}</TableCell>
                    <TableCell>{log.device_id}</TableCell>
                    <TableCell>{log.server_id}</TableCell>
                    <TableCell>{log.connection_type || '-'}</TableCell>
                    <TableCell>{log.ip_address || '-'}</TableCell>
                    <TableCell>{formatDateTime(log.disconnected_at)}</TableCell>
                    <TableCell>{log.duration_seconds != null ? `${log.duration_seconds} с` : '-'}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
};

export default ConnectionLogsPage;
