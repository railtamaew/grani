import React, { useCallback, useState } from 'react';
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
  Alert,
  Chip,
  FormControlLabel,
  Checkbox,
} from '@mui/material';
import { CircularProgress } from '@mui/material';
import { usersService } from '../services/usersService';
import { downloadCsv } from '../utils/csv';

export interface DiagnosticEvent {
  timestamp?: string | null;
  source: 'client_log' | 'connection_log' | 'server_log';
  id?: number;
  event_type?: string;
  connection_type?: string;
  message?: string | null;
  error_code?: string | null;
  line?: string;
  protocol?: string | null;
  server_id?: number | null;
  duration_seconds?: number | null;
  [key: string]: any;
}

interface UserDiagnosticsViewProps {
  userId: number;
  showTitle?: boolean;
}

const UserDiagnosticsView: React.FC<UserDiagnosticsViewProps> = ({ userId, showTitle = true }) => {
  const [events, setEvents] = useState<DiagnosticEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState({
    from_time: '',
    to_time: '',
    server_id: '',
    include_server_logs: false,
  });

  const loadDiagnostics = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const params: any = { limit: 200 };
      if (filters.from_time) params.from_time = filters.from_time;
      if (filters.to_time) params.to_time = filters.to_time;
      if (filters.server_id) params.server_id = Number(filters.server_id);
      if (filters.include_server_logs) params.include_server_logs = true;
      const data = await usersService.getUserDiagnostics(userId, params);
      setEvents(data.events || []);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки диагностики');
      setEvents([]);
    } finally {
      setLoading(false);
    }
  }, [userId, filters]);

  const formatDate = (dateString: string | null | undefined) => {
    if (!dateString) return '-';
    return new Date(dateString).toLocaleString('ru-RU');
  };

  const isError = (e: DiagnosticEvent) => {
    if (e.source === 'client_log' && e.error_code) return true;
    if (e.source === 'connection_log' && e.connection_type === 'disconnect' && e.duration_seconds != null && e.duration_seconds < 10) return true;
    if (e.source === 'server_log' && e.line && /error|fail|refused/i.test(e.line)) return true;
    return false;
  };

  const getEventType = (e: DiagnosticEvent) => {
    if (e.source === 'client_log') return e.event_type || '-';
    if (e.source === 'connection_log') return e.connection_type || '-';
    return e.protocol || '-';
  };
  const getEventDetails = (e: DiagnosticEvent) => {
    if (e.source === 'client_log') return (e.message || e.error_code || '-') as string;
    if (e.source === 'connection_log') return `Сервер ${e.server_id}${e.duration_seconds != null ? `, ${e.duration_seconds} с` : ''}`;
    return (e.line || '') as string;
  };

  const handleExportCsv = () => {
    const headers = ['Время', 'Источник', 'Событие / тип', 'Детали', 'Код ошибки', 'Server ID'];
    const rows = events.map((e) => [
      formatDate(e.timestamp),
      e.source === 'client_log' ? 'Клиент' : e.source === 'connection_log' ? 'Подключение' : 'Сервер',
      getEventType(e),
      getEventDetails(e),
      e.error_code ?? '',
      e.server_id ?? '',
    ]);
    downloadCsv(`diagnostics-user-${userId}.csv`, headers, rows);
  };

  const handleExportJson = () => {
    const payload = { user_id: userId, exported_at: new Date().toISOString(), count: events.length, events };
    const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `diagnostics-user-${userId}.json`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 1, mb: 2 }}>
        {showTitle && (
          <Typography variant="h6">Диагностика подключений (пользователь {userId})</Typography>
        )}
        {!showTitle && <Box />}
        <Box sx={{ display: 'flex', gap: 1 }}>
          <Button variant="outlined" size="small" onClick={handleExportCsv} disabled={events.length === 0}>
            Экспорт CSV
          </Button>
          <Button variant="outlined" size="small" onClick={handleExportJson} disabled={events.length === 0}>
            Экспорт JSON
          </Button>
        </Box>
      </Box>
      <Grid container spacing={2} sx={{ mb: 2 }}>
        <Grid item xs={12} sm={3}>
          <TextField
            size="small"
            fullWidth
            label="С (дата/время)"
            type="datetime-local"
            value={filters.from_time}
            onChange={(e) => setFilters((f) => ({ ...f, from_time: e.target.value }))}
            InputLabelProps={{ shrink: true }}
          />
        </Grid>
        <Grid item xs={12} sm={3}>
          <TextField
            size="small"
            fullWidth
            label="По (дата/время)"
            type="datetime-local"
            value={filters.to_time}
            onChange={(e) => setFilters((f) => ({ ...f, to_time: e.target.value }))}
            InputLabelProps={{ shrink: true }}
          />
        </Grid>
        <Grid item xs={12} sm={2}>
          <TextField
            size="small"
            fullWidth
            label="Server ID"
            value={filters.server_id}
            onChange={(e) => setFilters((f) => ({ ...f, server_id: e.target.value }))}
            placeholder="опционально"
          />
        </Grid>
        <Grid item xs={12} sm={2} sx={{ display: 'flex', alignItems: 'center' }}>
          <FormControlLabel
            control={
              <Checkbox
                checked={filters.include_server_logs}
                onChange={(e) => setFilters((f) => ({ ...f, include_server_logs: e.target.checked }))}
              />
            }
            label="Логи сервера (укажите Server ID)"
          />
        </Grid>
        <Grid item xs={12} sm={2}>
          <Button variant="contained" onClick={loadDiagnostics} disabled={loading}>
            {loading ? <CircularProgress size={24} /> : 'Загрузить'}
          </Button>
        </Grid>
      </Grid>
      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}
      {filters.include_server_logs && !filters.server_id && (
        <Alert severity="info" sx={{ mb: 2 }}>
          Для логов сервера укажите Server ID выше — иначе в выдачу попадут только логи клиента и подключений.
        </Alert>
      )}
      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Время</TableCell>
              <TableCell>Источник</TableCell>
              <TableCell>Событие / тип</TableCell>
              <TableCell>Детали</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {events.length === 0 && !loading && (
              <TableRow>
                <TableCell colSpan={4} align="center">
                  Нажмите «Загрузить» для получения событий
                </TableCell>
              </TableRow>
            )}
            {events.map((e, idx) => (
              <TableRow key={e.id ? `${e.source}-${e.id}` : idx} sx={{ bgcolor: isError(e) ? 'action.hover' : undefined }}>
                <TableCell>{formatDate(e.timestamp)}</TableCell>
                <TableCell>
                  <Chip
                    label={e.source === 'client_log' ? 'Клиент' : e.source === 'connection_log' ? 'Подключение' : 'Сервер'}
                    size="small"
                    color={e.source === 'server_log' ? 'default' : 'primary'}
                    variant="outlined"
                  />
                </TableCell>
                <TableCell>
                  {e.source === 'client_log' && (e.event_type || '-')}
                  {e.source === 'connection_log' && (e.connection_type || '-')}
                  {e.source === 'server_log' && (e.protocol || '-')}
                </TableCell>
                <TableCell sx={{ fontFamily: 'monospace', fontSize: '0.8rem', wordBreak: 'break-all' }}>
                  {e.source === 'client_log' && (e.message || e.error_code || '-')}
                  {e.source === 'connection_log' && `Сервер ${e.server_id}${e.duration_seconds != null ? `, ${e.duration_seconds} с` : ''}`}
                  {e.source === 'server_log' && e.line}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
};

export default UserDiagnosticsView;
