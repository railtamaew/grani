import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Grid,
  Paper,
  MenuItem,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
  FormControlLabel,
  Switch,
} from '@mui/material';
import OpenInNewIcon from '@mui/icons-material/OpenInNew';

import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';
import {
  observabilityService,
  ObservabilityEvent,
  ObservabilityIncident,
  ObservabilityIncidentComment,
} from '../services/observabilityService';

const CONNECTIVITY_THRESHOLDS = {
  minSamples: 20,
  p95HealthyMs: 15000,
  p95CriticalMs: 20000,
  successHealthyPct: 92,
  successCriticalPct: 85,
  degradedHealthyPct: 8,
  degradedCriticalPct: 15,
};

const ObservabilityPage: React.FC = () => {
  const [events, setEvents] = useState<ObservabilityEvent[]>([]);
  const [incidents, setIncidents] = useState<ObservabilityIncident[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [eventsCursor, setEventsCursor] = useState<string | null>(null);
  const [eventsNextCursor, setEventsNextCursor] = useState<string | null>(null);
  const [eventsPrevCursor, setEventsPrevCursor] = useState<string | null>(null);
  const [eventsCursorHistory, setEventsCursorHistory] = useState<string[]>([]);
  const [incidentsCursor, setIncidentsCursor] = useState<string | null>(null);
  const [incidentsNextCursor, setIncidentsNextCursor] = useState<string | null>(null);
  const [incidentsPrevCursor, setIncidentsPrevCursor] = useState<string | null>(null);
  const [incidentsCursorHistory, setIncidentsCursorHistory] = useState<string[]>([]);
  const [eventsCursorDirection, setEventsCursorDirection] = useState<'next' | 'prev'>('next');
  const [incidentsCursorDirection, setIncidentsCursorDirection] = useState<'next' | 'prev'>('next');
  const [autoRefreshEvents, setAutoRefreshEvents] = useState(false);
  const [eventsDetailLevel, setEventsDetailLevel] = useState<'basic' | 'enriched'>('basic');
  const [hasNewEventsAvailable, setHasNewEventsAvailable] = useState(false);
  const [latestKnownEventId, setLatestKnownEventId] = useState<number | null>(null);
  const [metrics, setMetrics] = useState<{ open_total: number; by_severity: Record<string, number> } | null>(null);
  const [connectivitySummary, setConnectivitySummary] = useState<{
    window_hours: number;
    duration_by_protocol: Record<string, { samples: number; p50_ms: number; p95_ms: number; avg_ms: number }>;
    stage_errors: Record<string, Record<string, number>>;
    degraded_rate: Record<string, { degraded_count: number; starts_count: number; degraded_rate_pct: number }>;
    success_rate: Record<string, { success_count: number; starts_count: number; success_rate_pct: number }>;
    network_split: Record<string, Record<string, { errors: number; starts: number }>>;
    signals: { dataplane_not_ready_after_apply: number };
  } | null>(null);
  const [selectedIncident, setSelectedIncident] = useState<ObservabilityIncident | null>(null);
  const [incidentComments, setIncidentComments] = useState<ObservabilityIncidentComment[]>([]);
  const [relatedEvents, setRelatedEvents] = useState<ObservabilityEvent[]>([]);
  const [relatedFilters, setRelatedFilters] = useState<{ vpn_session_id?: string | null; request_id?: string | null; server_id?: number | null } | null>(null);
  const [commentText, setCommentText] = useState('');
  const [statusValue, setStatusValue] = useState('');
  const [assigneeValue, setAssigneeValue] = useState('');
  const [incidentDialogOpen, setIncidentDialogOpen] = useState(false);
  const [sortField, setSortField] = useState<'last_seen_at' | 'first_seen_at' | 'severity' | 'status' | 'id'>('last_seen_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [incidentFilters, setIncidentFilters] = useState({
    status: '',
    severity: '',
    incident_type: '',
    server_id: '',
    assignee_user_id: '',
    breached_only: false,
  });
  const [testDialogOpen, setTestDialogOpen] = useState(false);
  const [testForm, setTestForm] = useState({
    incident_type: 'config_conflict',
    severity: 'P2',
    user_id: '',
    server_id: '',
    vpn_session_id: '',
    request_id: '',
    message: '',
  });
  const [filters, setFilters] = useState({
    user_id: '',
    server_id: '',
    vpn_session_id: '',
    event_name: '',
    severity: '',
  });

  const buildEventParams = useCallback(
    (cursor: string | null, direction: 'next' | 'prev') => {
      const eventParams: any = { limit: 200, cursor: cursor || undefined };
      eventParams.cursor_direction = direction;
      if (filters.user_id) eventParams.user_id = Number(filters.user_id);
      if (filters.server_id) eventParams.server_id = Number(filters.server_id);
      if (filters.vpn_session_id) eventParams.vpn_session_id = filters.vpn_session_id;
      if (filters.event_name) eventParams.event_name = filters.event_name;
      if (filters.severity) eventParams.severity = filters.severity;
      eventParams.detail_level = eventsDetailLevel;
      if (eventsDetailLevel === 'enriched') {
        eventParams.correlation_window_seconds = 120;
      }
      return eventParams;
    },
    [filters, eventsDetailLevel]
  );

  const refreshEventsToNewest = useCallback(async () => {
    const eventsResp = await observabilityService.getEvents(buildEventParams(null, 'next'));
    setEvents(eventsResp.items || []);
    setEventsNextCursor(eventsResp.next_cursor || null);
    setEventsPrevCursor(eventsResp.prev_cursor || null);
    if (eventsResp.items?.length) {
      setLatestKnownEventId(eventsResp.items[0].id);
    }
    setHasNewEventsAvailable(false);
  }, [buildEventParams]);

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [eventsResp, incidentsResp, connectivityResp] = await Promise.all([
        observabilityService.getEvents(buildEventParams(eventsCursor, eventsCursorDirection)),
        observabilityService.getIncidents({
          limit: 200,
          cursor: incidentsCursor || undefined,
          cursor_direction: incidentsCursorDirection,
          status: incidentFilters.status || undefined,
          severity: incidentFilters.severity || undefined,
          incident_type: incidentFilters.incident_type || undefined,
          server_id: incidentFilters.server_id ? Number(incidentFilters.server_id) : undefined,
          assignee_user_id: incidentFilters.assignee_user_id ? Number(incidentFilters.assignee_user_id) : undefined,
          breached_only: incidentFilters.breached_only || undefined,
          sort_by: sortField,
          sort_dir: sortDirection,
        }),
        observabilityService.getConnectivitySummary(24),
      ]);
      setEvents(eventsResp.items || []);
      setEventsNextCursor(eventsResp.next_cursor || null);
      setEventsPrevCursor(eventsResp.prev_cursor || null);
      if (eventsResp.items?.length) {
        setLatestKnownEventId(eventsResp.items[0].id);
      }
      const onNewestPage = eventsCursor === null && eventsCursorDirection === 'next';
      if (onNewestPage) {
        setHasNewEventsAvailable(false);
      }
      setIncidents(incidentsResp.items || []);
      setIncidentsNextCursor(incidentsResp.next_cursor || null);
      setIncidentsPrevCursor(incidentsResp.prev_cursor || null);
      const metricsResp = await observabilityService.getIncidentMetrics();
      setMetrics(metricsResp);
      setConnectivitySummary(connectivityResp);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки observability данных');
      setEvents([]);
      setIncidents([]);
      setMetrics(null);
      setConnectivitySummary(null);
    } finally {
      setLoading(false);
    }
  }, [
    buildEventParams,
    incidentFilters,
    sortField,
    sortDirection,
    eventsCursor,
    incidentsCursor,
    eventsCursorDirection,
    incidentsCursorDirection,
  ]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  useEffect(() => {
    if (!autoRefreshEvents) return;
    const timer = setInterval(() => {
      const onNewestPage = eventsCursor === null && eventsCursorDirection === 'next';
      if (onNewestPage) {
        refreshEventsToNewest().catch(() => {
          // Keep background refresh failures non-blocking for operators.
        });
      } else {
        observabilityService
          .getEvents(buildEventParams(null, 'next'))
          .then((resp) => {
            const topId = resp.items?.[0]?.id ?? null;
            if (topId != null && latestKnownEventId != null && topId > latestKnownEventId) {
              setHasNewEventsAvailable(true);
            } else if (topId != null && latestKnownEventId == null) {
              setLatestKnownEventId(topId);
            }
          })
          .catch(() => {
            // Ignore background check failures.
          });
      }
    }, 10000);
    return () => clearInterval(timer);
  }, [
    autoRefreshEvents,
    eventsCursor,
    eventsCursorDirection,
    refreshEventsToNewest,
    buildEventParams,
    latestKnownEventId,
  ]);

  const openIncident = async (incidentId: number) => {
    try {
      const resp = await observabilityService.getIncident(incidentId);
      setSelectedIncident(resp.incident);
      setIncidentComments(resp.comments || []);
      setRelatedEvents(resp.related_events || []);
      setRelatedFilters(resp.related_filters || null);
      setStatusValue(resp.incident.status || '');
      setAssigneeValue(resp.incident.assignee_user_id != null ? String(resp.incident.assignee_user_id) : '');
      setCommentText('');
      setIncidentDialogOpen(true);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки деталей инцидента');
    }
  };

  const saveIncidentActions = async () => {
    if (!selectedIncident) return;
    try {
      if (statusValue && statusValue !== selectedIncident.status) {
        await observabilityService.updateIncidentStatus(selectedIncident.id, statusValue);
      }
      const parsedAssignee = assigneeValue.trim() ? Number(assigneeValue) : null;
      if (
        (parsedAssignee ?? null) !== (selectedIncident.assignee_user_id ?? null)
      ) {
        await observabilityService.assignIncident(selectedIncident.id, parsedAssignee);
      }
      if (commentText.trim()) {
        await observabilityService.addIncidentComment(selectedIncident.id, commentText.trim());
      }
      await openIncident(selectedIncident.id);
      await loadData();
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Не удалось сохранить изменения инцидента');
    }
  };

  const handleIncidentSort = (field: typeof sortField) => {
    setIncidentsCursor(null);
    setIncidentsCursorHistory([]);
    setIncidentsCursorDirection('next');
    if (sortField === field) {
      setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortDirection('desc');
    }
  };

  const resetIncidentPagination = () => {
    setIncidentsCursor(null);
    setIncidentsCursorHistory([]);
    setIncidentsCursorDirection('next');
  };

  const applyRelatedFilters = () => {
    if (!relatedFilters) return;
    setFilters((prev) => ({
      ...prev,
      vpn_session_id: relatedFilters.vpn_session_id || '',
      server_id: relatedFilters.server_id != null ? String(relatedFilters.server_id) : prev.server_id,
    }));
    setEventsCursor(null);
    setEventsCursorHistory([]);
    setEventsCursorDirection('next');
    setIncidentDialogOpen(false);
  };

  const createTestIncident = async () => {
    try {
      await observabilityService.generateTestIncident({
        incident_type: testForm.incident_type,
        severity: testForm.severity,
        user_id: testForm.user_id ? Number(testForm.user_id) : undefined,
        server_id: testForm.server_id ? Number(testForm.server_id) : undefined,
        vpn_session_id: testForm.vpn_session_id || undefined,
        request_id: testForm.request_id || undefined,
        message: testForm.message || undefined,
      });
      setTestDialogOpen(false);
      await loadData();
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Не удалось создать тестовый incident/event');
    }
  };

  const formatDate = (value?: string | null) => (value ? new Date(value).toLocaleString('ru-RU') : '-');

  const protocolHealthRows = React.useMemo(() => {
    if (!connectivitySummary) return [];
    const protocols = new Set<string>([
      ...Object.keys(connectivitySummary.duration_by_protocol || {}),
      ...Object.keys(connectivitySummary.success_rate || {}),
      ...Object.keys(connectivitySummary.degraded_rate || {}),
      ...Object.keys(connectivitySummary.stage_errors || {}),
    ]);

    return Array.from(protocols).map((protocol) => {
      const duration = connectivitySummary.duration_by_protocol?.[protocol];
      const success = connectivitySummary.success_rate?.[protocol];
      const degraded = connectivitySummary.degraded_rate?.[protocol];
      const stageErrorCount = Object.values(connectivitySummary.stage_errors?.[protocol] || {}).reduce(
        (acc, val) => acc + (val || 0),
        0
      );

      const samples = duration?.samples ?? success?.starts_count ?? degraded?.starts_count ?? 0;
      const p95 = duration?.p95_ms ?? 0;
      const successPct = success?.success_rate_pct ?? 0;
      const degradedPct = degraded?.degraded_rate_pct ?? 0;

      let status: 'healthy' | 'warning' | 'critical' | 'insufficient' = 'healthy';
      if (samples < CONNECTIVITY_THRESHOLDS.minSamples) {
        status = 'insufficient';
      } else if (
        p95 > CONNECTIVITY_THRESHOLDS.p95CriticalMs
        || successPct < CONNECTIVITY_THRESHOLDS.successCriticalPct
        || degradedPct > CONNECTIVITY_THRESHOLDS.degradedCriticalPct
      ) {
        status = 'critical';
      } else if (
        p95 > CONNECTIVITY_THRESHOLDS.p95HealthyMs
        || successPct < CONNECTIVITY_THRESHOLDS.successHealthyPct
        || degradedPct > CONNECTIVITY_THRESHOLDS.degradedHealthyPct
      ) {
        status = 'warning';
      }

      return {
        protocol,
        samples,
        p95,
        successPct,
        degradedPct,
        stageErrorCount,
        status,
      };
    }).sort((a, b) => a.protocol.localeCompare(b.protocol));
  }, [connectivitySummary]);

  return (
    <Box>
      <PageHeader
        title="Observability"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={() => setTestDialogOpen(true)} disabled={loading}>
              Создать тестовый incident/event
            </Button>
            <Button variant="outlined" onClick={loadData} disabled={loading}>
              Обновить
            </Button>
            <Button
              variant="outlined"
              onClick={() => {
                setEventsCursor(null);
                setEventsCursorDirection('next');
                setEventsCursorHistory([]);
                setHasNewEventsAvailable(false);
              }}
              disabled={loading}
            >
              К последним событиям
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
          <Grid item xs={12} sm={2}>
            <TextField
              label="User ID"
              value={filters.user_id}
              onChange={(e) => {
                setFilters((f) => ({ ...f, user_id: e.target.value }));
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={2}>
            <TextField
              label="Server ID"
              value={filters.server_id}
              onChange={(e) => {
                setFilters((f) => ({ ...f, server_id: e.target.value }));
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={3}>
            <TextField
              label="VPN Session ID"
              value={filters.vpn_session_id}
              onChange={(e) => {
                setFilters((f) => ({ ...f, vpn_session_id: e.target.value }));
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={3}>
            <TextField
              label="Event Name"
              value={filters.event_name}
              onChange={(e) => {
                setFilters((f) => ({ ...f, event_name: e.target.value }));
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={2}>
            <TextField
              label="Severity"
              value={filters.severity}
              onChange={(e) => {
                setFilters((f) => ({ ...f, severity: e.target.value }));
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={12}>
            <FormControlLabel
              control={
                <Switch
                  checked={autoRefreshEvents}
                  onChange={(e) => setAutoRefreshEvents(e.target.checked)}
                />
              }
              label="Автообновление событий (каждые 10с, без сброса позиции в истории)"
            />
          </Grid>
          <Grid item xs={12} sm={4}>
            <TextField
              select
              label="Детализация событий"
              value={eventsDetailLevel}
              onChange={(e) => {
                const lvl = (e.target.value || 'basic') as 'basic' | 'enriched';
                setEventsDetailLevel(lvl);
                setEventsCursor(null);
                setEventsCursorHistory([]);
                setEventsCursorDirection('next');
              }}
              size="small"
              fullWidth
            >
              <MenuItem value="basic">Basic (быстро)</MenuItem>
              <MenuItem value="enriched">Enriched (контекст + near-event logs)</MenuItem>
            </TextField>
          </Grid>
        </Grid>
      </FilterCard>

      {loading ? (
        <Box display="flex" justifyContent="center" minHeight="180px" alignItems="center">
          <CircularProgress />
        </Box>
      ) : (
        <>
          <Box sx={{ mb: 2 }}>
            <Typography variant="body2" color="textSecondary">
              Открыто инцидентов: {metrics?.open_total ?? '-'}
            </Typography>
            <Box sx={{ mt: 1, display: 'flex', gap: 1, flexWrap: 'wrap' }}>
              {metrics ? Object.entries(metrics.by_severity || {}).map(([sev, cnt]) => (
                <Chip key={sev} label={`${sev}: ${cnt}`} size="small" variant="outlined" />
              )) : null}
            </Box>
          </Box>

          <Paper sx={{ p: 2, mb: 2 }}>
            <Typography variant="h6" sx={{ mb: 1 }}>
              Мониторинг подключения (последние 24ч)
            </Typography>
            <Typography variant="body2" color="textSecondary" sx={{ mb: 1 }}>
              Пороги: p95 healthy lte 15s / critical gt 20s, success healthy gte 92%, degraded healthy lte 8%.
            </Typography>
            <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap', mb: 1 }}>
              {protocolHealthRows.map((row) => (
                <Chip
                  key={row.protocol}
                  size="small"
                  color={
                    row.status === 'critical'
                      ? 'error'
                      : row.status === 'warning'
                        ? 'warning'
                        : row.status === 'healthy'
                          ? 'success'
                          : 'default'
                  }
                  label={`${row.protocol}: ${row.status} (p95=${row.p95}ms, success=${row.successPct}%, degraded=${row.degradedPct}%, errs=${row.stageErrorCount})`}
                />
              ))}
            </Box>
            <Typography variant="body2" color="textSecondary" sx={{ mb: 1 }}>
              dataplane_not_ready_after_apply: {connectivitySummary?.signals?.dataplane_not_ready_after_apply ?? '-'}
            </Typography>
            <Grid container spacing={2}>
              <Grid item xs={12} md={6}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Latency p50/p95</Typography>
                {connectivitySummary
                  ? Object.entries(connectivitySummary.duration_by_protocol || {}).map(([protocol, v]) => (
                      <Typography key={protocol} variant="body2">
                        {protocol}: p50={v.p50_ms}ms, p95={v.p95_ms}ms, samples={v.samples}
                      </Typography>
                    ))
                  : <Typography variant="body2" color="textSecondary">Нет данных</Typography>}
              </Grid>
              <Grid item xs={12} md={6}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Degraded rate</Typography>
                {connectivitySummary
                  ? Object.entries(connectivitySummary.degraded_rate || {}).map(([protocol, v]) => (
                      <Typography key={protocol} variant="body2">
                        {protocol}: {v.degraded_rate_pct}% ({v.degraded_count}/{v.starts_count})
                      </Typography>
                    ))
                  : <Typography variant="body2" color="textSecondary">Нет данных</Typography>}
              </Grid>
              <Grid item xs={12} md={6}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Success rate</Typography>
                {connectivitySummary
                  ? Object.entries(connectivitySummary.success_rate || {}).map(([protocol, v]) => (
                      <Typography key={protocol} variant="body2">
                        {protocol}: {v.success_rate_pct}% ({v.success_count}/{v.starts_count})
                      </Typography>
                    ))
                  : <Typography variant="body2" color="textSecondary">Нет данных</Typography>}
              </Grid>
              <Grid item xs={12} md={6}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Ошибки по стадиям</Typography>
                {connectivitySummary ? (
                  <TableContainer component={Paper} variant="outlined">
                    <Table size="small">
                      <TableHead>
                        <TableRow>
                          <TableCell>Протокол</TableCell>
                          <TableCell>Stage</TableCell>
                          <TableCell align="right">Ошибки</TableCell>
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {Object.entries(connectivitySummary.stage_errors || {}).flatMap(([protocol, stages]) =>
                          Object.entries(stages || {}).map(([stage, count], idx) => (
                            <TableRow key={`${protocol}-${stage}`}>
                              <TableCell>{idx === 0 ? protocol : ''}</TableCell>
                              <TableCell>{stage}</TableCell>
                              <TableCell align="right">{count}</TableCell>
                            </TableRow>
                          ))
                        )}
                      </TableBody>
                    </Table>
                  </TableContainer>
                ) : (
                  <Typography variant="body2" color="textSecondary">Нет данных</Typography>
                )}
              </Grid>
              <Grid item xs={12}>
                <Typography variant="subtitle2" sx={{ mb: 0.5 }}>Сеть: Wi-Fi / Mobile / Other</Typography>
                {connectivitySummary ? (
                  <TableContainer component={Paper} variant="outlined">
                    <Table size="small">
                      <TableHead>
                        <TableRow>
                          <TableCell>Протокол</TableCell>
                          <TableCell>Сеть</TableCell>
                          <TableCell align="right">Starts</TableCell>
                          <TableCell align="right">Errors</TableCell>
                          <TableCell align="right">Error rate</TableCell>
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {Object.entries(connectivitySummary.network_split || {}).flatMap(([protocol, networks]) =>
                          Object.entries(networks || {}).map(([networkType, vals], idx) => {
                            const starts = vals.starts || 0;
                            const errors = vals.errors || 0;
                            const rate = starts > 0 ? `${((errors / starts) * 100).toFixed(2)}%` : '0.00%';
                            return (
                              <TableRow key={`${protocol}-${networkType}`}>
                                <TableCell>{idx === 0 ? protocol : ''}</TableCell>
                                <TableCell>{networkType}</TableCell>
                                <TableCell align="right">{starts}</TableCell>
                                <TableCell align="right">{errors}</TableCell>
                                <TableCell align="right">{rate}</TableCell>
                              </TableRow>
                            );
                          })
                        )}
                      </TableBody>
                    </Table>
                  </TableContainer>
                ) : (
                  <Typography variant="body2" color="textSecondary">Нет данных</Typography>
                )}
              </Grid>
            </Grid>
          </Paper>

          <Typography variant="h6" sx={{ mb: 1 }}>
            Инциденты ({incidents.length})
          </Typography>
          <FilterCard>
            <Grid container spacing={2}>
              <Grid item xs={12} sm={2}>
                <TextField label="Status" value={incidentFilters.status} onChange={(e) => { setIncidentFilters((f) => ({ ...f, status: e.target.value })); resetIncidentPagination(); }} size="small" fullWidth />
              </Grid>
              <Grid item xs={12} sm={2}>
                <TextField label="Severity" value={incidentFilters.severity} onChange={(e) => { setIncidentFilters((f) => ({ ...f, severity: e.target.value })); resetIncidentPagination(); }} size="small" fullWidth />
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField label="Incident Type" value={incidentFilters.incident_type} onChange={(e) => { setIncidentFilters((f) => ({ ...f, incident_type: e.target.value })); resetIncidentPagination(); }} size="small" fullWidth />
              </Grid>
              <Grid item xs={12} sm={2}>
                <TextField label="Server ID" value={incidentFilters.server_id} onChange={(e) => { setIncidentFilters((f) => ({ ...f, server_id: e.target.value })); resetIncidentPagination(); }} size="small" fullWidth />
              </Grid>
              <Grid item xs={12} sm={3}>
                <TextField label="Assignee User ID" value={incidentFilters.assignee_user_id} onChange={(e) => { setIncidentFilters((f) => ({ ...f, assignee_user_id: e.target.value })); resetIncidentPagination(); }} size="small" fullWidth />
              </Grid>
            <Grid item xs={12} sm={2}>
              <TextField
                select
                label="SLA"
                value={incidentFilters.breached_only ? 'breached' : 'all'}
                onChange={(e) => {
                  const v = e.target.value === 'breached';
                  setIncidentFilters((f) => ({ ...f, breached_only: v }));
                  resetIncidentPagination();
                }}
                size="small"
                fullWidth
              >
                <MenuItem value="all">Все</MenuItem>
                <MenuItem value="breached">Только breached</MenuItem>
              </TextField>
            </Grid>
            </Grid>
          </FilterCard>
          <TableContainer component={Paper} sx={{ mb: 2 }}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell onClick={() => handleIncidentSort('id')} sx={{ cursor: 'pointer' }}>ID</TableCell>
                  <TableCell onClick={() => handleIncidentSort('severity')} sx={{ cursor: 'pointer' }}>Severity</TableCell>
                  <TableCell onClick={() => handleIncidentSort('status')} sx={{ cursor: 'pointer' }}>Status</TableCell>
                  <TableCell>Type</TableCell>
                  <TableCell>Title</TableCell>
                  <TableCell>SLA</TableCell>
                  <TableCell onClick={() => handleIncidentSort('first_seen_at')} sx={{ cursor: 'pointer' }}>First Seen</TableCell>
                  <TableCell onClick={() => handleIncidentSort('last_seen_at')} sx={{ cursor: 'pointer' }}>Last Seen</TableCell>
                  <TableCell>Action</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {incidents.length === 0 ? (
                  <TableRow><TableCell colSpan={9} align="center">Инциденты не найдены</TableCell></TableRow>
                ) : incidents.map((incident) => (
                  <TableRow key={incident.id}>
                    <TableCell>{incident.id}</TableCell>
                    <TableCell>{incident.severity}</TableCell>
                    <TableCell>{incident.status}</TableCell>
                    <TableCell>{incident.incident_type}</TableCell>
                    <TableCell>{incident.title}</TableCell>
                    <TableCell>
                      {incident.sla ? (
                        <Chip
                          size="small"
                          color={incident.sla.sla_breached ? 'error' : 'success'}
                          label={`${incident.sla.age_minutes}/${incident.sla.sla_target_minutes}m`}
                        />
                      ) : '-'}
                    </TableCell>
                    <TableCell>{formatDate(incident.first_seen_at)}</TableCell>
                    <TableCell>{formatDate(incident.last_seen_at)}</TableCell>
                    <TableCell>
                      <Button size="small" onClick={() => openIncident(incident.id)}>Открыть</Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
          <Box sx={{ display: 'flex', gap: 1, justifyContent: 'flex-end', mb: 2 }}>
            <Button
              size="small"
              variant="outlined"
              disabled={incidentsCursorHistory.length === 0 || !incidentsPrevCursor}
              onClick={() => {
                setIncidentsCursorHistory((hist) => {
                  if (hist.length === 0) return hist;
                  const nextHist = [...hist];
                  const prevCursor = nextHist.pop() ?? null;
                  setIncidentsCursorDirection('prev');
                  setIncidentsCursor(prevCursor);
                  return nextHist;
                });
              }}
            >
              Предыдущая
            </Button>
            <Button
              size="small"
              variant="outlined"
              disabled={!incidentsNextCursor}
              onClick={() => {
                setIncidentsCursorHistory((hist) => [...hist, incidentsCursor ?? '']);
                setIncidentsCursorDirection('next');
                setIncidentsCursor(incidentsNextCursor);
              }}
            >
              Следующая
            </Button>
          </Box>

          <Typography variant="h6" sx={{ mb: 1 }}>
            События ({events.length})
          </Typography>
          {hasNewEventsAvailable && (
            <Alert
              severity="info"
              sx={{ mb: 1 }}
              action={(
                <Button
                  color="inherit"
                  size="small"
                  onClick={() => {
                    setEventsCursor(null);
                    setEventsCursorDirection('next');
                    setEventsCursorHistory([]);
                    refreshEventsToNewest().catch(() => {
                      // Surface errors through existing load flow only.
                    });
                  }}
                >
                  Показать новые
                </Button>
              )}
            >
              Новые события доступны
            </Alert>
          )}
          <TableContainer component={Paper}>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>Время</TableCell>
                  <TableCell>Событие</TableCell>
                  <TableCell>Severity</TableCell>
                  <TableCell>Пользователь</TableCell>
                  <TableCell>Сервер</TableCell>
                  <TableCell>Session</TableCell>
                  <TableCell>Контекст / Логи</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {events.length === 0 ? (
                  <TableRow>
                    <TableCell colSpan={7} align="center">
                      <Typography variant="body2" color="textSecondary">
                        События не найдены
                      </Typography>
                    </TableCell>
                  </TableRow>
                ) : events.map((event) => (
                  <TableRow key={event.id}>
                    <TableCell>{event.event_time ? new Date(event.event_time).toLocaleString('ru-RU') : '-'}</TableCell>
                    <TableCell>{event.event_name}</TableCell>
                    <TableCell>{event.severity}</TableCell>
                    <TableCell>
                      {event.user_context?.email
                        ? `${event.user_context.email} (#${event.user_id ?? '-'})`
                        : (event.user_id ?? '-')}
                    </TableCell>
                    <TableCell>
                      {event.server_context?.name
                        ? `${event.server_context.name} (#${event.server_id ?? '-'})`
                        : (event.server_id ?? '-')}
                    </TableCell>
                    <TableCell>{event.vpn_session_id || '-'}</TableCell>
                    <TableCell>
                      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
                        <Typography variant="caption">
                          {event.message || event.reason_code || '-'}
                        </Typography>
                        {event.device_context ? (
                          <Typography variant="caption" color="text.secondary">
                            Устройство: {event.device_context.device_id} / {event.device_context.platform || '-'} / {event.device_context.app_version || '-'}
                          </Typography>
                        ) : null}
                        {event.related_logs?.vpn_server_log ? (
                          <Typography variant="caption" color="text.secondary">
                            VPN server log: {event.related_logs.vpn_server_log.connection_type || '-'}
                            {event.related_logs.vpn_server_log.ip_address ? `, ip=${event.related_logs.vpn_server_log.ip_address}` : ''}
                          </Typography>
                        ) : null}
                        {event.related_logs?.client_log ? (
                          <Typography variant="caption" color="text.secondary">
                            Client log: {event.related_logs.client_log.event_type || '-'}
                            {event.related_logs.client_log.error_code ? `, error=${event.related_logs.client_log.error_code}` : ''}
                          </Typography>
                        ) : null}
                      </Box>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
          <Box sx={{ display: 'flex', gap: 1, justifyContent: 'flex-end', mt: 1 }}>
            <Button
              size="small"
              variant="outlined"
              disabled={eventsCursorHistory.length === 0 || !eventsPrevCursor}
              onClick={() => {
                setEventsCursorHistory((hist) => {
                  if (hist.length === 0) return hist;
                  const nextHist = [...hist];
                  const prevCursor = nextHist.pop() ?? null;
                  setEventsCursorDirection('prev');
                  setEventsCursor(prevCursor);
                  return nextHist;
                });
              }}
            >
              Предыдущая
            </Button>
            <Button
              size="small"
              variant="outlined"
              disabled={!eventsNextCursor}
              onClick={() => {
                setEventsCursorHistory((hist) => [...hist, eventsCursor ?? '']);
                setEventsCursorDirection('next');
                setEventsCursor(eventsNextCursor);
              }}
            >
              Следующая
            </Button>
          </Box>

          <Dialog open={incidentDialogOpen} onClose={() => setIncidentDialogOpen(false)} maxWidth="md" fullWidth>
            <DialogTitle>
              {selectedIncident ? `Инцидент #${selectedIncident.id}: ${selectedIncident.title}` : 'Инцидент'}
            </DialogTitle>
            <DialogContent>
              {selectedIncident && (
                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2, pt: 1 }}>
                  <Typography variant="body2" color="textSecondary">
                    Тип: {selectedIncident.incident_type} | Severity: {selectedIncident.severity}
                  </Typography>
                  <TextField
                    select
                    label="Статус"
                    value={statusValue}
                    onChange={(e) => setStatusValue(e.target.value)}
                    size="small"
                  >
                    {['open', 'investigating', 'mitigated', 'resolved', 'ignored'].map((s) => (
                      <MenuItem key={s} value={s}>{s}</MenuItem>
                    ))}
                  </TextField>
                  <TextField
                    label="Assignee User ID"
                    value={assigneeValue}
                    onChange={(e) => setAssigneeValue(e.target.value)}
                    size="small"
                    placeholder="пусто = снять assignee"
                  />
                  <TextField
                    label="Комментарий"
                    value={commentText}
                    onChange={(e) => setCommentText(e.target.value)}
                    multiline
                    minRows={2}
                  />
                  <Typography variant="subtitle2">Комментарии</Typography>
                  <Box sx={{ maxHeight: 220, overflow: 'auto', border: '1px solid #eee', borderRadius: 1, p: 1 }}>
                    {incidentComments.length === 0 ? (
                      <Typography variant="body2" color="textSecondary">Комментариев нет</Typography>
                    ) : incidentComments.map((c) => (
                      <Box key={c.id} sx={{ mb: 1 }}>
                        <Typography variant="caption" color="textSecondary">
                          {c.created_at ? new Date(c.created_at).toLocaleString('ru-RU') : '-'} | author={c.author_user_id ?? '-'}
                        </Typography>
                        <Typography variant="body2">{c.comment}</Typography>
                      </Box>
                    ))}
                  </Box>
                  <Typography variant="subtitle2">Связанные события</Typography>
                  <Box sx={{ display: 'flex', gap: 1, flexWrap: 'wrap' }}>
                    {relatedFilters?.vpn_session_id ? <Chip size="small" label={`vpn_session_id: ${relatedFilters.vpn_session_id}`} /> : null}
                    {relatedFilters?.request_id ? <Chip size="small" label={`request_id: ${relatedFilters.request_id}`} /> : null}
                    {relatedFilters?.server_id != null ? <Chip size="small" label={`server_id: ${relatedFilters.server_id}`} /> : null}
                    <Button size="small" variant="outlined" onClick={applyRelatedFilters} startIcon={<OpenInNewIcon />}>
                      Открыть как фильтр events
                    </Button>
                  </Box>
                  <Box sx={{ maxHeight: 160, overflow: 'auto', border: '1px solid #eee', borderRadius: 1, p: 1 }}>
                    {relatedEvents.length === 0 ? (
                      <Typography variant="body2" color="textSecondary">Связанных событий не найдено</Typography>
                    ) : relatedEvents.map((ev) => (
                      <Typography key={ev.id} variant="body2">
                        {formatDate(ev.event_time)} | {ev.event_name} | {ev.message || ev.reason_code || '-'}
                      </Typography>
                    ))}
                  </Box>
                </Box>
              )}
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setIncidentDialogOpen(false)}>Закрыть</Button>
              <Button variant="contained" onClick={saveIncidentActions}>Сохранить</Button>
            </DialogActions>
          </Dialog>

          <Dialog open={testDialogOpen} onClose={() => setTestDialogOpen(false)} maxWidth="sm" fullWidth>
            <DialogTitle>Создать тестовый incident/event</DialogTitle>
            <DialogContent>
              <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2, pt: 1 }}>
                <TextField
                  select
                  label="Incident Type"
                  value={testForm.incident_type}
                  onChange={(e) => setTestForm((f) => ({ ...f, incident_type: e.target.value }))}
                >
                  {['config_conflict', 'duplicate_session', 'stale_tunnel'].map((t) => (
                    <MenuItem key={t} value={t}>{t}</MenuItem>
                  ))}
                </TextField>
                <TextField
                  select
                  label="Severity"
                  value={testForm.severity}
                  onChange={(e) => setTestForm((f) => ({ ...f, severity: e.target.value }))}
                >
                  {['P1', 'P2', 'P3', 'P4'].map((s) => (
                    <MenuItem key={s} value={s}>{s}</MenuItem>
                  ))}
                </TextField>
                <TextField label="User ID" value={testForm.user_id} onChange={(e) => setTestForm((f) => ({ ...f, user_id: e.target.value }))} />
                <TextField label="Server ID" value={testForm.server_id} onChange={(e) => setTestForm((f) => ({ ...f, server_id: e.target.value }))} />
                <TextField label="VPN Session ID" value={testForm.vpn_session_id} onChange={(e) => setTestForm((f) => ({ ...f, vpn_session_id: e.target.value }))} />
                <TextField label="Request ID" value={testForm.request_id} onChange={(e) => setTestForm((f) => ({ ...f, request_id: e.target.value }))} />
                <TextField label="Message" value={testForm.message} onChange={(e) => setTestForm((f) => ({ ...f, message: e.target.value }))} multiline minRows={2} />
              </Box>
            </DialogContent>
            <DialogActions>
              <Button onClick={() => setTestDialogOpen(false)}>Отмена</Button>
              <Button variant="contained" onClick={createTestIncident}>Создать</Button>
            </DialogActions>
          </Dialog>
        </>
      )}
    </Box>
  );
};

export default ObservabilityPage;
