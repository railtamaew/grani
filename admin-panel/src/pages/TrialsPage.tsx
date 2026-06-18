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
  Alert,
  CircularProgress,
  Grid,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Pagination,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
} from '@mui/material';
import { Refresh, Search, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { trialsService, TrialInfo } from '../services/trialsService';
import RoleGuard from '../components/RoleGuard';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const TrialsPage: React.FC = () => {
  const [trials, setTrials] = useState<TrialInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [limit] = useState(20);
  const [total, setTotal] = useState(0);
  const [filters, setFilters] = useState({
    user_id: '',
    status: '',
    search: '',
  });
  const [dialogOpen, setDialogOpen] = useState(false);
  const [selectedUserId, setSelectedUserId] = useState<number | null>(null);
  const [trialMinutes, setTrialMinutes] = useState(24 * 60);
  const [sortField, setSortField] = useState<string>('user_id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadTrials = useCallback(async (targetPage: number = 1, overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = { page: targetPage, limit };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.search) params.search = activeFilters.search;
      if (activeFilters.status) params.status = activeFilters.status;

      const data = await trialsService.getTrials(params);
      setTrials(data.trials);
      setTotal(data.total);
      setPage(data.page);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки триалов');
    } finally {
      setLoading(false);
    }
  }, [filters, limit]);

  useEffect(() => {
    loadTrials(1);
  }, [loadTrials]);

  const handlePageChange = (_: React.ChangeEvent<unknown>, value: number) => {
    setPage(value);
    loadTrials(value);
  };

  const handleSearch = () => {
    loadTrials(1);
  };

  const handleReset = () => {
    const nextFilters = { user_id: '', status: '', search: '' };
    setFilters(nextFilters);
    loadTrials(1, nextFilters);
  };

  const formatDateTime = (value?: string | null) => {
    if (!value) return '-';
    return new Date(value).toLocaleString('ru-RU');
  };

  const formatTimeLeft = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}м ${secs}с`;
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedTrials = [...trials].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'trial_started_at' || sortField === 'trial_ends_at') {
      aVal = aVal ? new Date(aVal).getTime() : 0;
      bVal = bVal ? new Date(bVal).getTime() : 0;
    } else if (sortField === 'email' && typeof aVal === 'string') {
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
      'trials-export.csv',
      ['User ID', 'Email', 'Status', 'Seconds Left', 'Started At', 'Ends At'],
      trials.map((trial) => [
        trial.user_id,
        trial.email,
        trial.status,
        trial.trial_seconds_left,
        trial.trial_started_at || '',
        trial.trial_ends_at || '',
      ])
    );
  };

  const openTrialDialog = (userId: number) => {
    setSelectedUserId(userId);
    setTrialMinutes(24 * 60);
    setDialogOpen(true);
  };

  const handleSetTrial = async () => {
    if (!selectedUserId) return;
    try {
      await trialsService.setTrial(selectedUserId, trialMinutes);
      setDialogOpen(false);
      loadTrials(page);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка установки trial');
    }
  };

  if (loading && trials.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Триалы"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={trials.length === 0}>
              Экспорт CSV
            </Button>
            <Button variant="outlined" startIcon={<Refresh />} onClick={() => loadTrials(1)} disabled={loading}>
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
        <Grid container spacing={2} alignItems="center">
          <Grid item xs={12} md={4}>
            <TextField
              label="Поиск по email"
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              onKeyPress={(e) => e.key === 'Enter' && handleSearch()}
              size="small"
              fullWidth
            />
          </Grid>
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
            <FormControl fullWidth size="small">
              <InputLabel>Статус</InputLabel>
              <Select
                value={filters.status}
                label="Статус"
                onChange={(e) => setFilters({ ...filters, status: e.target.value })}
              >
                <MenuItem value="">Все</MenuItem>
                <MenuItem value="active">Активные</MenuItem>
                <MenuItem value="expired">Истекшие</MenuItem>
                <MenuItem value="not_started">Не выдавался</MenuItem>
              </Select>
            </FormControl>
          </Grid>
          <Grid item xs={12} md={4}>
            <Box display="flex" gap={1}>
              <Button variant="contained" startIcon={<Search />} onClick={handleSearch}>
                Найти
              </Button>
              <Button variant="outlined" onClick={handleReset}>
                Сбросить
              </Button>
            </Box>
          </Grid>
        </Grid>
      </FilterCard>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <SortableHeader field="user_id">User ID</SortableHeader>
              <SortableHeader field="email">Email</SortableHeader>
              <TableCell>Статус</TableCell>
              <TableCell>Осталось</TableCell>
              <SortableHeader field="trial_started_at">Начало</SortableHeader>
              <SortableHeader field="trial_ends_at">Окончание</SortableHeader>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {trials.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} align="center">
                  <Typography variant="body2" color="textSecondary">
                    Триалы не найдены
                  </Typography>
                </TableCell>
              </TableRow>
            ) : (
              sortedTrials.map((trial) => (
                <TableRow key={trial.user_id}>
                  <TableCell>{trial.user_id}</TableCell>
                  <TableCell>{trial.email}</TableCell>
                  <TableCell>
                    <Chip
                      label={trial.status === 'active' ? 'Активен' : trial.status === 'expired' ? 'Истек' : 'Не выдавался'}
                      color={trial.status === 'active' ? 'success' : trial.status === 'expired' ? 'default' : 'info'}
                      size="small"
                    />
                  </TableCell>
                  <TableCell>
                    {trial.status === 'active' ? formatTimeLeft(trial.trial_seconds_left) : '-'}
                  </TableCell>
                  <TableCell>{formatDateTime(trial.trial_started_at)}</TableCell>
                  <TableCell>{formatDateTime(trial.trial_ends_at)}</TableCell>
                  <TableCell>
                    <RoleGuard roles={['admin', 'owner']} fallback={<span>-</span>}>
                      <Button size="small" variant="outlined" onClick={() => openTrialDialog(trial.user_id)}>
                        {trial.status === 'not_started' ? 'Выдать trial' : 'Установить trial'}
                      </Button>
                    </RoleGuard>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </TableContainer>

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

      <Dialog open={dialogOpen} onClose={() => setDialogOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>Установить trial</DialogTitle>
        <DialogContent>
          <TextField
            label="Длительность (минуты)"
            type="number"
            value={trialMinutes}
            onChange={(e) => setTrialMinutes(Number(e.target.value))}
            fullWidth
            margin="normal"
            inputProps={{ min: 1 }}
          />
          <Typography variant="caption" color="text.secondary">
            По умолчанию: 1440 минут (24 часа)
          </Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDialogOpen(false)}>Отмена</Button>
          <Button onClick={handleSetTrial} variant="contained">Сохранить</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default TrialsPage;
