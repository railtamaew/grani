import React, { useEffect, useState } from 'react';
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
  Alert,
  CircularProgress,
  Grid,
  LinearProgress,
  Stack,
  TextField,
  InputAdornment,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Tabs,
  Tab,
} from '@mui/material';
import {
  Refresh,
  Visibility,
  Settings,
  TrendingUp,
  Speed,
  CheckCircle,
  Info,
  ArrowUpward,
  ArrowDownward,
} from '@mui/icons-material';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as RechartsTooltip, Legend, ResponsiveContainer } from 'recharts';
import { protocolsService, Protocol, ProtocolStats, ProtocolServer, ProtocolPerformance } from '../services/protocolsService';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

interface TabPanelProps {
  children?: React.ReactNode;
  index: number;
  value: number;
}

function TabPanel(props: TabPanelProps) {
  const { children, value, index, ...other } = props;
  return (
    <div
      role="tabpanel"
      hidden={value !== index}
      id={`protocol-tabpanel-${index}`}
      aria-labelledby={`protocol-tab-${index}`}
      {...other}
    >
      {value === index && <Box sx={{ p: 3 }}>{children}</Box>}
    </div>
  );
}

const ProtocolsPage: React.FC = () => {
  const [protocols, setProtocols] = useState<Protocol[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedProtocol, setSelectedProtocol] = useState<Protocol | null>(null);
  const [protocolStats, setProtocolStats] = useState<ProtocolStats | null>(null);
  const [protocolServers, setProtocolServers] = useState<ProtocolServer[]>([]);
  const [protocolPerformance, setProtocolPerformance] = useState<ProtocolPerformance | null>(null);
  const [detailDialogOpen, setDetailDialogOpen] = useState(false);
  const [statsLoading, setStatsLoading] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [tabValue, setTabValue] = useState(0);
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  useEffect(() => {
    loadProtocols();
  }, []);

  const loadProtocols = async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await protocolsService.getProtocols();
      setProtocols(data);
    } catch (err: any) {
      setError(err.message || 'Ошибка загрузки протоколов');
      console.error('Ошибка загрузки протоколов:', err);
    } finally {
      setLoading(false);
    }
  };

  const handleViewDetails = async (protocol: Protocol) => {
    try {
      setStatsLoading(true);
      setSelectedProtocol(protocol);
      setDetailDialogOpen(true);
      setTabValue(0);

      const [stats, servers, performance] = await Promise.all([
        protocolsService.getProtocolStats(protocol.id, 30).catch(() => null),
        protocolsService.getProtocolServers(protocol.id).catch(() => []),
        protocolsService.getProtocolPerformance(protocol.code, 7).catch(() => null),
      ]);

      setProtocolStats(stats);
      setProtocolServers(servers);
      setProtocolPerformance(performance);
    } catch (err: any) {
      console.error('Ошибка загрузки деталей протокола:', err);
      setError(err.message || 'Ошибка загрузки деталей протокола');
    } finally {
      setStatsLoading(false);
    }
  };

  const handleEnableDisable = async (protocol: Protocol) => {
    try {
      if (protocol.status === 'enabled') {
        await protocolsService.disableProtocol(protocol.id);
      } else {
        await protocolsService.enableProtocol(protocol.id);
      }
      await loadProtocols();
    } catch (err: any) {
      setError(err.message || 'Ошибка изменения статуса протокола');
      console.error('Ошибка изменения статуса:', err);
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'enabled':
        return 'success';
      case 'disabled':
        return 'default';
      case 'testing':
        return 'warning';
      case 'deprecated':
        return 'error';
      default:
        return 'default';
    }
  };

  const getStatusLabel = (status: string) => {
    switch (status) {
      case 'enabled':
        return 'Включен';
      case 'disabled':
        return 'Выключен';
      case 'testing':
        return 'Тестирование';
      case 'deprecated':
        return 'Устаревший';
      default:
        return status;
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

  const filteredProtocols = protocols
    .filter((protocol) => {
      const matchesSearch = 
        protocol.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
        protocol.code.toLowerCase().includes(searchQuery.toLowerCase());
      const matchesStatus = statusFilter === 'all' || protocol.status === statusFilter;
      return matchesSearch && matchesStatus;
    })
    .sort((a, b) => {
      let aValue: any = a[sortField as keyof typeof a];
      let bValue: any = b[sortField as keyof typeof b];
      
      // Обработка специальных полей
      if (sortField === 'active_users_24h') {
        aValue = a.active_users_24h || 0;
        bValue = b.active_users_24h || 0;
      } else if (typeof aValue === 'string') {
        aValue = aValue.toLowerCase();
        bValue = bValue?.toLowerCase() || '';
      }
      
      if (aValue < bValue) return sortDirection === 'asc' ? -1 : 1;
      if (aValue > bValue) return sortDirection === 'asc' ? 1 : -1;
      return 0;
    });

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

  if (loading && protocols.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  if (!loading && protocols.length === 0) {
    return (
      <Box>
        <PageHeader title="Протоколы" />
        <Card>
          <CardContent>
            <Typography variant="h6" gutterBottom>
              Протоколы не настроены
            </Typography>
            <Typography variant="body2" color="textSecondary" paragraph>
              В таблице протоколов пока нет записей. Список протоколов (WireGuard, Xray и др.) можно добавить через API или выполнив скрипт сидирования на бэкенде: <code>python scripts/seed_protocols.py</code>.
            </Typography>
            <Button variant="outlined" startIcon={<Refresh />} onClick={loadProtocols}>
              Обновить
            </Button>
          </CardContent>
        </Card>
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Протоколы"
        actions={(
          <Box display="flex" gap={1}>
            <Button
              variant="outlined"
              onClick={() => {
                downloadCsv(
                  'protocols-export.csv',
                  ['ID', 'Name', 'Code', 'Status', 'Active Users 24h', 'Platforms'],
                  filteredProtocols.map((protocol) => [
                    protocol.id,
                    protocol.name,
                    protocol.code,
                    protocol.status,
                    protocol.active_users_24h ?? 0,
                    (protocol.app_supported || []).join(', '),
                  ])
                );
              }}
              disabled={filteredProtocols.length === 0}
            >
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={loadProtocols}
              disabled={loading}
            >
              Обновить
            </Button>
          </Box>
        )}
      />

      {error && (
        <Alert severity="error" sx={{ mb: 3 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {/* Фильтры */}
      <FilterCard>
        <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap', alignItems: 'center' }}>
          <TextField
            placeholder="Поиск по названию или коду..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            size="small"
            sx={{ flexGrow: 1 }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <Info />
                </InputAdornment>
              ),
            }}
          />
          <FormControl size="small" sx={{ minWidth: 200 }}>
            <InputLabel>Статус</InputLabel>
            <Select
              value={statusFilter}
              label="Статус"
              onChange={(e) => setStatusFilter(e.target.value)}
            >
              <MenuItem value="all">Все</MenuItem>
              <MenuItem value="enabled">Включен</MenuItem>
              <MenuItem value="disabled">Выключен</MenuItem>
              <MenuItem value="testing">Тестирование</MenuItem>
              <MenuItem value="deprecated">Устаревший</MenuItem>
            </Select>
          </FormControl>
          <Button
            variant="outlined"
            onClick={() => {
              setSearchQuery('');
              setStatusFilter('all');
              setSortField('id');
              setSortDirection('asc');
            }}
          >
            Сбросить
          </Button>
        </Box>
      </FilterCard>

      {/* Таблица протоколов */}
      <TableContainer component={Paper}>
        <Table>
          <TableHead>
            <TableRow>
              <SortableHeader field="id">ID</SortableHeader>
              <SortableHeader field="name">Название</SortableHeader>
              <SortableHeader field="code">Код</SortableHeader>
              <SortableHeader field="status">Статус</SortableHeader>
              <SortableHeader field="active_users_24h">Активные пользователи (24ч)</SortableHeader>
              <TableCell>Поддерживаемые платформы</TableCell>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {filteredProtocols.length === 0 ? (
              <TableRow>
                <TableCell colSpan={7} align="center">
                  <Typography variant="body2" color="textSecondary">
                    Протоколы не найдены
                  </Typography>
                </TableCell>
              </TableRow>
            ) : (
              filteredProtocols.map((protocol) => (
                <TableRow key={protocol.id}>
                  <TableCell>{protocol.id}</TableCell>
                  <TableCell>
                    <Typography variant="body2" fontWeight="medium">
                      {protocol.name}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Chip
                      label={protocol.code}
                      size="small"
                      variant="outlined"
                      sx={{ fontFamily: 'monospace' }}
                    />
                  </TableCell>
                  <TableCell>
                    <Chip
                      label={getStatusLabel(protocol.status)}
                      color={getStatusColor(protocol.status) as any}
                      size="small"
                    />
                  </TableCell>
                  <TableCell>
                    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                      <Typography variant="body2">{protocol.active_users_24h ?? 0}</Typography>
                      {(protocol.active_users_24h ?? 0) > 0 && (
                        <Chip
                          label={`+${(((protocol.active_users_24h ?? 0) / 100).toFixed(0))}%`}
                          size="small"
                          color="success"
                          variant="outlined"
                          sx={{ fontSize: '0.65rem', height: 20 }}
                        />
                      )}
                    </Box>
                  </TableCell>
                  <TableCell>
                    <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                      {(protocol.app_supported || []).map((platform) => (
                        <Chip
                          key={platform}
                          label={platform}
                          size="small"
                          variant="outlined"
                          sx={{ fontSize: '0.65rem', height: 20 }}
                        />
                      ))}
                    </Stack>
                  </TableCell>
                  <TableCell>
                    <IconButton
                      size="small"
                      onClick={() => handleViewDetails(protocol)}
                      title="Детали"
                      color="primary"
                    >
                      <Visibility />
                    </IconButton>
                    <IconButton
                      size="small"
                      onClick={() => handleEnableDisable(protocol)}
                      title={protocol.status === 'enabled' ? 'Выключить' : 'Включить'}
                      color={protocol.status === 'enabled' ? 'warning' : 'success'}
                    >
                      <Settings />
                    </IconButton>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </TableContainer>

      {/* Диалог деталей протокола */}
      <Dialog open={detailDialogOpen} onClose={() => setDetailDialogOpen(false)} maxWidth="lg" fullWidth>
        <DialogTitle>
          {selectedProtocol?.name} ({selectedProtocol?.code})
        </DialogTitle>
        <DialogContent>
          {statsLoading ? (
            <Box display="flex" justifyContent="center" alignItems="center" minHeight="200px">
              <CircularProgress />
            </Box>
          ) : (
            <Box>
              <Tabs value={tabValue} onChange={(e, newValue) => setTabValue(newValue)} sx={{ mb: 2 }}>
                <Tab label="Общая статистика" />
                <Tab label="Серверы" />
                <Tab label="Производительность" />
              </Tabs>

              {/* Вкладка общей статистики */}
              <TabPanel value={tabValue} index={0}>
                {protocolStats ? (
                  <Grid container spacing={2}>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Активные пользователи (24ч)</Typography>
                          <Typography variant="h5">{protocolStats.active_users['24h'] || 0}</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Активные пользователи (7д)</Typography>
                          <Typography variant="h5">{protocolStats.active_users['7d'] || 0}</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Активные пользователи (30д)</Typography>
                          <Typography variant="h5">{protocolStats.active_users['30d'] || 0}</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Ошибки ({protocolStats.period_days}д)</Typography>
                          <Typography variant="h5" color="error">{protocolStats.errors_count || 0}</Typography>
                        </CardContent>
                      </Card>
                    </Grid>

                    {/* График активных пользователей */}
                    <Grid item xs={12}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="subtitle2" gutterBottom>Активные пользователи</Typography>
                          <ResponsiveContainer width="100%" height={300}>
                            <BarChart data={[
                              { period: '24ч', users: protocolStats.active_users['24h'] },
                              { period: '7д', users: protocolStats.active_users['7d'] },
                              { period: '30д', users: protocolStats.active_users['30d'] },
                            ]}>
                              <CartesianGrid strokeDasharray="3 3" />
                              <XAxis dataKey="period" />
                              <YAxis />
                              <RechartsTooltip />
                              <Legend />
                              <Bar dataKey="users" fill="#2196f3" name="Пользователи" />
                            </BarChart>
                          </ResponsiveContainer>
                        </CardContent>
                      </Card>
                    </Grid>
                  </Grid>
                ) : (
                  <Typography>Статистика недоступна</Typography>
                )}
              </TabPanel>

              {/* Вкладка серверов */}
              <TabPanel value={tabValue} index={1}>
                {protocolServers.length > 0 ? (
                  <TableContainer component={Paper} variant="outlined">
                    <Table size="small">
                      <TableHead>
                        <TableRow>
                          <TableCell>ID</TableCell>
                          <TableCell>Название</TableCell>
                          <TableCell>Страна</TableCell>
                          <TableCell>Статус</TableCell>
                          <TableCell>Активен</TableCell>
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {protocolServers.map((server) => (
                          <TableRow key={server.id}>
                            <TableCell>{server.id}</TableCell>
                            <TableCell>{server.name}</TableCell>
                            <TableCell>{server.country}</TableCell>
                            <TableCell>
                              <Chip
                                label={server.status}
                                size="small"
                                color={server.status === 'online' ? 'success' : 'default'}
                              />
                            </TableCell>
                            <TableCell>
                              <Chip
                                label={server.is_active ? 'Да' : 'Нет'}
                                size="small"
                                color={server.is_active ? 'success' : 'default'}
                              />
                            </TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </TableContainer>
                ) : (
                  <Typography>Серверы не найдены</Typography>
                )}
              </TabPanel>

              {/* Вкладка производительности */}
              <TabPanel value={tabValue} index={2}>
                {protocolPerformance ? (
                  <Grid container spacing={2}>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                            <Speed color="primary" />
                            <Typography variant="body2" color="textSecondary">Средняя скорость</Typography>
                          </Box>
                          <Typography variant="h5">{protocolPerformance.average_speed_mbps?.toFixed(2) || 0} Mbps</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                            <TrendingUp color="success" />
                            <Typography variant="body2" color="textSecondary">Средний ping</Typography>
                          </Box>
                          <Typography variant="h5">{protocolPerformance.average_ping_ms?.toFixed(1) || 0} ms</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                            <CheckCircle color="success" />
                            <Typography variant="body2" color="textSecondary">Процент успеха</Typography>
                          </Box>
                          <Typography variant="h5">{protocolPerformance.success_rate?.toFixed(1) || 0}%</Typography>
                          <LinearProgress 
                            variant="determinate" 
                            value={protocolPerformance.success_rate || 0}
                            sx={{ mt: 1 }}
                          />
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6} md={3}>
                      <Card variant="outlined">
                        <CardContent>
                          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                            <Info color="info" />
                            <Typography variant="body2" color="textSecondary">Всего подключений</Typography>
                          </Box>
                          <Typography variant="h5">{protocolPerformance.total_connections || 0}</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Всего трафика</Typography>
                          <Typography variant="h5">{protocolPerformance.total_traffic_gb?.toFixed(2) || 0} GB</Typography>
                        </CardContent>
                      </Card>
                    </Grid>
                    <Grid item xs={12} sm={6}>
                      <Card variant="outlined">
                        <CardContent>
                          <Typography variant="body2" color="textSecondary">Uptime</Typography>
                          <Typography variant="h5">{protocolPerformance.uptime_percentage?.toFixed(1) || 0}%</Typography>
                          <LinearProgress 
                            variant="determinate" 
                            value={protocolPerformance.uptime_percentage || 0}
                            color="success"
                            sx={{ mt: 1 }}
                          />
                        </CardContent>
                      </Card>
                    </Grid>
                  </Grid>
                ) : (
                  <Typography>Данные о производительности недоступны</Typography>
                )}
              </TabPanel>
            </Box>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDetailDialogOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default ProtocolsPage;
