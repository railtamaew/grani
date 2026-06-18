import React, { useCallback, useEffect, useState } from 'react';
import {
  Box,
  Typography,
  Button,
  TextField,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  Chip,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  CircularProgress,
  Alert,
  Grid,
} from '@mui/material';
import { Refresh, Visibility, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { incidentsService, Incident, IncidentDetail } from '../services/incidentsService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const statusOptions = ['new', 'investigating', 'resolved', 'ignored'];

const IncidentsPage: React.FC = () => {
  const [incidents, setIncidents] = useState<Incident[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState({
    user_id: '',
    server_id: '',
    protocol_code: '',
    error_code: '',
    app_version: '',
    status: '',
  });
  const [detailOpen, setDetailOpen] = useState(false);
  const [selectedIncident, setSelectedIncident] = useState<IncidentDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [newStatus, setNewStatus] = useState<string>('new');
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadIncidents = useCallback(async (overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = {
        limit: 100,
      };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.server_id) params.server_id = Number(activeFilters.server_id);
      if (activeFilters.protocol_code) params.protocol_code = activeFilters.protocol_code;
      if (activeFilters.error_code) params.error_code = activeFilters.error_code;
      if (activeFilters.app_version) params.app_version = activeFilters.app_version;
      if (activeFilters.status) params.status = activeFilters.status;
      const data = await incidentsService.getIncidents(params);
      setIncidents(data);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки инцидентов');
    } finally {
      setLoading(false);
    }
  }, [filters]);

  const openDetail = async (incidentId: number) => {
    setDetailOpen(true);
    setDetailLoading(true);
    try {
      const detail = await incidentsService.getIncidentDetail(incidentId);
      setSelectedIncident(detail);
      setNewStatus(detail.status || 'new');
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки инцидента');
    } finally {
      setDetailLoading(false);
    }
  };

  const updateStatus = async () => {
    if (!selectedIncident) return;
    try {
      await incidentsService.updateIncident(selectedIncident.id, { status: newStatus });
      await loadIncidents();
      setDetailOpen(false);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка обновления статуса');
    }
  };

  useEffect(() => {
    loadIncidents();
  }, [loadIncidents]);

  const formatDateTime = (value?: string | null) => {
    if (!value) return '-';
    return new Date(value).toLocaleString('ru-RU');
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedIncidents = [...incidents].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'timestamp') {
      aVal = aVal ? new Date(aVal).getTime() : 0;
      bVal = bVal ? new Date(bVal).getTime() : 0;
    } else if (sortField === 'user_email' || sortField === 'user_id') {
      aVal = String((a as any).user_email || (a as any).user_id || '').toLowerCase();
      bVal = String((b as any).user_email || (b as any).user_id || '').toLowerCase();
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

  return (
    <Box>
      <PageHeader
        title="Инциденты"
        actions={(
          <Box display="flex" gap={1}>
            <Button
              variant="outlined"
              onClick={() => {
                downloadCsv(
                  'incidents-export.csv',
                  ['ID', 'Timestamp', 'User', 'Server ID', 'Protocol', 'Error Code', 'App Version', 'Status'],
                  incidents.map((incident) => [
                    incident.id,
                    incident.timestamp || '',
                    incident.user_email || incident.user_id || '',
                    incident.server_id || '',
                    incident.protocol_code || '',
                    incident.error_code || '',
                    incident.app_version || '',
                    incident.status || '',
                  ])
                );
              }}
              disabled={incidents.length === 0}
            >
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => loadIncidents()}
              disabled={loading}
            >
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
              label="Server ID"
              value={filters.server_id}
              onChange={(e) => setFilters({ ...filters, server_id: e.target.value })}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <TextField
              label="Protocol"
              value={filters.protocol_code}
              onChange={(e) => setFilters({ ...filters, protocol_code: e.target.value })}
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
              label="App version"
              value={filters.app_version}
              onChange={(e) => setFilters({ ...filters, app_version: e.target.value })}
              size="small"
              fullWidth
            />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <FormControl fullWidth size="small">
              <InputLabel>Статус</InputLabel>
              <Select
                value={filters.status}
                label="Статус"
                onChange={(e) => setFilters({ ...filters, status: e.target.value })}
              >
                <MenuItem value="">Все</MenuItem>
                {statusOptions.map((s) => (
                  <MenuItem key={s} value={s}>{s}</MenuItem>
                ))}
              </Select>
            </FormControl>
          </Grid>
          <Grid item xs={12}>
            <Box display="flex" gap={2}>
              <Button variant="contained" onClick={() => loadIncidents()}>
                Применить
              </Button>
              <Button
                variant="outlined"
                onClick={() => {
                  const nextFilters = {
                    user_id: '',
                    server_id: '',
                    protocol_code: '',
                    error_code: '',
                    app_version: '',
                    status: '',
                  };
                  setFilters(nextFilters);
                  loadIncidents(nextFilters);
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
                <SortableHeader field="timestamp">Время</SortableHeader>
                <SortableHeader field="user_email">User</SortableHeader>
                <SortableHeader field="protocol_code">Protocol</SortableHeader>
                <SortableHeader field="error_code">Error</SortableHeader>
                <SortableHeader field="status">Статус</SortableHeader>
                <TableCell>Действия</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {incidents.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Инциденты не найдены
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sortedIncidents.map((incident) => (
                  <TableRow key={incident.id}>
                    <TableCell>{incident.id}</TableCell>
                    <TableCell>{formatDateTime(incident.timestamp)}</TableCell>
                    <TableCell>{incident.user_email || incident.user_id || '-'}</TableCell>
                    <TableCell>{incident.protocol_code || '-'}</TableCell>
                    <TableCell>
                      {incident.error_code ? (
                        <Chip label={incident.error_code} color="error" size="small" />
                      ) : (
                        '-'
                      )}
                    </TableCell>
                    <TableCell>
                      <Chip label={incident.status || 'new'} size="small" variant="outlined" />
                    </TableCell>
                    <TableCell>
                      <Button
                        size="small"
                        startIcon={<Visibility />}
                        onClick={() => openDetail(incident.id)}
                      >
                        Детали
                      </Button>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={detailOpen} onClose={() => setDetailOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Детали инцидента</DialogTitle>
        <DialogContent>
          {detailLoading ? (
            <Box display="flex" justifyContent="center" alignItems="center" minHeight="200px">
              <CircularProgress />
            </Box>
          ) : selectedIncident ? (
            <Box>
              <Typography variant="body2" color="textSecondary">ID</Typography>
              <Typography variant="body1" gutterBottom>{selectedIncident.id}</Typography>
              <Typography variant="body2" color="textSecondary">Пользователь</Typography>
              <Typography variant="body1" gutterBottom>
                {selectedIncident.user_email || selectedIncident.user_id || '-'}
              </Typography>
              <Typography variant="body2" color="textSecondary">Ошибка</Typography>
              <Typography variant="body1" gutterBottom>
                {selectedIncident.error_code || '-'} {selectedIncident.error_message ? `— ${selectedIncident.error_message}` : ''}
              </Typography>
              {selectedIncident.recommended_action && (
                <Alert severity="info" sx={{ mb: 2 }}>
                  {selectedIncident.recommended_action}
                </Alert>
              )}
              <FormControl fullWidth size="small" sx={{ mb: 2 }}>
                <InputLabel>Статус</InputLabel>
                <Select
                  value={newStatus}
                  label="Статус"
                  onChange={(e) => setNewStatus(e.target.value)}
                >
                  {statusOptions.map((s) => (
                    <MenuItem key={s} value={s}>{s}</MenuItem>
                  ))}
                </Select>
              </FormControl>
              <Typography variant="subtitle2" sx={{ mt: 2 }}>
                Таймлайн
              </Typography>
              {selectedIncident.timeline?.length ? (
                <TableContainer component={Paper} sx={{ mt: 1 }}>
                  <Table size="small">
                    <TableHead>
                      <TableRow>
                        <TableCell>Событие</TableCell>
                        <TableCell>Время</TableCell>
                        <TableCell>Ошибка</TableCell>
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {selectedIncident.timeline.map((t) => (
                        <TableRow key={t.id}>
                          <TableCell>{t.event_type}</TableCell>
                          <TableCell>{formatDateTime(t.timestamp)}</TableCell>
                          <TableCell>{t.error_code || '-'}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TableContainer>
              ) : (
                <Typography variant="body2" color="textSecondary">Нет данных</Typography>
              )}
            </Box>
          ) : (
            <Typography>Нет данных</Typography>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDetailOpen(false)}>Закрыть</Button>
          <Button onClick={updateStatus} variant="contained" disabled={detailLoading}>
            Сохранить статус
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default IncidentsPage;



