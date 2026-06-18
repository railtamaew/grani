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
  IconButton,
  Checkbox,
} from '@mui/material';
import { Refresh, Delete, Search, Block, ArrowUpward, ArrowDownward } from '@mui/icons-material';
import { devicesService, DeviceInfo } from '../services/devicesService';
import RoleGuard from '../components/RoleGuard';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const DevicesPage: React.FC = () => {
  const [devices, setDevices] = useState<DeviceInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [limit] = useState(20);
  const [total, setTotal] = useState(0);
  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  const [filters, setFilters] = useState({
    user_id: '',
    platform: '',
    status: '',
    search: '',
  });
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  const loadDevices = useCallback(async (targetPage: number = page, overrideFilters?: typeof filters) => {
    const activeFilters = overrideFilters || filters;
    setLoading(true);
    setError(null);
    try {
      const params: any = { page: targetPage, limit };
      if (activeFilters.user_id) params.user_id = Number(activeFilters.user_id);
      if (activeFilters.platform) params.platform = activeFilters.platform;
      if (activeFilters.search) params.search = activeFilters.search;
      if (activeFilters.status === 'active') params.is_active = true;
      if (activeFilters.status === 'inactive') params.is_active = false;

      const data = await devicesService.getDevices(params);
      setDevices(data.devices);
      setTotal(data.total);
      setPage(data.page);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки устройств');
    } finally {
      setLoading(false);
    }
  }, [filters, limit, page]);

  useEffect(() => {
    loadDevices(1);
  }, [loadDevices]);

  useEffect(() => {
    setSelectedIds([]);
  }, [devices]);

  const handlePageChange = (_: React.ChangeEvent<unknown>, value: number) => {
    setPage(value);
    loadDevices(value);
  };

  const handleSearch = () => {
    loadDevices(1);
  };

  const handleReset = () => {
    const nextFilters = { user_id: '', platform: '', status: '', search: '' };
    setFilters(nextFilters);
    loadDevices(1, nextFilters);
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedDevices = [...devices].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'last_connected_at' || sortField === 'created_at') {
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

  const handleDeleteDevice = async (deviceId: number) => {
    if (!window.confirm('Удалить устройство?')) return;
    setError(null);
    try {
      await devicesService.deleteDevice(deviceId);
      await loadDevices(page);
    } catch (err: any) {
      const d = err.response?.data?.detail;
      setError(Array.isArray(d) ? (d.map((x: any) => x?.msg || JSON.stringify(x)).join(' ')) : (d || 'Ошибка удаления устройства'));
    }
  };

  const formatDate = (value?: string | null) => {
    if (!value) return '-';
    return new Date(value).toLocaleString('ru-RU');
  };

  const handleExport = () => {
    downloadCsv(
      'devices-export.csv',
      ['ID', 'User', 'Device ID', 'Name', 'Platform', 'App', 'Last IP', 'Last Connected', 'Active', 'Created At'],
      devices.map((device) => [
        device.id,
        device.user_email || device.user_id,
        device.device_id,
        device.device_name || '',
        device.platform || '',
        device.app_version || '',
        device.last_ip || '',
        device.last_connected || '',
        device.is_active,
        device.created_at,
      ])
    );
  };

  const isAllSelected = devices.length > 0 && devices.every((device) => selectedIds.includes(device.id));

  const toggleSelectAll = (checked: boolean) => {
    if (checked) {
      setSelectedIds(devices.map((device) => device.id));
    } else {
      setSelectedIds([]);
    }
  };

  const toggleSelectOne = (deviceId: number) => {
    setSelectedIds((prev) => (
      prev.includes(deviceId)
        ? prev.filter((id) => id !== deviceId)
        : [...prev, deviceId]
    ));
  };

  const handleBulkDisable = async () => {
    if (selectedIds.length === 0) return;
    if (!window.confirm(`Деактивировать выбранные устройства: ${selectedIds.length}?`)) return;
    try {
      await devicesService.bulkDisable(selectedIds);
      loadDevices(page);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка деактивации устройств');
    }
  };

  const handleBulkDelete = async () => {
    if (selectedIds.length === 0) return;
    if (!window.confirm(`Удалить выбранные устройства: ${selectedIds.length}?`)) return;
    setError(null);
    try {
      await devicesService.bulkDelete(selectedIds);
      await loadDevices(page);
    } catch (err: any) {
      const d = err.response?.data?.detail;
      setError(Array.isArray(d) ? (d.map((x: any) => x?.msg || JSON.stringify(x)).join(' ')) : (d || 'Ошибка удаления устройств'));
    }
  };

  if (loading && devices.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Устройства"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={devices.length === 0}>
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => loadDevices(1)}
              disabled={loading}
            >
              Обновить
            </Button>
          </Box>
        )}
      />

      {error && (
        <Alert severity="error" sx={{ mb: 3 }}>
          {error}
        </Alert>
      )}

      <FilterCard>
        <Grid container spacing={2} alignItems="center">
            <Grid item xs={12} md={4}>
              <TextField
                label="Поиск по email/ID/имени"
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
              <TextField
                label="Platform"
                value={filters.platform}
                onChange={(e) => setFilters({ ...filters, platform: e.target.value })}
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
                  <MenuItem value="inactive">Неактивные</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} md={2}>
              <Box display="flex" gap={1} flexWrap="wrap">
                <Button variant="contained" startIcon={<Search />} onClick={handleSearch}>
                  Найти
                </Button>
                <Button variant="outlined" onClick={handleReset}>
                  Сбросить
                </Button>
                <RoleGuard roles={['admin', 'owner']}>
                  <Button
                    variant="outlined"
                    color="warning"
                    startIcon={<Block />}
                    disabled={selectedIds.length === 0}
                    onClick={handleBulkDisable}
                  >
                    Деактивировать выбранные
                  </Button>
                </RoleGuard>
                <RoleGuard roles={['admin', 'owner']}>
                  <Button
                    variant="outlined"
                    color="error"
                    startIcon={<Delete />}
                    disabled={selectedIds.length === 0}
                    onClick={handleBulkDelete}
                  >
                    Удалить выбранные
                  </Button>
                </RoleGuard>
              </Box>
            </Grid>
        </Grid>
      </FilterCard>

      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell padding="checkbox">
                <Checkbox
                  checked={isAllSelected}
                  indeterminate={selectedIds.length > 0 && !isAllSelected}
                  onChange={(e) => toggleSelectAll(e.target.checked)}
                  inputProps={{ 'aria-label': 'select all devices' }}
                />
              </TableCell>
              <SortableHeader field="id">ID</SortableHeader>
              <SortableHeader field="user_id">User</SortableHeader>
              <SortableHeader field="device_id">Device ID</SortableHeader>
              <SortableHeader field="name">Имя</SortableHeader>
              <SortableHeader field="platform">Платформа</SortableHeader>
              <TableCell>App</TableCell>
              <TableCell>Последний IP</TableCell>
              <SortableHeader field="last_connected_at">Последнее подключение</SortableHeader>
              <TableCell>Статус</TableCell>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {devices.length === 0 ? (
              <TableRow>
                <TableCell colSpan={11} align="center">
                  <Typography variant="body2" color="textSecondary">
                    Устройства не найдены
                  </Typography>
                </TableCell>
              </TableRow>
            ) : (
              sortedDevices.map((device) => (
                <TableRow key={device.id}>
                  <TableCell padding="checkbox">
                    <Checkbox
                      checked={selectedIds.includes(device.id)}
                      onChange={() => toggleSelectOne(device.id)}
                    />
                  </TableCell>
                  <TableCell>{device.id}</TableCell>
                  <TableCell>{device.user_email || device.user_id}</TableCell>
                  <TableCell>{device.device_id}</TableCell>
                  <TableCell>{device.device_name || '-'}</TableCell>
                  <TableCell>{device.platform || '-'}</TableCell>
                  <TableCell>{device.app_version || '-'}</TableCell>
                  <TableCell>{device.last_ip || '-'}</TableCell>
                  <TableCell>{formatDate(device.last_connected)}</TableCell>
                  <TableCell>
                    <Chip
                      label={device.is_active ? 'Активно' : 'Неактивно'}
                      color={device.is_active ? 'success' : 'default'}
                      size="small"
                    />
                  </TableCell>
                  <TableCell>
                    <RoleGuard roles={['admin', 'owner']} fallback={<span>-</span>}>
                      <IconButton size="small" color="error" onClick={() => handleDeleteDevice(device.id)}>
                        <Delete />
                      </IconButton>
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
    </Box>
  );
};

export default DevicesPage;
