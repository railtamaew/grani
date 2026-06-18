import React, { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Box,
  Typography,
  Card,
  CardContent,
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
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Alert,
  CircularProgress,
  Grid,
  LinearProgress,
  Tooltip,
  Stack,
  InputAdornment,
} from '@mui/material';
import {
  Add,
  Edit,
  Refresh,
  Visibility,
  Settings,
  BarChart as BarChartIcon,
  ArrowUpward,
  ArrowDownward,
  Search,
  Description,
} from '@mui/icons-material';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as RechartsTooltip, Legend, ResponsiveContainer } from 'recharts';

import { RootState } from '../store';
import { fetchServers, createServer, updateServer } from '../store/slices/serversSlice';
import { serversService } from '../services/serversService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const ServersPage: React.FC = () => {
  const dispatch = useDispatch<any>();
  const { servers, loading, error } = useSelector((state: RootState) => state.servers);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingServer, setEditingServer] = useState<any>(null);
  const [formData, setFormData] = useState({
    name: '',
    country: '',
    city: '',
    ip_address: '',
    port: 51820,
    max_users: 1000,
    ssh_host: '',
    ssh_port: 22,
    ssh_user: 'root',
    ssh_key_content: '',
  });
  const [statusDialogOpen, setStatusDialogOpen] = useState(false);
  const [selectedServer, setSelectedServer] = useState<any>(null);
  const [newStatus, setNewStatus] = useState('online');
  const [statsDialogOpen, setStatsDialogOpen] = useState(false);
  const [serverStats, setServerStats] = useState<any>(null);
  const [serverProtocols, setServerProtocols] = useState<any>(null);
  const [statsLoading, setStatsLoading] = useState(false);
  const [sessionsDialogOpen, setSessionsDialogOpen] = useState(false);
  const [activeSessions, setActiveSessions] = useState<any[]>([]);
  const [logsDialogOpen, setLogsDialogOpen] = useState(false);
  const [logsServer, setLogsServer] = useState<any>(null);
  const [logsParams, setLogsParams] = useState({ protocol: 'xray' as 'xray' | 'wireguard', log_type: 'access', lines: 200 });
  const [serverLogsContent, setServerLogsContent] = useState<string[]>([]);
  const [serverLogsLoading, setServerLogsLoading] = useState(false);
  const [serverLogsError, setServerLogsError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [countryFilter, setCountryFilter] = useState<string>('all');
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  useEffect(() => {
    dispatch(fetchServers());
  }, [dispatch]);

  const handleOpenDialog = (server?: any) => {
    if (server) {
      setEditingServer(server);
      setFormData({
        name: server.name,
        country: server.country,
        city: server.city || '',
        ip_address: server.ip_address,
        port: server.port ?? server.wireguard_port ?? 51820,
        max_users: server.max_users,
        ssh_host: server.ssh_host ?? server.ip_address ?? '',
        ssh_port: server.ssh_port ?? 22,
        ssh_user: server.ssh_user ?? 'root',
        ssh_key_content: '',
      });
    } else {
      setEditingServer(null);
      setFormData({
        name: '',
        country: '',
        city: '',
        ip_address: '',
        port: 51820,
        max_users: 1000,
        ssh_host: '',
        ssh_port: 22,
        ssh_user: 'root',
        ssh_key_content: '',
      });
    }
    setDialogOpen(true);
  };

  const handleCloseDialog = () => {
    setDialogOpen(false);
    setEditingServer(null);
  };

  const handleSubmit = () => {
    const payload: any = {
      name: formData.name,
      country: formData.country,
      city: formData.city || null,
      ip_address: formData.ip_address,
      wireguard_port: formData.port,
      max_users: formData.max_users,
      ssh_host: formData.ssh_host || formData.ip_address || null,
      ssh_port: formData.ssh_port,
      ssh_user: formData.ssh_user,
    };
    if (formData.ssh_key_content?.trim()) {
      payload.ssh_key_content = formData.ssh_key_content.trim();
    }
    if (editingServer) {
      dispatch(updateServer({ id: editingServer.id, data: payload }));
    } else {
      dispatch(createServer(payload));
    }
    handleCloseDialog();
  };

  const handleChangeStatus = async (serverId: number) => {
    try {
      await serversService.changeServerStatus(serverId, newStatus);
      setStatusDialogOpen(false);
      dispatch(fetchServers());
    } catch (err: any) {
      console.error('Ошибка изменения статуса:', err);
    }
  };

  const handleViewStats = async (serverId: number) => {
    try {
      setStatsLoading(true);
      setStatsDialogOpen(true);
      const [stats, protocols] = await Promise.all([
        serversService.getServerStats(serverId),
        serversService.getServerProtocols(serverId).catch(() => null)
      ]);
      setServerStats(stats);
      setServerProtocols(protocols);
    } catch (err: any) {
      console.error('Ошибка загрузки статистики:', err);
    } finally {
      setStatsLoading(false);
    }
  };

  const handleViewSessions = async (serverId: number) => {
    try {
      const sessions = await serversService.getServerActiveSessions(serverId);
      setActiveSessions(sessions);
      setSessionsDialogOpen(true);
    } catch (err: any) {
      console.error('Ошибка загрузки сессий:', err);
    }
  };

  const handleOpenLogsDialog = (server: any) => {
    setLogsServer(server);
    setLogsParams({ protocol: 'xray', log_type: 'access', lines: 200 });
    setServerLogsContent([]);
    setServerLogsError(null);
    setLogsDialogOpen(true);
  };

  // Автозагрузка логов при открытии диалога
  useEffect(() => {
    if (logsDialogOpen && logsServer) {
      handleLoadServerLogs();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- только при открытии диалога
  }, [logsDialogOpen, logsServer?.id]);

  const handleLoadServerLogs = async () => {
    if (!logsServer) return;
    setServerLogsLoading(true);
    setServerLogsError(null);
    try {
      const data = await serversService.getServerLogs(logsServer.id, {
        protocol: logsParams.protocol,
        log_type: logsParams.log_type,
        lines: logsParams.lines,
      });
      setServerLogsContent(data.logs || []);
    } catch (err: any) {
      setServerLogsError(err.response?.data?.detail || err.message || 'Ошибка загрузки логов');
      setServerLogsContent([]);
    } finally {
      setServerLogsLoading(false);
    }
  };

  const handleSort = (field: string) => {
    if (sortField === field) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortField(field);
      setSortDirection('asc');
    }
  };

  const sortedAndFilteredServers = [...servers]
    .filter((server) => {
      const matchesSearch = 
        server.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
        server.ip_address.toLowerCase().includes(searchQuery.toLowerCase()) ||
        server.country.toLowerCase().includes(searchQuery.toLowerCase()) ||
        (server.city && server.city.toLowerCase().includes(searchQuery.toLowerCase()));
      const matchesStatus = statusFilter === 'all' || 
        (statusFilter === 'active' && server.is_active) ||
        (statusFilter === 'inactive' && !server.is_active) ||
        (statusFilter === server.status);
      const matchesCountry = countryFilter === 'all' || server.country === countryFilter;
      return matchesSearch && matchesStatus && matchesCountry;
    })
    .sort((a, b) => {
      let aValue: any = a[sortField as keyof typeof a];
      let bValue: any = b[sortField as keyof typeof b];
      
      // Обработка специальных полей
      if (sortField === 'load_percentage') {
        aValue = a.load_percentage || 0;
        bValue = b.load_percentage || 0;
      } else if (sortField === 'bandwidth_used') {
        aValue = a.bandwidth_used_mbps || 0;
        bValue = b.bandwidth_used_mbps || 0;
      } else if (sortField === 'ping') {
        aValue = a.ping_ms || 0;
        bValue = b.ping_ms || 0;
      } else if (sortField === 'users') {
        aValue = a.current_users || 0;
        bValue = b.current_users || 0;
      } else if (typeof aValue === 'string') {
        aValue = aValue.toLowerCase();
        bValue = bValue?.toLowerCase() || '';
      }
      
      if (aValue < bValue) return sortDirection === 'asc' ? -1 : 1;
      if (aValue > bValue) return sortDirection === 'asc' ? 1 : -1;
      return 0;
    });

  const uniqueCountries = Array.from(new Set(servers.map(s => s.country))).sort();

  const SortableHeader = ({ field, children }: { field: string; children: React.ReactNode }) => (
    <TableCell 
      sx={{ cursor: 'pointer', userSelect: 'none' }}
      onClick={() => handleSort(field)}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
        {children}
        {sortField === field && (
          sortDirection === 'asc' ? <ArrowUpward fontSize="small" /> : <ArrowDownward fontSize="small" />
        )}
      </Box>
    </TableCell>
  );

  if (loading && servers.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Серверы"
        actions={(
          <Box display="flex" gap={1}>
            <Button
              variant="outlined"
              onClick={() => {
                downloadCsv(
                  'servers-export.csv',
                  ['ID', 'Name', 'Country', 'City', 'IP', 'Port', 'Users', 'Max Users', 'Load %', 'Bandwidth Used', 'Bandwidth Limit', 'Ping', 'Status', 'Active'],
                  sortedAndFilteredServers.map((server) => [
                    server.id,
                    server.name,
                    server.country,
                    server.city || '',
                    server.ip_address,
                    server.port || server.wireguard_port || '',
                    server.current_users || 0,
                    server.max_users || 0,
                    server.load_percentage || 0,
                    server.bandwidth_used_mbps || 0,
                    server.bandwidth_limit_mbps || 0,
                    server.ping_ms || 0,
                    server.status || '',
                    server.is_active ? 'active' : 'inactive',
                  ])
                );
              }}
              disabled={sortedAndFilteredServers.length === 0}
            >
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => dispatch(fetchServers())}
              disabled={loading}
            >
              Обновить
            </Button>
            <Button
              variant="contained"
              startIcon={<Add />}
              onClick={() => handleOpenDialog()}
            >
              Добавить сервер
            </Button>
          </Box>
        )}
      />

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => {}}>
          {error}
        </Alert>
      )}

      {/* Фильтры и поиск */}
      <FilterCard>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            placeholder="Поиск по названию, IP, стране, городу..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            size="small"
            sx={{ flexGrow: 1, minWidth: 300 }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <Search />
                </InputAdornment>
              ),
            }}
          />
          <FormControl size="small" sx={{ minWidth: 150 }}>
            <InputLabel>Статус</InputLabel>
            <Select
              value={statusFilter}
              label="Статус"
              onChange={(e) => setStatusFilter(e.target.value)}
            >
              <MenuItem value="all">Все</MenuItem>
              <MenuItem value="active">Активные</MenuItem>
              <MenuItem value="inactive">Неактивные</MenuItem>
              <MenuItem value="online">Online</MenuItem>
              <MenuItem value="offline">Offline</MenuItem>
              <MenuItem value="maintenance">Maintenance</MenuItem>
              <MenuItem value="draining">Draining</MenuItem>
            </Select>
          </FormControl>
          <FormControl size="small" sx={{ minWidth: 150 }}>
            <InputLabel>Страна</InputLabel>
            <Select
              value={countryFilter}
              label="Страна"
              onChange={(e) => setCountryFilter(e.target.value)}
            >
              <MenuItem value="all">Все</MenuItem>
              {uniqueCountries.map((country) => (
                <MenuItem key={country} value={country}>
                  {country}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <Button
            variant="outlined"
            onClick={() => {
              setSearchQuery('');
              setStatusFilter('all');
              setCountryFilter('all');
              setSortField('id');
              setSortDirection('asc');
            }}
          >
            Сбросить
          </Button>
        </Box>
      </FilterCard>

      <TableContainer component={Paper}>
        <Table>
          <TableHead>
            <TableRow>
              <SortableHeader field="id">ID</SortableHeader>
              <SortableHeader field="name">Название</SortableHeader>
              <SortableHeader field="country">Страна</SortableHeader>
              <SortableHeader field="city">Город</SortableHeader>
              <TableCell>IP адрес</TableCell>
              <TableCell>Порт</TableCell>
              <SortableHeader field="users">Пользователи</SortableHeader>
              <SortableHeader field="load_percentage">Загруженность</SortableHeader>
              <SortableHeader field="bandwidth_used">Bandwidth</SortableHeader>
              <SortableHeader field="ping">Ping</SortableHeader>
              <TableCell>Протоколы</TableCell>
              <TableCell>Статус</TableCell>
              <TableCell>Здоровье</TableCell>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {sortedAndFilteredServers.length === 0 ? (
              <TableRow>
                <TableCell colSpan={14} align="center">
                  <Typography variant="body2" color="textSecondary">
                    Серверы не найдены
                  </Typography>
                </TableCell>
              </TableRow>
            ) : (
              sortedAndFilteredServers.map((server) => {
              const loadPercentage = server.load_percentage || 0;
              const bandwidthUsed = server.bandwidth_used_mbps || 0;
              const bandwidthLimit = server.bandwidth_limit_mbps || 0;
              const bandwidthPercent = bandwidthLimit > 0 ? (bandwidthUsed / bandwidthLimit) * 100 : 0;
              const ping = server.ping_ms || 0;
              const supportedProtocols = server.supported_protocols || [];
              
              const getPingColor = (ping: number) => {
                if (ping === 0 || !ping) return 'default';
                if (ping < 50) return 'success';
                if (ping < 100) return 'warning';
                return 'error';
              };

              return (
                <TableRow key={server.id}>
                  <TableCell>{server.id}</TableCell>
                  <TableCell>{server.name}</TableCell>
                  <TableCell>{server.country}</TableCell>
                  <TableCell>{server.city || '-'}</TableCell>
                  <TableCell>{server.ip_address}</TableCell>
                  <TableCell>{server.port || server.wireguard_port || '-'}</TableCell>
                  <TableCell>
                    {server.current_users} / {server.max_users}
                  </TableCell>
                  <TableCell>
                    <Box sx={{ width: 100 }}>
                      <LinearProgress 
                        variant="determinate" 
                        value={loadPercentage} 
                        color={loadPercentage > 80 ? 'error' : loadPercentage > 60 ? 'warning' : 'primary'}
                        sx={{ height: 8, borderRadius: 4 }}
                      />
                      <Typography variant="caption" color="textSecondary">
                        {loadPercentage.toFixed(1)}%
                      </Typography>
                    </Box>
                  </TableCell>
                  <TableCell>
                    {bandwidthLimit > 0 ? (
                      <Box sx={{ width: 120 }}>
                        <LinearProgress 
                          variant="determinate" 
                          value={bandwidthPercent} 
                          color={bandwidthPercent > 80 ? 'error' : bandwidthPercent > 60 ? 'warning' : 'primary'}
                          sx={{ height: 8, borderRadius: 4 }}
                        />
                        <Typography variant="caption" color="textSecondary">
                          {bandwidthUsed.toFixed(1)} / {bandwidthLimit.toFixed(1)} Mbps
                        </Typography>
                      </Box>
                    ) : (
                      <Typography variant="caption" color="textSecondary">
                        {bandwidthUsed.toFixed(1)} Mbps
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell>
                    {ping > 0 ? (
                      <Chip
                        label={`${ping.toFixed(0)} ms`}
                        color={getPingColor(ping) as any}
                        size="small"
                      />
                    ) : (
                      <Typography variant="caption" color="textSecondary">-</Typography>
                    )}
                  </TableCell>
                  <TableCell>
                    <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                      {supportedProtocols.slice(0, 3).map((protocol) => (
                        <Chip
                          key={protocol}
                          label={protocol.replace('xray_', '').replace('_', ' ')}
                          size="small"
                          variant="outlined"
                          sx={{ fontSize: '0.65rem', height: 20 }}
                        />
                      ))}
                      {supportedProtocols.length > 3 && (
                        <Tooltip title={supportedProtocols.slice(3).join(', ')}>
                          <Chip
                            label={`+${supportedProtocols.length - 3}`}
                            size="small"
                            variant="outlined"
                            sx={{ fontSize: '0.65rem', height: 20 }}
                          />
                        </Tooltip>
                      )}
                    </Stack>
                  </TableCell>
                  <TableCell>
                    <Chip
                      label={server.is_active ? 'Активен' : 'Неактивен'}
                      color={server.is_active ? 'success' : 'default'}
                      size="small"
                    />
                  </TableCell>
                  <TableCell>
                    <Chip
                      label={server.health_status === 'healthy' ? 'OK' : server.health_status || 'Неизвестно'}
                      color={server.health_status === 'healthy' ? 'success' : 'error'}
                      size="small"
                    />
                  </TableCell>
                  <TableCell>
                    <IconButton
                      size="small"
                      onClick={() => handleOpenDialog(server)}
                      title="Редактировать"
                    >
                      <Edit />
                    </IconButton>
                    <IconButton
                      size="small"
                      onClick={() => {
                        setSelectedServer(server);
                        setNewStatus((server as any).status || (server.is_active ? 'online' : 'offline'));
                        setStatusDialogOpen(true);
                      }}
                      title="Изменить статус"
                    >
                      <Settings />
                    </IconButton>
                    <IconButton
                      size="small"
                    onClick={() => handleViewStats(server.id)}
                    title="Статистика"
                    color="primary"
                  >
                    <BarChartIcon />
                  </IconButton>
                    <IconButton
                      size="small"
                      onClick={() => handleViewSessions(server.id)}
                      title="Активные сессии"
                      color="info"
                    >
                      <Visibility />
                    </IconButton>
                    <Tooltip title="Логи сервера">
                      <IconButton
                        size="small"
                        onClick={() => handleOpenLogsDialog(server)}
                        color="default"
                      >
                        <Description />
                      </IconButton>
                    </Tooltip>
                  </TableCell>
                </TableRow>
              );
            }))}
          </TableBody>
        </Table>
      </TableContainer>

      <Dialog open={dialogOpen} onClose={handleCloseDialog} maxWidth="sm" fullWidth>
        <DialogTitle>
          {editingServer ? 'Редактировать сервер' : 'Добавить сервер'}
        </DialogTitle>
        <DialogContent>
          <Box sx={{ pt: 1 }}>
            <TextField
              fullWidth
              label="Название сервера"
              value={formData.name}
              onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              margin="normal"
            />
            <TextField
              fullWidth
              label="Страна"
              value={formData.country}
              onChange={(e) => setFormData({ ...formData, country: e.target.value })}
              margin="normal"
            />
            <TextField
              fullWidth
              label="Город"
              value={formData.city}
              onChange={(e) => setFormData({ ...formData, city: e.target.value })}
              margin="normal"
            />
            <TextField
              fullWidth
              label="IP адрес"
              value={formData.ip_address}
              onChange={(e) => setFormData({ ...formData, ip_address: e.target.value })}
              margin="normal"
            />
            <TextField
              fullWidth
              label="Порт"
              type="number"
              value={formData.port}
              onChange={(e) => setFormData({ ...formData, port: parseInt(e.target.value) })}
              margin="normal"
            />
            <TextField
              fullWidth
              label="Максимум пользователей"
              type="number"
              value={formData.max_users}
              onChange={(e) => setFormData({ ...formData, max_users: parseInt(e.target.value) })}
              margin="normal"
            />
            <Typography variant="subtitle2" sx={{ mt: 2, mb: 1 }} color="textSecondary">
              SSH доступ
            </Typography>
            <TextField
              fullWidth
              label="SSH хост (если отличается от IP)"
              placeholder={formData.ip_address || 'тот же, что IP'}
              value={formData.ssh_host}
              onChange={(e) => setFormData({ ...formData, ssh_host: e.target.value })}
              margin="normal"
              size="small"
            />
            <Grid container spacing={2}>
              <Grid item xs={6}>
                <TextField
                  fullWidth
                  label="SSH порт"
                  type="number"
                  value={formData.ssh_port}
                  onChange={(e) => setFormData({ ...formData, ssh_port: parseInt(e.target.value) || 22 })}
                  margin="normal"
                  size="small"
                />
              </Grid>
              <Grid item xs={6}>
                <TextField
                  fullWidth
                  label="SSH пользователь"
                  value={formData.ssh_user}
                  onChange={(e) => setFormData({ ...formData, ssh_user: e.target.value })}
                  margin="normal"
                  size="small"
                />
              </Grid>
            </Grid>
            <TextField
              fullWidth
              label="Приватный ключ SSH (содержимое)"
              placeholder={editingServer?.has_ssh_key ? 'Оставьте пустым, чтобы не менять ключ' : 'Вставьте содержимое ключа'}
              value={formData.ssh_key_content}
              onChange={(e) => setFormData({ ...formData, ssh_key_content: e.target.value })}
              margin="normal"
              size="small"
              multiline
              minRows={2}
              maxRows={6}
            />
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={handleCloseDialog}>Отмена</Button>
          <Button onClick={handleSubmit} variant="contained">
            {editingServer ? 'Сохранить' : 'Добавить'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Диалог изменения статуса */}
      <Dialog open={statusDialogOpen} onClose={() => setStatusDialogOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>Изменить статус сервера</DialogTitle>
        <DialogContent>
          <FormControl fullWidth margin="normal">
            <InputLabel>Статус</InputLabel>
            <Select
              value={newStatus}
              label="Статус"
              onChange={(e) => setNewStatus(e.target.value)}
            >
              <MenuItem value="online">Online</MenuItem>
              <MenuItem value="offline">Offline</MenuItem>
              <MenuItem value="maintenance">Maintenance</MenuItem>
              <MenuItem value="draining">Draining</MenuItem>
            </Select>
          </FormControl>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatusDialogOpen(false)}>Отмена</Button>
          <Button
            onClick={() => selectedServer && handleChangeStatus(selectedServer.id)}
            variant="contained"
          >
            Сохранить
          </Button>
        </DialogActions>
      </Dialog>

      {/* Диалог статистики */}
      <Dialog open={statsDialogOpen} onClose={() => setStatsDialogOpen(false)} maxWidth="lg" fullWidth>
        <DialogTitle>Статистика сервера</DialogTitle>
        <DialogContent>
          {statsLoading ? (
            <Box display="flex" justifyContent="center" alignItems="center" minHeight="200px">
              <CircularProgress />
            </Box>
          ) : serverStats ? (
            <Box>
              <Typography variant="h6" gutterBottom>{serverStats.server_name}</Typography>
              
              {/* Основные метрики */}
              <Grid container spacing={2} sx={{ mt: 1, mb: 3 }}>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Уникальные пользователи (24ч)</Typography>
                      <Typography variant="h5">{serverStats.unique_users_24h || 0}</Typography>
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Уникальные пользователи (7д)</Typography>
                      <Typography variant="h5">{serverStats.unique_users_7d || 0}</Typography>
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Уникальные пользователи (30д)</Typography>
                      <Typography variant="h5">{serverStats.unique_users_30d || 0}</Typography>
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Ошибки (24ч)</Typography>
                      <Typography variant="h5" color="error">{serverStats.errors_24h || 0}</Typography>
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Текущие пользователи</Typography>
                      <Typography variant="h5">{serverStats.current_users || 0} / {serverStats.max_users || 0}</Typography>
                      <LinearProgress 
                        variant="determinate" 
                        value={(serverStats.current_users || 0) / (serverStats.max_users || 1) * 100}
                        sx={{ mt: 1 }}
                      />
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Загрузка</Typography>
                      <Typography variant="h5">{serverStats.load_percentage?.toFixed(1) || 0}%</Typography>
                      <LinearProgress 
                        variant="determinate" 
                        value={serverStats.load_percentage || 0}
                        color={serverStats.load_percentage > 80 ? 'error' : serverStats.load_percentage > 60 ? 'warning' : 'primary'}
                        sx={{ mt: 1 }}
                      />
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Среднее время подключения</Typography>
                      <Typography variant="h5">{Math.round((serverStats.average_connection_duration_seconds || 0) / 60)} мин</Typography>
                    </CardContent>
                  </Card>
                </Grid>
                <Grid item xs={12} sm={6} md={3}>
                  <Card variant="outlined">
                    <CardContent>
                      <Typography variant="body2" color="textSecondary">Статус</Typography>
                      <Chip
                        label={serverStats.status || 'unknown'}
                        color={serverStats.status === 'online' ? 'success' : 'default'}
                        size="small"
                        sx={{ mt: 1 }}
                      />
                    </CardContent>
                  </Card>
                </Grid>
              </Grid>

              {/* Статистика по протоколам */}
              {serverProtocols && serverProtocols.protocol_stats && Object.keys(serverProtocols.protocol_stats).length > 0 && (
                <Box sx={{ mt: 3 }}>
                  <Typography variant="h6" gutterBottom>Статистика по протоколам</Typography>
                  <Grid container spacing={2}>
                    {/* График подключений по протоколам */}
                    <Grid item xs={12} md={6}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="subtitle2" gutterBottom>Подключения по протоколам</Typography>
                          <ResponsiveContainer width="100%" height={300}>
                            <BarChart data={Object.entries(serverProtocols.protocol_stats).map(([protocol, stats]: [string, any]) => ({
                              name: protocol.replace('xray_', '').replace('_', ' '),
                              successful: stats.successful_connections || 0,
                              failed: stats.failed_connections || 0,
                              total: stats.total_connections || 0
                            }))}>
                              <CartesianGrid strokeDasharray="3 3" />
                              <XAxis dataKey="name" />
                              <YAxis />
                              <RechartsTooltip />
                              <Legend />
                              <Bar dataKey="successful" fill="#4caf50" name="Успешные" />
                              <Bar dataKey="failed" fill="#f44336" name="Неудачные" />
                            </BarChart>
                          </ResponsiveContainer>
                        </CardContent>
                      </Card>
                    </Grid>

                    {/* График производительности по протоколам */}
                    <Grid item xs={12} md={6}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="subtitle2" gutterBottom>Производительность по протоколам</Typography>
                          <ResponsiveContainer width="100%" height={300}>
                            <BarChart data={Object.entries(serverProtocols.protocol_stats).map(([protocol, stats]: [string, any]) => ({
                              name: protocol.replace('xray_', '').replace('_', ' '),
                              speed: stats.average_speed_mbps || 0,
                              ping: (stats.average_ping_ms || 0) / 10, // Масштабируем для визуализации
                              uptime: stats.uptime_percentage || 0
                            }))}>
                              <CartesianGrid strokeDasharray="3 3" />
                              <XAxis dataKey="name" />
                              <YAxis yAxisId="left" />
                              <YAxis yAxisId="right" orientation="right" />
                              <RechartsTooltip />
                              <Legend />
                              <Bar yAxisId="left" dataKey="speed" fill="#2196f3" name="Скорость (Mbps)" />
                              <Bar yAxisId="right" dataKey="uptime" fill="#ff9800" name="Uptime (%)" />
                            </BarChart>
                          </ResponsiveContainer>
                        </CardContent>
                      </Card>
                    </Grid>

                    {/* Таблица детальной статистики по протоколам */}
                    <Grid item xs={12}>
                      <TableContainer component={Paper} variant="outlined">
                        <Table size="small">
                          <TableHead>
                            <TableRow>
                              <TableCell>Протокол</TableCell>
                              <TableCell align="right">Всего подключений</TableCell>
                              <TableCell align="right">Успешных</TableCell>
                              <TableCell align="right">Неудачных</TableCell>
                              <TableCell align="right">Средняя скорость (Mbps)</TableCell>
                              <TableCell align="right">Средний ping (ms)</TableCell>
                              <TableCell align="right">Uptime (%)</TableCell>
                            </TableRow>
                          </TableHead>
                          <TableBody>
                            {Object.entries(serverProtocols.protocol_stats).map(([protocol, stats]: [string, any]) => (
                              <TableRow key={protocol}>
                                <TableCell>
                                  <Chip
                                    label={protocol.replace('xray_', '').replace('_', ' ')}
                                    size="small"
                                    variant="outlined"
                                  />
                                </TableCell>
                                <TableCell align="right">{stats.total_connections || 0}</TableCell>
                                <TableCell align="right">
                                  <Typography color="success.main">{stats.successful_connections || 0}</Typography>
                                </TableCell>
                                <TableCell align="right">
                                  <Typography color="error.main">{stats.failed_connections || 0}</Typography>
                                </TableCell>
                                <TableCell align="right">{stats.average_speed_mbps?.toFixed(2) || 0}</TableCell>
                                <TableCell align="right">{stats.average_ping_ms?.toFixed(1) || 0}</TableCell>
                                <TableCell align="right">
                                  <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 1 }}>
                                    <Typography variant="body2">{stats.uptime_percentage?.toFixed(1) || 0}%</Typography>
                                    <LinearProgress 
                                      variant="determinate" 
                                      value={stats.uptime_percentage || 0}
                                      sx={{ width: 60, height: 6, borderRadius: 3 }}
                                    />
                                  </Box>
                                </TableCell>
                              </TableRow>
                            ))}
                          </TableBody>
                        </Table>
                      </TableContainer>
                    </Grid>
                  </Grid>
                </Box>
              )}
            </Box>
          ) : (
            <Typography>Нет данных</Typography>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setStatsDialogOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>

      {/* Диалог активных сессий */}
      <Dialog open={sessionsDialogOpen} onClose={() => setSessionsDialogOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Активные сессии</DialogTitle>
        <DialogContent>
          <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>ID</TableCell>
                  <TableCell>User ID</TableCell>
                  <TableCell>Device ID</TableCell>
                  <TableCell>IP адрес</TableCell>
                  <TableCell>Подключен</TableCell>
                </TableRow>
              </TableHead>
              <TableBody>
                {activeSessions.map((session) => (
                  <TableRow key={session.id}>
                    <TableCell>{session.id}</TableCell>
                    <TableCell>{session.user_id}</TableCell>
                    <TableCell>{session.device_id}</TableCell>
                    <TableCell>{session.ip_address || '-'}</TableCell>
                    <TableCell>
                      {session.connected_at
                        ? new Date(session.connected_at).toLocaleString('ru-RU')
                        : '-'}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TableContainer>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setSessionsDialogOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>

      {/* Диалог логов сервера */}
      <Dialog open={logsDialogOpen} onClose={() => setLogsDialogOpen(false)} maxWidth="lg" fullWidth>
        <DialogTitle>Логи сервера{logsServer ? `: ${logsServer.name}` : ''}</DialogTitle>
        <DialogContent>
          <Grid container spacing={2} sx={{ mb: 2 }}>
            <Grid item xs={12} sm={4}>
              <FormControl fullWidth size="small">
                <InputLabel>Протокол</InputLabel>
                <Select
                  value={logsParams.protocol}
                  label="Протокол"
                  onChange={(e) => setLogsParams((p) => ({ ...p, protocol: e.target.value as 'xray' | 'wireguard' }))}
                >
                  <MenuItem value="xray">XRay</MenuItem>
                  <MenuItem value="wireguard">WireGuard</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            {logsParams.protocol === 'xray' && (
              <Grid item xs={12} sm={4}>
                <FormControl fullWidth size="small">
                  <InputLabel>Тип лога</InputLabel>
                  <Select
                    value={logsParams.log_type}
                    label="Тип лога"
                    onChange={(e) => setLogsParams((p) => ({ ...p, log_type: e.target.value }))}
                  >
                    <MenuItem value="access">Access</MenuItem>
                    <MenuItem value="error">Error</MenuItem>
                    <MenuItem value="journalctl">Journal (systemd)</MenuItem>
                  </Select>
                </FormControl>
              </Grid>
            )}
            <Grid item xs={12} sm={2}>
              <FormControl fullWidth size="small">
                <InputLabel>Строк</InputLabel>
                <Select
                  value={logsParams.lines}
                  label="Строк"
                  onChange={(e) => setLogsParams((p) => ({ ...p, lines: Number(e.target.value) }))}
                >
                  <MenuItem value={100}>100</MenuItem>
                  <MenuItem value={200}>200</MenuItem>
                  <MenuItem value={500}>500</MenuItem>
                  <MenuItem value={1000}>1000</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={2} sx={{ display: 'flex', alignItems: 'center' }}>
              <Button variant="contained" onClick={handleLoadServerLogs} disabled={serverLogsLoading}>
                {serverLogsLoading ? <CircularProgress size={24} /> : 'Загрузить'}
              </Button>
            </Grid>
          </Grid>
          {serverLogsError && (
            <Alert severity="error" sx={{ mb: 2 }} onClose={() => setServerLogsError(null)}>
              {serverLogsError}
            </Alert>
          )}
          <Box
            sx={{
              bgcolor: 'grey.900',
              color: 'grey.100',
              p: 2,
              borderRadius: 1,
              maxHeight: 400,
              overflow: 'auto',
              fontFamily: 'monospace',
              fontSize: '0.8rem',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-all',
            }}
            component="pre"
          >
            {serverLogsContent.length === 0 && !serverLogsLoading && !serverLogsError
              ? 'Выберите параметры и нажмите «Загрузить».'
              : serverLogsContent.join('\n')}
          </Box>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setLogsDialogOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default ServersPage;
