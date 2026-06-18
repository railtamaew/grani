import React, { useCallback, useEffect, useState } from 'react';
import {
  Box,
  Typography,
  TextField,
  Button,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  Chip,
  CircularProgress,
  Alert,
  Grid,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Pagination,
} from '@mui/material';
import { Refresh, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { subscriptionsService, SubscriptionInfo } from '../services/subscriptionsService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const SubscriptionsPage: React.FC = () => {
  const [subscriptions, setSubscriptions] = useState<SubscriptionInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [limit] = useState(20);
  const [total, setTotal] = useState(0);
  const [filters, setFilters] = useState({
    status: '',
    user_id: '',
    plan_id: '',
    start_date_from: '',
    start_date_to: '',
    end_date_from: '',
    end_date_to: '',
  });
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadSubscriptions = useCallback(async (targetPage: number = page, overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = { page: targetPage, limit };
      if (activeFilters.status) params.status = activeFilters.status;
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.plan_id) params.plan_id = Number(activeFilters.plan_id);
      if (activeFilters.start_date_from) params.start_date_from = activeFilters.start_date_from;
      if (activeFilters.start_date_to) params.start_date_to = activeFilters.start_date_to;
      if (activeFilters.end_date_from) params.end_date_from = activeFilters.end_date_from;
      if (activeFilters.end_date_to) params.end_date_to = activeFilters.end_date_to;
      const data = await subscriptionsService.getSubscriptions(params);
      setSubscriptions(data.subscriptions);
      setTotal(data.total);
      setPage(data.page);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки подписок');
    } finally {
      setLoading(false);
    }
  }, [filters, limit, page]);

  useEffect(() => {
    loadSubscriptions(1);
  }, [loadSubscriptions]);

  const formatDate = (dateString?: string | null) => {
    if (!dateString) return '-';
    return new Date(dateString).toLocaleString('ru-RU');
  };

  const handlePageChange = (_: React.ChangeEvent<unknown>, value: number) => {
    setPage(value);
    loadSubscriptions(value);
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedSubscriptions = [...subscriptions].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'start_date' || sortField === 'end_date') {
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

  const handleExport = () => {
    downloadCsv(
      'subscriptions-export.csv',
      ['ID', 'User', 'Plan', 'Status', 'Start Date', 'End Date', 'Auto Renew', 'Source'],
      subscriptions.map((sub) => [
        sub.id,
        sub.user_email || sub.user_id,
        sub.plan_name || sub.plan_id,
        sub.status || 'unknown',
        sub.start_date || '',
        sub.end_date || '',
        sub.auto_renew ? 'yes' : 'no',
        sub.source || '',
      ])
    );
  };

  return (
    <Box>
      <PageHeader
        title="Подписки"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={subscriptions.length === 0}>
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => loadSubscriptions(1)}
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
            <Grid item xs={12} sm={6} md={3}>
              <FormControl fullWidth size="small">
                <InputLabel>Статус</InputLabel>
                <Select
                  value={filters.status}
                  label="Статус"
                  onChange={(e) => setFilters({ ...filters, status: e.target.value })}
                >
                  <MenuItem value="">Все</MenuItem>
                  <MenuItem value="active">active</MenuItem>
                  <MenuItem value="expired">expired</MenuItem>
                  <MenuItem value="cancelled">cancelled</MenuItem>
                </Select>
              </FormControl>
            </Grid>
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
                label="Plan ID"
                value={filters.plan_id}
                onChange={(e) => setFilters({ ...filters, plan_id: e.target.value })}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Начало от"
                type="date"
                value={filters.start_date_from}
                onChange={(e) => setFilters({ ...filters, start_date_from: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Начало до"
                type="date"
                value={filters.start_date_to}
                onChange={(e) => setFilters({ ...filters, start_date_to: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Окончание от"
                type="date"
                value={filters.end_date_from}
                onChange={(e) => setFilters({ ...filters, end_date_from: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <TextField
                label="Окончание до"
                type="date"
                value={filters.end_date_to}
                onChange={(e) => setFilters({ ...filters, end_date_to: e.target.value })}
                size="small"
                fullWidth
                InputLabelProps={{ shrink: true }}
              />
            </Grid>
            <Grid item xs={12} sm={6} md={3}>
              <Box display="flex" gap={2}>
                <Button variant="contained" onClick={() => loadSubscriptions(1)} disabled={loading}>
                  Применить
                </Button>
                <Button
                  variant="outlined"
                  onClick={() => {
                    const nextFilters = {
                      status: '',
                      user_id: '',
                      plan_id: '',
                      start_date_from: '',
                      start_date_to: '',
                      end_date_from: '',
                      end_date_to: '',
                    };
                    setFilters(nextFilters);
                    loadSubscriptions(1, nextFilters);
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
                <SortableHeader field="user_email">User</SortableHeader>
                <SortableHeader field="plan_name">Plan</SortableHeader>
                <TableCell>Статус</TableCell>
                <SortableHeader field="start_date">Начало</SortableHeader>
                <SortableHeader field="end_date">Конец</SortableHeader>
                <TableCell>Auto‑renew</TableCell>
                <SortableHeader field="source">Источник</SortableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {subscriptions.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} align="center">
                    <Typography variant="body2" color="textSecondary">
                      Подписок не найдено
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                sortedSubscriptions.map((sub) => (
                  <TableRow key={sub.id}>
                    <TableCell>{sub.id}</TableCell>
                    <TableCell>{sub.user_email || sub.user_id}</TableCell>
                    <TableCell>{sub.plan_name || sub.plan_id}</TableCell>
                    <TableCell>
                      <Chip
                        label={sub.status || 'unknown'}
                        color={sub.status === 'active' ? 'success' : 'default'}
                        size="small"
                      />
                    </TableCell>
                    <TableCell>{formatDate(sub.start_date)}</TableCell>
                    <TableCell>{formatDate(sub.end_date)}</TableCell>
                    <TableCell>{sub.auto_renew ? 'Да' : 'Нет'}</TableCell>
                    <TableCell>{sub.source || '-'}</TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {total > limit && (
        <Box display="flex" justifyContent="center" mt={3}>
          <Pagination
            count={Math.ceil(total / limit)}
            page={page}
            onChange={handlePageChange}
            color="primary"
          />
        </Box>
      )}
    </Box>
  );
};

export default SubscriptionsPage;
