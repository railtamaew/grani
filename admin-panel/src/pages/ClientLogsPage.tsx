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
  Chip,
} from '@mui/material';
import { Refresh, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { clientLogsService, ClientLogEntry } from '../services/clientLogsService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const ClientLogsPage: React.FC = () => {
  const [logs, setLogs] = useState<ClientLogEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState({
    user_id: '',
    device_id: '',
    server_id: '',
    event_type: '',
    error_code: '',
    protocol: '',
    platform: '',
  });
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadLogs = useCallback(async (overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = { page: 1, limit: 200 };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.device_id) params.device_id = Number(activeFilters.device_id);
      if (activeFilters.server_id) params.server_id = Number(activeFilters.server_id);
      if (activeFilters.event_type) params.event_type = activeFilters.event_type;
      if (activeFilters.error_code) params.error_code = activeFilters.error_code;
      if (activeFilters.protocol) params.protocol = activeFilters.protocol;
      if (activeFilters.platform) params.platform = activeFilters.platform;
      const data = await clientLogsService.getClientLogs(params);
      setLogs(data.logs);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки клиентских логов');
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
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedLogs = [...logs].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'created_at') {
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
      'client-logs-export.csv',
      ['ID', 'Created At', 'User ID', 'Event', 'Protocol', 'Error Code', 'Message'],
      logs.map((log) => [
        log.id,
        log.created_at || '',
        log.user_id,
        log.event_type || '',
        log.protocol || '',
        log.error_code || '',
        log.message || '',
      ])
    );
  };

  return (
    <Box>
      <PageHeader
        title="Логи клиента"
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
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="User ID"
                value={filters.user_id}
                onChange={(e) => setFilters({ ...filters, user_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Device ID"
                value={filters.device_id}
                onChange={(e) => setFilters({ ...filters, device_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Server ID"
                value={filters.server_id}
                onChange={(e) => setFilters({ ...filters, server_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Event type"
                value={filters.event_type}
                onChange={(e) => setFilters({ ...filters, event_type: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Error code"
                value={filters.error_code}
                onChange={(e) => setFilters({ ...filters, error_code: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Protocol"
                value={filters.protocol}
                onChange={(e) => setFilters({ ...filters, protocol: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Platform"
                value={filters.platform}
                onChange={(e) => setFilters({ ...filters, platform: e.target.value })}
                size="small"
                fullWidth
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
                      device_id: '',
                      server_id: '',
                      event_type: '',
                      error_code: '',
                      protocol: '',
                      platform: '',
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
                <SortableHeader field="created_at">Время</SortableHeader>
                <SortableHeader field="user_id">User</SortableHeader>
                <SortableHeader field="event_type">Event</SortableHeader>
                <SortableHeader field="protocol">Protocol</SortableHeader>
                <SortableHeader field="error_code">Error</SortableHeader>
                <SortableHeader field="message">Message</SortableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {logs.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Логи не найдены
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sortedLogs.map((log) => (
                  <TableRow key={log.id}>
                    <TableCell>{log.id}</TableCell>
                    <TableCell>{formatDateTime(log.created_at)}</TableCell>
                    <TableCell>{log.user_id}</TableCell>
                    <TableCell>{log.event_type}</TableCell>
                    <TableCell>{log.protocol || '-'}</TableCell>
                    <TableCell>
                      {log.error_code ? (
                        <Chip label={log.error_code} color="error" size="small" />
                      ) : (
                        '-'
                      )}
                    </TableCell>
                    <TableCell>{log.message || '-'}</TableCell>
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

export default ClientLogsPage;
