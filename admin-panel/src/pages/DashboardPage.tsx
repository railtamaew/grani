import React, { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Box,
  Grid,
  Card,
  CardContent,
  Typography,
  CircularProgress,
  Alert,
  Button,
  Stack,
} from '@mui/material';
import {
  People,
  Dns,
  Payment,
  TrendingUp,
  Refresh,
  CheckCircle,
  Error as ErrorIcon,
} from '@mui/icons-material';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  PieChart,
  Pie,
  Cell,
  Legend,
} from 'recharts';

import { RootState } from '../store';
import { fetchDashboardStats } from '../store/slices/dashboardSlice';
import { dashboardService } from '../services/dashboardService';

const StatCard: React.FC<{
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: string;
}> = ({ title, value, icon, color }) => (
  <Card>
    <CardContent>
      <Box display="flex" alignItems="center" justifyContent="space-between">
        <Box>
          <Typography color="textSecondary" gutterBottom variant="body2">
            {title}
          </Typography>
          <Typography variant="h4" component="div">
            {value}
          </Typography>
        </Box>
        <Box
          sx={{
            color,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            width: 48,
            height: 48,
            borderRadius: '50%',
            backgroundColor: `${color}20`,
          }}
        >
          {icon}
        </Box>
      </Box>
    </CardContent>
  </Card>
);

const DashboardPage: React.FC = () => {
  const dispatch = useDispatch<any>();
  const { stats, loading, error } = useSelector((state: RootState) => state.dashboard);
  const [chartData, setChartData] = useState([
    { name: 'Пн', connections: 0 },
    { name: 'Вт', connections: 0 },
    { name: 'Ср', connections: 0 },
    { name: 'Чт', connections: 0 },
    { name: 'Пт', connections: 0 },
    { name: 'Сб', connections: 0 },
    { name: 'Вс', connections: 0 },
  ]);
  const [authProviderStats, setAuthProviderStats] = useState<{ name: string; value: number }[]>([]);
  const [loadAlerts, setLoadAlerts] = useState<any[]>([]);
  const [metrics, setMetrics] = useState<any>(null);
  const [diagnostics, setDiagnostics] = useState<{ api: any[]; xray_servers: any[] } | null>(null);
  const [monitoringError, setMonitoringError] = useState<string | null>(null);
  const authColors = ['#1976d2', '#2e7d32', '#ed6c02', '#9c27b0'];

  useEffect(() => {
    dispatch(fetchDashboardStats());
    loadChartData();
    loadAuthStats();
    loadLoadAlerts();
    loadMonitoring();
  }, [dispatch]);

  const loadChartData = async () => {
    try {
      // Получаем данные за последние 7 дней
      const logs = await dashboardService.getConnectionLogs({ limit: 1000 });
      
      // Группируем по дням недели
      const dayCounts: { [key: string]: number } = {
        'Пн': 0,
        'Вт': 0,
        'Ср': 0,
        'Чт': 0,
        'Пт': 0,
        'Сб': 0,
        'Вс': 0,
      };

      const dayNames = ['Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб'];
      
      logs.logs.forEach((log: any) => {
        if (log.connected_at) {
          const date = new Date(log.connected_at);
          const dayName = dayNames[date.getDay()];
          if (dayCounts.hasOwnProperty(dayName)) {
            dayCounts[dayName]++;
          }
        }
      });

      setChartData([
        { name: 'Пн', connections: dayCounts['Пн'] },
        { name: 'Вт', connections: dayCounts['Вт'] },
        { name: 'Ср', connections: dayCounts['Ср'] },
        { name: 'Чт', connections: dayCounts['Чт'] },
        { name: 'Пт', connections: dayCounts['Пт'] },
        { name: 'Сб', connections: dayCounts['Сб'] },
        { name: 'Вс', connections: dayCounts['Вс'] },
      ]);
    } catch (err) {
      console.error('Ошибка загрузки данных графика:', err);
    }
  };

  const loadAuthStats = async () => {
    try {
      const stats = await dashboardService.getAuthProviderStats();
      const data = Object.entries(stats.providers || {}).map(([name, value]) => ({
        name: name || 'unknown',
        value: Number(value),
      }));
      setAuthProviderStats(data);
    } catch (err) {
      console.error('Ошибка загрузки статистики провайдеров:', err);
    }
  };

  const loadLoadAlerts = async () => {
    try {
      const data = await dashboardService.getLoadAlerts(80);
      setLoadAlerts(data.alerts || []);
    } catch (err) {
      console.error('Ошибка загрузки алертов по нагрузке:', err);
    }
  };

  const loadMonitoring = async () => {
    setMonitoringError(null);
    try {
      const [metricsData, diagData] = await Promise.allSettled([
        dashboardService.getMetrics(),
        dashboardService.getDiagnosticsPing(),
      ]);
      if (metricsData.status === 'fulfilled') setMetrics(metricsData.value);
      else setMetrics(null);
      if (diagData.status === 'fulfilled') setDiagnostics(diagData.value);
      else setDiagnostics(null);
      if (metricsData.status === 'rejected' && diagData.status === 'rejected') {
        setMonitoringError('Метрики отключены или нет доступа');
      }
    } catch (err) {
      setMonitoringError('Ошибка загрузки мониторинга');
    }
  };

  const handleRefresh = () => {
    dispatch(fetchDashboardStats());
    loadChartData();
    loadAuthStats();
    loadLoadAlerts();
    loadMonitoring();
  };

  if (loading && !stats) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  if (error) {
    return (
      <Box>
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
        <Button onClick={handleRefresh} variant="contained">
          Попробовать снова
        </Button>
      </Box>
    );
  }

  return (
    <Box>
      <Box display="flex" justifyContent="space-between" alignItems="center" mb={3}>
        <Typography variant="h4" component="h1">
          Панель управления
        </Typography>
        <Button
          onClick={handleRefresh}
          startIcon={<Refresh />}
          variant="outlined"
          disabled={loading}
        >
          Обновить
        </Button>
      </Box>

      {stats && (
        <Grid container spacing={3} mb={4}>
          <Grid item xs={12} sm={6} md={3}>
            <StatCard
              title="Всего пользователей"
              value={stats.total_users}
              icon={<People />}
              color="#1976d2"
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <StatCard
              title="Активные подписки"
              value={stats.active_subscriptions}
              icon={<TrendingUp />}
              color="#2e7d32"
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <StatCard
              title="Общий доход"
              value={`${(stats.total_revenue / 1000).toFixed(0)}K ₽`}
              icon={<Payment />}
              color="#ed6c02"
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <StatCard
              title="Активные подключения"
              value={stats.active_connections}
              icon={<Dns />}
              color="#9c27b0"
            />
          </Grid>
        </Grid>
      )}

      <Grid container spacing={3}>
        <Grid item xs={12} md={8}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Активность подключений за неделю
              </Typography>
              <ResponsiveContainer width="100%" height={300}>
                <LineChart data={chartData}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="name" />
                  <YAxis />
                  <Tooltip />
                  <Line
                    type="monotone"
                    dataKey="connections"
                    stroke="#1976d2"
                    strokeWidth={2}
                  />
                </LineChart>
              </ResponsiveContainer>
            </CardContent>
          </Card>
        </Grid>
        
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Статус серверов
              </Typography>
              {stats && (
                <Box>
                  <Typography variant="body2" color="textSecondary">
                    Всего серверов: {stats.server_count}
                  </Typography>
                  <Typography variant="body2" color="textSecondary">
                    Активных подключений: {stats.active_connections}
                  </Typography>
                </Box>
              )}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Регистрация по провайдеру
              </Typography>
              {authProviderStats.length === 0 ? (
                <Typography variant="body2" color="textSecondary">Нет данных</Typography>
              ) : (
                <ResponsiveContainer width="100%" height={240}>
                  <PieChart>
                    <Pie data={authProviderStats} dataKey="value" nameKey="name" outerRadius={80}>
                      {authProviderStats.map((entry, index) => (
                        <Cell key={`cell-${entry.name}`} fill={authColors[index % authColors.length]} />
                      ))}
                    </Pie>
                    <Tooltip />
                    <Legend />
                  </PieChart>
                </ResponsiveContainer>
              )}
            </CardContent>
          </Card>
        </Grid>
        <Grid item xs={12} md={4}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Перегрузки серверов
              </Typography>
              {loadAlerts.length === 0 ? (
                <Typography variant="body2" color="textSecondary">
                  Нет предупреждений
                </Typography>
              ) : (
                <Box>
                  {loadAlerts.slice(0, 6).map((alert: any, idx: number) => (
                    <Typography key={`${alert.server_id}-${idx}`} variant="body2" color="textSecondary">
                      {alert.server_name || alert.server_id}: {alert.load_percentage?.toFixed?.(1) || alert.load_percentage}%
                    </Typography>
                  ))}
                </Box>
              )}
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12}>
          <Card>
            <CardContent>
              <Box display="flex" justifyContent="space-between" alignItems="center" mb={2}>
                <Typography variant="h6">
                  Мониторинг
                </Typography>
                <Button size="small" startIcon={<Refresh />} onClick={loadMonitoring}>
                  Обновить
                </Button>
              </Box>
              {monitoringError && (
                <Alert severity="info" sx={{ mb: 2 }}>{monitoringError}</Alert>
              )}
              <Grid container spacing={2}>
                {diagnostics && (
                  <Grid item xs={12} md={6}>
                    <Typography variant="subtitle2" color="textSecondary" gutterBottom>
                      Доступность API
                    </Typography>
                    {diagnostics.api?.length ? (
                      <Stack spacing={0.5}>
                        {diagnostics.api.map((p: any, i: number) => (
                          <Box key={i} display="flex" alignItems="center" gap={1}>
                            {p.ok ? <CheckCircle color="success" fontSize="small" /> : <ErrorIcon color="error" fontSize="small" />}
                            <Typography variant="body2">
                              {p.url?.replace(/^https?:\/\//, '').split('/')[0]}: {p.elapsed_ms} ms
                            </Typography>
                          </Box>
                        ))}
                      </Stack>
                    ) : (
                      <Typography variant="body2" color="textSecondary">Нет данных</Typography>
                    )}
                  </Grid>
                )}
                {diagnostics && (
                  <Grid item xs={12} md={6}>
                    <Typography variant="subtitle2" color="textSecondary" gutterBottom>
                      VPN-серверы
                    </Typography>
                    {diagnostics.xray_servers?.length ? (
                      <Stack spacing={0.5}>
                        {diagnostics.xray_servers.map((p: any, i: number) => (
                          <Box key={i} display="flex" alignItems="center" gap={1}>
                            {p.ok ? <CheckCircle color="success" fontSize="small" /> : <ErrorIcon color="error" fontSize="small" />}
                            <Typography variant="body2">
                              {p.name || p.host}:{p.port}{p.transport ? `/${String(p.transport).toUpperCase()}` : ''} — {p.elapsed_ms} ms
                            </Typography>
                          </Box>
                        ))}
                      </Stack>
                    ) : (
                      <Typography variant="body2" color="textSecondary">Нет данных</Typography>
                    )}
                  </Grid>
                )}
                {metrics && (
                  <Grid item xs={12} md={6}>
                    <Typography variant="subtitle2" color="textSecondary" gutterBottom>
                      Кэш Redis
                    </Typography>
                    <Typography variant="body2">
                      hits: {metrics?.cache?.hits ?? '—'}, misses: {metrics?.cache?.misses ?? '—'}
                    </Typography>
                  </Grid>
                )}
              </Grid>
            </CardContent>
          </Card>
        </Grid>
      </Grid>
    </Box>
  );
};

export default DashboardPage;
