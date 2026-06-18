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
  CircularProgress,
  Alert,
  Grid,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
} from '@mui/material';
import { Refresh, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { auditLogService, AuditLogEntry } from '../services/auditLogService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const AuditLogPage: React.FC = () => {
  const [logs, setLogs] = useState<AuditLogEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filters, setFilters] = useState({
    admin_user_id: '',
    entity_type: '',
    entity_id: '',
    start_date: '',
    end_date: '',
  });
  const [selectedLog, setSelectedLog] = useState<AuditLogEntry | null>(null);
  const [detailOpen, setDetailOpen] = useState(false);
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadLogs = useCallback(async (overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = {
        limit: 200,
      };
      if (activeFilters.admin_user_id) params.admin_user_id = Number(activeFilters.admin_user_id);
      if (activeFilters.entity_type) params.entity_type = activeFilters.entity_type;
      if (activeFilters.entity_id) params.entity_id = Number(activeFilters.entity_id);
      if (activeFilters.start_date) params.start_date = activeFilters.start_date;
      if (activeFilters.end_date) params.end_date = activeFilters.end_date;
      const data = await auditLogService.getAuditLogs(params);
      setLogs(data);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки audit log');
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

  const openDetail = (log: AuditLogEntry) => {
    setSelectedLog(log);
    setDetailOpen(true);
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
    } else if (sortField === 'admin_email' || sortField === 'admin_user_id') {
      aVal = String((a as any).admin_email || (a as any).admin_user_id || '').toLowerCase();
      bVal = String((b as any).admin_email || (b as any).admin_user_id || '').toLowerCase();
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
      'audit-log-export.csv',
      ['ID', 'Created At', 'Admin', 'Action', 'Entity', 'Entity ID', 'IP', 'Old Value', 'New Value'],
      logs.map((log) => [
        log.id,
        log.created_at || '',
        log.admin_email || log.admin_user_id || '',
        log.action || '',
        log.entity_type || '',
        log.entity_id ?? '',
        log.ip_address || '',
        JSON.stringify(log.old_value || {}),
        JSON.stringify(log.new_value || {}),
      ])
    );
  };

  return (
    <Box>
      <PageHeader
        title="Audit Log"
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
                label="Admin ID"
                value={filters.admin_user_id}
                onChange={(e) => setFilters({ ...filters, admin_user_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Entity type"
                value={filters.entity_type}
                onChange={(e) => setFilters({ ...filters, entity_type: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <TextField
                label="Entity ID"
                value={filters.entity_id}
                onChange={(e) => setFilters({ ...filters, entity_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Начало"
                type="datetime-local"
                value={filters.start_date}
                onChange={(e) => setFilters({ ...filters, start_date: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Конец"
                type="datetime-local"
                value={filters.end_date}
                onChange={(e) => setFilters({ ...filters, end_date: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
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
                      admin_user_id: '',
                      entity_type: '',
                      entity_id: '',
                      start_date: '',
                      end_date: '',
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
                <SortableHeader field="admin_email">Админ</SortableHeader>
                <SortableHeader field="action">Действие</SortableHeader>
                <SortableHeader field="entity_type">Сущность</SortableHeader>
                <SortableHeader field="ip_address">IP</SortableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {logs.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={6} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Записей не найдено
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sortedLogs.map((log) => (
                  <TableRow key={log.id} hover onClick={() => openDetail(log)} sx={{ cursor: 'pointer' }}>
                    <TableCell>{log.id}</TableCell>
                    <TableCell>{formatDateTime(log.created_at)}</TableCell>
                    <TableCell>{log.admin_email || log.admin_user_id}</TableCell>
                    <TableCell>{log.action}</TableCell>
                    <TableCell>{log.entity_type} #{log.entity_id ?? '-'}</TableCell>
                    <TableCell>{log.ip_address || '-'}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      <Dialog open={detailOpen} onClose={() => setDetailOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Детали audit‑события</DialogTitle>
        <DialogContent>
          {selectedLog ? (
            <Box>
              <Typography variant="body2" color="textSecondary">Действие</Typography>
              <Typography variant="body1" gutterBottom>
                {selectedLog.action} {selectedLog.entity_type} #{selectedLog.entity_id ?? '-'}
              </Typography>
              <Typography variant="body2" color="textSecondary">Администратор</Typography>
              <Typography variant="body1" gutterBottom>
                {selectedLog.admin_email || selectedLog.admin_user_id}
              </Typography>
              <Typography variant="body2" color="textSecondary">IP / User‑Agent</Typography>
              <Typography variant="body1" gutterBottom>
                {selectedLog.ip_address || '-'}
              </Typography>
              <Typography variant="subtitle2" sx={{ mt: 2 }}>Старое значение</Typography>
              <Paper variant="outlined" sx={{ p: 2, bgcolor: 'background.default' }}>
                <pre style={{ margin: 0, whiteSpace: 'pre-wrap' }}>
                  {JSON.stringify(selectedLog.old_value || {}, null, 2)}
                </pre>
              </Paper>
              <Typography variant="subtitle2" sx={{ mt: 2 }}>Новое значение</Typography>
              <Paper variant="outlined" sx={{ p: 2, bgcolor: 'background.default' }}>
                <pre style={{ margin: 0, whiteSpace: 'pre-wrap' }}>
                  {JSON.stringify(selectedLog.new_value || {}, null, 2)}
                </pre>
              </Paper>
            </Box>
          ) : (
            <Typography>Нет данных</Typography>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDetailOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default AuditLogPage;



