import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Grid,
  MenuItem,
  Paper,
  TextField,
  Typography,
} from '@mui/material';
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';
import {
  observabilityService,
  ProductTimelinePoint,
  ProductTimelineResponse,
} from '../services/observabilityService';

type Grain = 'minute' | 'hour' | 'day';

const toInputDateTime = (date: Date): string => {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
};

const formatBucket = (bucket: string, grain: Grain): string => {
  const date = new Date(bucket);
  if (Number.isNaN(date.getTime())) return bucket;
  if (grain === 'day') return date.toLocaleDateString('ru-RU');
  return date.toLocaleString('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
};

const MetricCard = ({ label, value }: { label: string; value: number }) => (
  <Paper sx={{ p: 2, height: '100%' }}>
    <Typography variant="body2" color="textSecondary">
      {label}
    </Typography>
    <Typography variant="h5" sx={{ mt: 0.5 }}>
      {value}
    </Typography>
  </Paper>
);

const ProductTimelinePage: React.FC = () => {
  const now = useMemo(() => new Date(), []);
  const [grain, setGrain] = useState<Grain>('hour');
  const [fromTime, setFromTime] = useState(
    toInputDateTime(new Date(now.getTime() - 24 * 60 * 60 * 1000))
  );
  const [toTime, setToTime] = useState(toInputDateTime(now));
  const [data, setData] = useState<ProductTimelineResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadTimeline = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await observabilityService.getProductTimeline({
        from_time: new Date(fromTime).toISOString(),
        to_time: new Date(toTime).toISOString(),
        grain,
      });
      setData(response);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки графика');
      setData(null);
    } finally {
      setLoading(false);
    }
  }, [fromTime, grain, toTime]);

  useEffect(() => {
    loadTimeline();
  }, [loadTimeline]);

  const chartData = useMemo(
    () =>
      (data?.items || []).map((item: ProductTimelinePoint) => ({
        ...item,
        label: formatBucket(item.bucket, grain),
      })),
    [data, grain]
  );

  const setPreset = (hours: number, nextGrain: Grain) => {
    const end = new Date();
    const start = new Date(end.getTime() - hours * 60 * 60 * 1000);
    setFromTime(toInputDateTime(start));
    setToTime(toInputDateTime(end));
    setGrain(nextGrain);
  };

  const totals = data?.totals;

  return (
    <Box>
      <PageHeader
        title="График продукта"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={() => setPreset(1, 'minute')}>
              1 час
            </Button>
            <Button variant="outlined" onClick={() => setPreset(24, 'hour')}>
              24 часа
            </Button>
            <Button variant="outlined" onClick={() => setPreset(24 * 7, 'day')}>
              7 дней
            </Button>
            <Button variant="contained" onClick={loadTimeline} disabled={loading}>
              Обновить
            </Button>
          </Box>
        )}
      />
      <Typography variant="body2" color="textSecondary" sx={{ mt: -2, mb: 3 }}>
        Временная шкала попыток подключения, успешных подключений, подтверждённого трафика, технических verify warning, авторизаций и платежей.
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <FilterCard>
        <Grid container spacing={2}>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="С"
              type="datetime-local"
              value={fromTime}
              onChange={(e) => setFromTime(e.target.value)}
              size="small"
              fullWidth
              InputLabelProps={{ shrink: true }}
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              label="По"
              type="datetime-local"
              value={toTime}
              onChange={(e) => setToTime(e.target.value)}
              size="small"
              fullWidth
              InputLabelProps={{ shrink: true }}
            />
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <TextField
              select
              label="Шаг"
              value={grain}
              onChange={(e) => setGrain(e.target.value as Grain)}
              size="small"
              fullWidth
            >
              <MenuItem value="minute">Минуты</MenuItem>
              <MenuItem value="hour">Часы</MenuItem>
              <MenuItem value="day">Даты</MenuItem>
            </TextField>
          </Grid>
          <Grid item xs={12} sm={6} md={3}>
            <Button
              variant="contained"
              onClick={loadTimeline}
              disabled={loading}
              fullWidth
              sx={{ height: 40 }}
            >
              Построить
            </Button>
          </Grid>
        </Grid>
      </FilterCard>

      {totals && (
        <Grid container spacing={2} sx={{ mb: 3 }}>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Попытки подключения" value={totals.connection_attempts} />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Успешные подключения" value={totals.connection_success} />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Трафик подтвержден" value={totals.traffic_confirmed} />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Ошибки VPN" value={totals.connection_errors} />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Verify warning" value={totals.verify_warnings} />
          </Grid>
          <Grid item xs={12} sm={6} md={2}>
            <MetricCard label="Платежи успешные" value={totals.payments_completed} />
          </Grid>
        </Grid>
      )}

      <Paper sx={{ p: 2 }}>
        <Box sx={{ width: '100%', height: 460 }}>
          <ResponsiveContainer>
            <LineChart data={chartData} margin={{ top: 16, right: 24, left: 0, bottom: 16 }}>
              <CartesianGrid strokeDasharray="3 3" />
              <XAxis dataKey="label" minTickGap={24} />
              <YAxis allowDecimals={false} />
              <Tooltip />
              <Legend />
              <Line type="monotone" dataKey="connection_attempts" name="Попытки VPN" stroke="#182D3D" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="connection_success" name="Подключено" stroke="#2E7D5B" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="traffic_confirmed" name="Трафик подтвержден" stroke="#F28C28" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="connection_errors" name="Ошибки VPN" stroke="#B3261E" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="verify_warnings" name="Verify warning" stroke="#A67C00" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="new_users" name="Новые пользователи" stroke="#5271A3" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="login_seen" name="Авторизации" stroke="#7A5CA8" strokeWidth={2} dot={false} />
              <Line type="monotone" dataKey="payments_completed" name="Оплаты" stroke="#0B8F73" strokeWidth={2} dot={false} />
            </LineChart>
          </ResponsiveContainer>
        </Box>
      </Paper>

      {data?.notes?.login_seen && (
        <Alert severity="info" sx={{ mt: 2 }}>
          Авторизации сейчас считаются по `users.last_login_at`, это приближённый сигнал. Для полной истории входов нужен отдельный лог auth-событий.
        </Alert>
      )}
    </Box>
  );
};

export default ProductTimelinePage;
