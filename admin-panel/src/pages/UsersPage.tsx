import React, { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { useNavigate } from 'react-router-dom';
import {
  Box,
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
  IconButton,
  Alert,
  CircularProgress,
  Pagination,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Checkbox,
  FormControlLabel,
  Grid,
} from '@mui/material';
import {
  Search,
  Block,
  CheckCircle,
  Visibility,
  Refresh,
  ArrowUpward,
  ArrowDownward,
  Description,
} from '@mui/icons-material';

import { RootState } from '../store';
import { fetchUsers, blockUser, unblockUser } from '../store/slices/usersSlice';
import { downloadCsv } from '../utils/csv';
import RoleGuard from '../components/RoleGuard';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const UsersPage: React.FC = () => {
  const dispatch = useDispatch<any>();
  const navigate = useNavigate();
  const { users, loading, error, total, page, limit } = useSelector((state: RootState) => state.users);
  const [searchTerm, setSearchTerm] = useState('');
  const [appliedSearchTerm, setAppliedSearchTerm] = useState('');
  
  // Фильтры
  const [countryFilter, setCountryFilter] = useState<string>('');
  const [authProviderFilter, setAuthProviderFilter] = useState<string>('');
  const [hasSubscriptionFilter, setHasSubscriptionFilter] = useState<boolean | null>(null);
  const [hasErrorsFilter, setHasErrorsFilter] = useState<boolean | null>(null);
  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  useEffect(() => {
    const filters: any = { page, limit };
    if (appliedSearchTerm) filters.search = appliedSearchTerm;
    if (countryFilter) filters.country = countryFilter;
    if (authProviderFilter) filters.auth_provider = authProviderFilter;
    if (hasSubscriptionFilter !== null) filters.has_subscription = hasSubscriptionFilter;
    if (hasErrorsFilter !== null) filters.has_errors = hasErrorsFilter;
    
    dispatch(fetchUsers(filters));
  }, [dispatch, page, limit, countryFilter, authProviderFilter, hasSubscriptionFilter, hasErrorsFilter, appliedSearchTerm]);

  useEffect(() => {
    setSelectedIds([]);
  }, [users]);

  const handleSearch = () => {
    setAppliedSearchTerm(searchTerm);
    const filters: any = { page: 1, limit };
    if (searchTerm) filters.search = searchTerm;
    if (countryFilter) filters.country = countryFilter;
    if (authProviderFilter) filters.auth_provider = authProviderFilter;
    if (hasSubscriptionFilter !== null) filters.has_subscription = hasSubscriptionFilter;
    if (hasErrorsFilter !== null) filters.has_errors = hasErrorsFilter;
    
    dispatch(fetchUsers(filters));
  };

  const handleClearFilters = () => {
    setSearchTerm('');
    setAppliedSearchTerm('');
    setCountryFilter('');
    setAuthProviderFilter('');
    setHasSubscriptionFilter(null);
    setHasErrorsFilter(null);
    dispatch(fetchUsers({ page: 1, limit }));
  };

  const handleBlockUser = (userId: number) => {
    dispatch(blockUser(userId));
  };

  const handleUnblockUser = (userId: number) => {
    dispatch(unblockUser(userId));
  };

  const handleViewUser = (userId: number) => {
    navigate(`/users/${userId}`);
  };

  const handlePageChange = (event: React.ChangeEvent<unknown>, value: number) => {
    dispatch(fetchUsers({ page: value, limit }));
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('ru-RU');
  };

  const isAllSelected = users.length > 0 && users.every((user) => selectedIds.includes(user.id));

  const toggleSelectAll = (checked: boolean) => {
    if (checked) {
      setSelectedIds(users.map((user) => user.id));
    } else {
      setSelectedIds([]);
    }
  };

  const toggleSelectOne = (userId: number) => {
    setSelectedIds((prev) => (
      prev.includes(userId)
        ? prev.filter((id) => id !== userId)
        : [...prev, userId]
    ));
  };

  const handleBulkBlock = async () => {
    if (selectedIds.length === 0) return;
    if (!window.confirm(`Заблокировать выбранных пользователей: ${selectedIds.length}?`)) return;
    await Promise.all(selectedIds.map((userId) => dispatch(blockUser(userId))));
    setSelectedIds([]);
  };

  const handleBulkUnblock = async () => {
    if (selectedIds.length === 0) return;
    if (!window.confirm(`Разблокировать выбранных пользователей: ${selectedIds.length}?`)) return;
    await Promise.all(selectedIds.map((userId) => dispatch(unblockUser(userId))));
    setSelectedIds([]);
  };

  const handleExport = () => {
    downloadCsv(
      'users-export.csv',
      ['ID', 'Email', 'Country', 'Auth Provider', 'Status', 'Subscription', 'Devices', 'Created At'],
      users.map((user) => [
        user.id,
        user.email,
        user.country || '',
        user.auth_provider || 'email',
        user.is_active ? 'active' : 'blocked',
        user.subscription_status || 'none',
        user.devices_count || 0,
        user.created_at,
      ])
    );
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedUsers = [...users].sort((a, b) => {
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

  if (loading && users.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Пользователи"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={users.length === 0}>
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => dispatch(fetchUsers({ page, limit }))}
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
                label="Поиск по email"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
                onKeyPress={(e) => e.key === 'Enter' && handleSearch()}
                size="small"
                fullWidth
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <FormControl fullWidth size="small">
                <InputLabel>Страна</InputLabel>
                <Select
                  value={countryFilter}
                  label="Страна"
                  onChange={(e) => setCountryFilter(e.target.value)}
                >
                  <MenuItem value="">Все</MenuItem>
                  <MenuItem value="RU">Россия</MenuItem>
                  <MenuItem value="US">США</MenuItem>
                  <MenuItem value="DE">Германия</MenuItem>
                  <MenuItem value="NL">Нидерланды</MenuItem>
                  <MenuItem value="GB">Великобритания</MenuItem>
                  <MenuItem value="FR">Франция</MenuItem>
                  <MenuItem value="SG">Сингапур</MenuItem>
                  <MenuItem value="JP">Япония</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <FormControl fullWidth size="small">
                <InputLabel>Auth Provider</InputLabel>
                <Select
                  value={authProviderFilter}
                  label="Auth Provider"
                  onChange={(e) => setAuthProviderFilter(e.target.value)}
                >
                  <MenuItem value="">Все</MenuItem>
                  <MenuItem value="email">Email</MenuItem>
                  <MenuItem value="google">Google</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <FormControlLabel
                control={
                  <Checkbox
                    checked={hasSubscriptionFilter === true}
                    indeterminate={hasSubscriptionFilter === null}
                    onChange={(e) => setHasSubscriptionFilter(e.target.checked ? true : null)}
                  />
                }
                label="С подпиской"
              />
            </Grid>
            <Grid item xs={12} sm={6} md={2}>
              <FormControlLabel
                control={
                  <Checkbox
                    checked={hasErrorsFilter === true}
                    indeterminate={hasErrorsFilter === null}
                    onChange={(e) => setHasErrorsFilter(e.target.checked ? true : null)}
                  />
                }
                label="С ошибками"
              />
            </Grid>
            <Grid item xs={12} md={12}>
              <Box display="flex" gap={2} flexWrap="wrap">
                <Button
                  variant="contained"
                  startIcon={<Search />}
                  onClick={handleSearch}
                >
                  Применить фильтры
                </Button>
                <Button
                  variant="outlined"
                  onClick={handleClearFilters}
                >
                  Сбросить
                </Button>
                <RoleGuard roles={['admin', 'owner']}>
                  <Button
                    variant="outlined"
                    color="error"
                    disabled={selectedIds.length === 0}
                    onClick={handleBulkBlock}
                  >
                    Заблокировать выбранных
                  </Button>
                </RoleGuard>
                <RoleGuard roles={['admin', 'owner']}>
                  <Button
                    variant="outlined"
                    color="success"
                    disabled={selectedIds.length === 0}
                    onClick={handleBulkUnblock}
                  >
                    Разблокировать выбранных
                  </Button>
                </RoleGuard>
              </Box>
            </Grid>
        </Grid>
      </FilterCard>

      <TableContainer component={Paper}>
        <Table>
          <TableHead>
            <TableRow>
              <TableCell padding="checkbox">
                <Checkbox
                  checked={isAllSelected}
                  indeterminate={selectedIds.length > 0 && !isAllSelected}
                  onChange={(e) => toggleSelectAll(e.target.checked)}
                  inputProps={{ 'aria-label': 'select all users' }}
                />
              </TableCell>
              <SortableHeader field="id">ID</SortableHeader>
              <SortableHeader field="email">Email</SortableHeader>
              <SortableHeader field="country">Страна</SortableHeader>
              <TableCell>Auth Provider</TableCell>
              <TableCell>Статус</TableCell>
              <TableCell>Подписка</TableCell>
              <SortableHeader field="devices_count">Устройств</SortableHeader>
              <SortableHeader field="created_at">Дата регистрации</SortableHeader>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {sortedUsers.map((user) => (
              <TableRow key={user.id}>
                <TableCell padding="checkbox">
                  <Checkbox
                    checked={selectedIds.includes(user.id)}
                    onChange={() => toggleSelectOne(user.id)}
                  />
                </TableCell>
                <TableCell>{user.id}</TableCell>
                <TableCell>{user.email}</TableCell>
                <TableCell>{user.country || '-'}</TableCell>
                <TableCell>
                  <Chip
                    label={user.auth_provider || 'email'}
                    size="small"
                    variant="outlined"
                  />
                </TableCell>
                <TableCell>
                  <Chip
                    label={user.is_active ? 'Активен' : 'Заблокирован'}
                    color={user.is_active ? 'success' : 'error'}
                    size="small"
                  />
                </TableCell>
                <TableCell>
                  {user.subscription_status ? (
                    <Chip
                      label={user.subscription_status}
                      color={user.subscription_status === 'active' ? 'success' : 'warning'}
                      size="small"
                    />
                  ) : (
                    <Chip label="Нет подписки" color="default" size="small" />
                  )}
                </TableCell>
                <TableCell>{user.devices_count || 0}</TableCell>
                <TableCell>{formatDate(user.created_at)}</TableCell>
                <TableCell>
                  <Box display="flex" gap={1}>
                    <IconButton
                      size="small"
                      onClick={() => handleViewUser(user.id)}
                      color="primary"
                      title="Открыть карточку"
                    >
                      <Visibility />
                    </IconButton>
                    <IconButton
                      size="small"
                      onClick={() => navigate(`/user-logs?userId=${user.id}`)}
                      title="Логи / диагностика"
                    >
                      <Description />
                    </IconButton>
                    <RoleGuard roles={['admin', 'owner']}>
                      {user.is_active ? (
                        <IconButton
                          size="small"
                          onClick={() => handleBlockUser(user.id)}
                          color="error"
                        >
                          <Block />
                        </IconButton>
                      ) : (
                        <IconButton
                          size="small"
                          onClick={() => handleUnblockUser(user.id)}
                          color="success"
                        >
                          <CheckCircle />
                        </IconButton>
                      )}
                    </RoleGuard>
                  </Box>
                </TableCell>
              </TableRow>
            ))}
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

export default UsersPage;
