import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Collapse,
  Grid,
  IconButton,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from '@mui/material';
import {
  ContentCopy,
  ExpandLess,
  ExpandMore,
  Refresh,
} from '@mui/icons-material';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';
import {
  clientLogsService,
  SupportDiagnosticReport,
} from '../services/clientLogsService';
import { downloadCsv } from '../utils/csv';

const valueOrDash = (value: unknown): string => {
  if (value === null || value === undefined || value === '') return '-';
  return String(value);
};

const formatDateTime = (value?: string | null): string => {
  if (!value) return '-';
  return new Date(value).toLocaleString('ru-RU');
};

const detailsOf = (log: SupportDiagnosticReport): Record<string, any> => {
  if (!log.error_details || typeof log.error_details !== 'object') return {};
  return log.error_details;
};

const SupportDiagnosticsPage: React.FC = () => {
  const [logs, setLogs] = useState<SupportDiagnosticReport[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [filters, setFilters] = useState({
    user_id: '',
    device_id: '',
    email: '',
    report_id: '',
  });

  const loadReports = useCallback(async (overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = {
        page: 1,
        limit: 200,
        context_minutes: 15,
        context_limit: 50,
      };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.device_id) {
        params.device_id = Number(activeFilters.device_id);
      }
      if (activeFilters.email) params.email = activeFilters.email;
      if (activeFilters.report_id) params.report_id = activeFilters.report_id;
      const data = await clientLogsService.getSupportDiagnostics(params);
      setLogs(data.reports);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки диагностики');
    } finally {
      setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    loadReports();
  }, [loadReports]);

  const rows = useMemo(() => logs, [logs]);

  const handleExport = () => {
    downloadCsv(
      'support-diagnostics.csv',
      [
        'ID',
        'Created At',
        'User ID',
        'Email',
        'Report ID',
        'App',
        'Access',
        'VPN',
        'Server',
        'Protocol',
        'Last Error',
      ],
      rows.map((log) => {
        const details = detailsOf(log);
        return [
          log.id,
          log.created_at || '',
          log.user_id,
          valueOrDash(log.user_email || details.email),
          valueOrDash(log.report_id || details.report_id),
          `${valueOrDash(log.app_version || details.app_version)}+${valueOrDash(log.build_number || details.build_number)}`,
          valueOrDash(log.access_status || details.access_status),
          valueOrDash(log.vpn_state || details.vpn_state),
          valueOrDash(log.server || details.server),
          valueOrDash(details.protocol || log.protocol),
          valueOrDash(log.last_error || details.last_error),
        ];
      })
    );
  };

  const copyJson = async (log: SupportDiagnosticReport) => {
    await navigator.clipboard.writeText(
      JSON.stringify(
        {
          id: log.id,
          created_at: log.created_at,
          user_id: log.user_id,
          device_id: log.device_id,
          server_id: log.server_id,
          protocol: log.protocol,
          error_code: log.error_code,
          context_minutes: log.context_minutes,
          context_events: log.context_events || [],
          details: detailsOf(log),
        },
        null,
        2
      )
    );
  };

  return (
    <Box>
      <PageHeader
        title="Диагностика поддержки"
        actions={(
          <Box display="flex" gap={1}>
            <Button
              variant="outlined"
              onClick={handleExport}
              disabled={rows.length === 0}
            >
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => loadReports()}
              disabled={loading}
            >
              Обновить
            </Button>
          </Box>
        )}
      />
      <Typography variant="body2" color="textSecondary" sx={{ mt: -2, mb: 3 }}>
        Ручные отчеты, отправленные пользователями из приложения.
      </Typography>

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
              onChange={(e) =>
                setFilters({ ...filters, user_id: e.target.value })
              }
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="Device DB ID"
              value={filters.device_id}
              onChange={(e) =>
                setFilters({ ...filters, device_id: e.target.value })
              }
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="Email"
              value={filters.email}
              onChange={(e) =>
                setFilters({ ...filters, email: e.target.value })
              }
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="Report ID"
              value={filters.report_id}
              onChange={(e) =>
                setFilters({ ...filters, report_id: e.target.value })
              }
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12}>
            <Box display="flex" gap={2}>
              <Button variant="contained" onClick={() => loadReports()}>
                Применить
              </Button>
              <Button
                variant="outlined"
                onClick={() => {
                  const nextFilters = {
                    user_id: '',
                    device_id: '',
                    email: '',
                    report_id: '',
                  };
                  setFilters(nextFilters);
                  loadReports(nextFilters);
                }}
              >
                Сбросить
              </Button>
            </Box>
          </Grid>
        </Grid>
      </FilterCard>

      {loading ? (
        <Box display="flex" justifyContent="center" alignItems="center" minHeight="220px">
          <CircularProgress />
        </Box>
      ) : (
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell />
                <TableCell>Время</TableCell>
                <TableCell>User</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>App</TableCell>
                <TableCell>Доступ</TableCell>
                <TableCell>VPN</TableCell>
                <TableCell>Сервер</TableCell>
                <TableCell>Protocol</TableCell>
                <TableCell>Last error</TableCell>
                <TableCell align="right">Действия</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={11} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Диагностические отчеты не найдены
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                rows.map((log) => {
                  const details = detailsOf(log);
                  const isExpanded = expandedId === log.id;
                  return (
                    <React.Fragment key={log.id}>
                      <TableRow hover>
                        <TableCell>
                          <IconButton
                            size="small"
                            onClick={() =>
                              setExpandedId(isExpanded ? null : log.id)
                            }
                          >
                            {isExpanded ? <ExpandLess /> : <ExpandMore />}
                          </IconButton>
                        </TableCell>
                        <TableCell>{formatDateTime(log.created_at)}</TableCell>
                        <TableCell>{log.user_id}</TableCell>
                        <TableCell>
                          {valueOrDash(log.user_email || details.email)}
                        </TableCell>
                        <TableCell>
                          {valueOrDash(log.app_version || details.app_version)}+
                          {valueOrDash(log.build_number || details.build_number)}
                        </TableCell>
                        <TableCell>
                          <Chip
                            label={valueOrDash(
                              log.access_status || details.access_status
                            )}
                            size="small"
                            variant="outlined"
                          />
                        </TableCell>
                        <TableCell>
                          {valueOrDash(log.vpn_state || details.vpn_state)}
                        </TableCell>
                        <TableCell>
                          {valueOrDash(log.server || details.server)}
                        </TableCell>
                        <TableCell>{valueOrDash(details.protocol || log.protocol)}</TableCell>
                        <TableCell
                          sx={{
                            maxWidth: 240,
                            whiteSpace: 'nowrap',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                          }}
                        >
                          {valueOrDash(log.last_error || details.last_error)}
                        </TableCell>
                        <TableCell align="right">
                          <Tooltip title="Скопировать JSON">
                            <IconButton size="small" onClick={() => copyJson(log)}>
                              <ContentCopy fontSize="small" />
                            </IconButton>
                          </Tooltip>
                        </TableCell>
                      </TableRow>
                      <TableRow>
                        <TableCell colSpan={11} sx={{ py: 0, borderBottom: 0 }}>
                          <Collapse in={isExpanded} timeout="auto" unmountOnExit>
                            <Box sx={{ m: 2 }}>
                              <Typography variant="subtitle2" gutterBottom>
                                События перед отчётом за {log.context_minutes || 15} мин
                              </Typography>
                              <TableContainer component={Paper} variant="outlined" sx={{ mb: 2 }}>
                                <Table size="small">
                                  <TableHead>
                                    <TableRow>
                                      <TableCell>Время</TableCell>
                                      <TableCell>Event</TableCell>
                                      <TableCell>Protocol</TableCell>
                                      <TableCell>Server</TableCell>
                                      <TableCell>Error</TableCell>
                                      <TableCell>Message</TableCell>
                                    </TableRow>
                                  </TableHead>
                                  <TableBody>
                                    {(log.context_events || []).length === 0 ? (
                                      <TableRow>
                                        <TableCell colSpan={6} align="center">
                                          <Typography variant="body2" color="textSecondary">
                                            Событий рядом с отчётом нет
                                          </Typography>
                                        </TableCell>
                                      </TableRow>
                                    ) : (
                                      (log.context_events || []).map((event) => (
                                        <TableRow key={event.id}>
                                          <TableCell>{formatDateTime(event.created_at)}</TableCell>
                                          <TableCell>{valueOrDash(event.event_type)}</TableCell>
                                          <TableCell>{valueOrDash(event.protocol)}</TableCell>
                                          <TableCell>{valueOrDash(event.server_id)}</TableCell>
                                          <TableCell>
                                            {event.error_code ? (
                                              <Chip
                                                label={event.error_code}
                                                color="error"
                                                size="small"
                                              />
                                            ) : (
                                              '-'
                                            )}
                                          </TableCell>
                                          <TableCell
                                            sx={{
                                              maxWidth: 420,
                                              whiteSpace: 'nowrap',
                                              overflow: 'hidden',
                                              textOverflow: 'ellipsis',
                                            }}
                                          >
                                            {valueOrDash(event.message)}
                                          </TableCell>
                                        </TableRow>
                                      ))
                                    )}
                                  </TableBody>
                                </Table>
                              </TableContainer>
                              <Typography variant="subtitle2" gutterBottom>
                                Полный JSON отчёта
                              </Typography>
                              <Box
                                component="pre"
                                sx={{
                                  p: 2,
                                  bgcolor: '#0F1E2A',
                                  color: '#EEF4F7',
                                  borderRadius: 1,
                                  overflow: 'auto',
                                  fontSize: 12,
                                }}
                              >
                                {JSON.stringify(details, null, 2)}
                              </Box>
                            </Box>
                          </Collapse>
                        </TableCell>
                      </TableRow>
                    </React.Fragment>
                  );
                })
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
};

export default SupportDiagnosticsPage;
