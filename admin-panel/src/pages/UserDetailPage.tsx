import React, { useCallback, useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import {
  Box,
  Typography,
  Card,
  CardContent,
  Tabs,
  Tab,
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
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Alert,
  CircularProgress,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Grid,
} from '@mui/material';
import {
  ArrowBack,
  Edit,
  Delete,
  Block,
  CheckCircle,
  Add,
  Refresh,
} from '@mui/icons-material';
import { usersService } from '../services/usersService';
import { api } from '../services/api';
import UserDiagnosticsView from '../components/UserDiagnosticsView';

const UserEventsTab: React.FC<{ userId: number }> = ({ userId }) => {
  const [events, setEvents] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  const loadEvents = useCallback(async () => {
    try {
      setLoading(true);
      const data = await usersService.getUserEvents(userId);
      setEvents(data);
    } catch (err) {
      console.error('Ошибка загрузки событий:', err);
    } finally {
      setLoading(false);
    }
  }, [userId]);

  useEffect(() => {
    loadEvents();
  }, [loadEvents]);

  const formatDate = (dateString: string | null) => {
    if (!dateString) return '-';
    return new Date(dateString).toLocaleString('ru-RU');
  };

  if (loading) {
    return <CircularProgress />;
  }

  if (!events) {
    return <Typography>Нет данных</Typography>;
  }

  return (
    <Box>
      <Typography variant="h6" gutterBottom>События телеметрии</Typography>
      <TableContainer component={Paper} sx={{ mb: 3 }}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>ID</TableCell>
              <TableCell>Тип</TableCell>
              <TableCell>Протокол</TableCell>
              <TableCell>Ошибка</TableCell>
              <TableCell>Время</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {events.telemetry_events?.map((e: any) => (
              <TableRow key={e.id}>
                <TableCell>{e.id}</TableCell>
                <TableCell>{e.event_type}</TableCell>
                <TableCell>{e.protocol_code || '-'}</TableCell>
                <TableCell>
                  {e.error_code ? (
                    <Chip label={e.error_code} color="error" size="small" />
                  ) : (
                    '-'
                  )}
                </TableCell>
                <TableCell>{formatDate(e.timestamp)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>

      <Typography variant="h6" gutterBottom>История подключений</Typography>
      <TableContainer component={Paper}>
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>ID</TableCell>
              <TableCell>Сервер</TableCell>
              <TableCell>Тип</TableCell>
              <TableCell>IP</TableCell>
              <TableCell>Подключен</TableCell>
              <TableCell>Отключен</TableCell>
              <TableCell>Длительность</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {events.connection_logs?.map((log: any) => (
              <TableRow key={log.id}>
                <TableCell>{log.id}</TableCell>
                <TableCell>{log.server_id}</TableCell>
                <TableCell>{log.connection_type}</TableCell>
                <TableCell>{log.ip_address || '-'}</TableCell>
                <TableCell>{formatDate(log.connected_at)}</TableCell>
                <TableCell>{formatDate(log.disconnected_at)}</TableCell>
                <TableCell>
                  {log.duration_seconds ? `${Math.round(log.duration_seconds / 60)} мин` : '-'}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
    </Box>
  );
};

interface TabPanelProps {
  children?: React.ReactNode;
  index: number;
  value: number;
}

function TabPanel(props: TabPanelProps) {
  const { children, value, index, ...other } = props;
  return (
    <div role="tabpanel" hidden={value !== index} {...other}>
      {value === index && <Box sx={{ p: 3 }}>{children}</Box>}
    </div>
  );
}

const UserDetailPage: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  
  const [user, setUser] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tabValue, setTabValue] = useState(0);
  const [editDialogOpen, setEditDialogOpen] = useState(false);
  const [subscriptionDialogOpen, setSubscriptionDialogOpen] = useState(false);
  const [trialDialogOpen, setTrialDialogOpen] = useState(false);
  const [editForm, setEditForm] = useState({ email: '', notes: '' });
  const [subscriptionForm, setSubscriptionForm] = useState({ plan_id: '', end_date: '', reason: '' });
  const [trialMinutes, setTrialMinutes] = useState(24 * 60);
  const [plans, setPlans] = useState<any[]>([]);

  const loadUser = useCallback(async () => {
    if (!id) return;
    try {
      setLoading(true);
      const response = await usersService.getUser(Number(id));
      setUser(response);
      setEditForm({ email: response.email || '', notes: response.notes || '' });
    } catch (err: any) {
      setError(err?.response?.data?.error?.message || err?.response?.data?.message || 'Ошибка загрузки пользователя');
    } finally {
      setLoading(false);
    }
  }, [id]);

  const loadPlans = useCallback(async () => {
    try {
      const response = await api.get('/api/admin/plans');
      setPlans(response.data || []);
    } catch (err) {
      console.error('Ошибка загрузки тарифов:', err);
    }
  }, []);

  useEffect(() => {
    if (id) {
      loadUser();
      loadPlans();
    }
  }, [id, loadPlans, loadUser]);

  const handleEdit = async () => {
    try {
      await usersService.updateUser(Number(id), {
        email: editForm.email,
        notes: editForm.notes,
      });
      setEditDialogOpen(false);
      loadUser();
    } catch (err: any) {
      setError(err?.response?.data?.error?.message || err?.response?.data?.message || 'Ошибка обновления');
    }
  };

  const handleCreateSubscription = async () => {
    try {
      await api.post(`/api/admin/users/${id}/subscription`, {
        plan_id: Number(subscriptionForm.plan_id),
        end_date: subscriptionForm.end_date,
        reason: subscriptionForm.reason,
      });
      setSubscriptionDialogOpen(false);
      setSubscriptionForm({ plan_id: '', end_date: '', reason: '' });
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка создания подписки');
    }
  };

  const handleSetTrial = async () => {
    try {
      await api.post(`/api/admin/users/${id}/trial`, {
        duration_minutes: trialMinutes,
      });
      setTrialDialogOpen(false);
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка установки trial');
    }
  };

  const handleBlock = async () => {
    try {
      await usersService.blockUser(Number(id));
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка блокировки');
    }
  };

  const handleUnblock = async () => {
    try {
      await usersService.unblockUser(Number(id));
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка разблокировки');
    }
  };

  const handleDeleteDevice = async (deviceId: number) => {
    if (!window.confirm('Удалить устройство?')) return;
    setError(null);
    try {
      await api.delete(`/api/admin/devices/${deviceId}`);
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка удаления устройства');
    }
  };

  const handleResetDevices = async () => {
    if (!window.confirm('Сбросить все устройства?')) return;
    try {
      await api.post(`/api/admin/users/${id}/devices/reset`);
      loadUser();
    } catch (err: any) {
      setError(err.response?.data?.message || 'Ошибка сброса устройств');
    }
  };

  const formatDate = (dateString: string | null) => {
    if (!dateString) return '-';
    return new Date(dateString).toLocaleString('ru-RU');
  };

  if (loading && !user) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  if (error && !user) {
    return (
      <Box>
        <Alert severity="error">{error}</Alert>
        <Button onClick={() => navigate('/users')} sx={{ mt: 2 }}>
          Вернуться к списку
        </Button>
      </Box>
    );
  }

  if (!user) return null;

  return (
    <Box>
      <Box display="flex" alignItems="center" gap={2} mb={3}>
        <IconButton onClick={() => navigate('/users')}>
          <ArrowBack />
        </IconButton>
        <Typography variant="h4" component="h1">
          Пользователь: {user.email}
        </Typography>
        <Box flexGrow={1} />
        <Button
          variant="outlined"
          startIcon={<Refresh />}
          onClick={loadUser}
        >
          Обновить
        </Button>
        {user.is_active ? (
          <Button
            variant="outlined"
            color="error"
            startIcon={<Block />}
            onClick={handleBlock}
          >
            Заблокировать
          </Button>
        ) : (
          <Button
            variant="outlined"
            color="success"
            startIcon={<CheckCircle />}
            onClick={handleUnblock}
          >
            Разблокировать
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 3 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Grid container spacing={2}>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">ID</Typography>
              <Typography variant="body1">{user.id}</Typography>
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Email</Typography>
              <Typography variant="body1">{user.email}</Typography>
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Статус</Typography>
              <Chip
                label={user.is_active ? 'Активен' : 'Заблокирован'}
                color={user.is_active ? 'success' : 'error'}
                size="small"
              />
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Подтвержден</Typography>
              <Chip
                label={user.is_verified ? 'Да' : 'Нет'}
                color={user.is_verified ? 'success' : 'default'}
                size="small"
              />
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Страна</Typography>
              <Typography variant="body1">{user.country || '-'}</Typography>
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Auth Provider</Typography>
              <Typography variant="body1">{user.auth_provider || 'email'}</Typography>
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Дата регистрации</Typography>
              <Typography variant="body1">{formatDate(user.created_at)}</Typography>
            </Grid>
            <Grid item xs={12} md={6}>
              <Typography variant="body2" color="textSecondary">Последний визит</Typography>
              <Typography variant="body1">{formatDate(user.last_seen_at)}</Typography>
            </Grid>
            {user.notes && (
              <Grid item xs={12}>
                <Typography variant="body2" color="textSecondary">Заметки</Typography>
                <Typography variant="body1">{user.notes}</Typography>
              </Grid>
            )}
          </Grid>
        </CardContent>
      </Card>

      <Card>
        <Box sx={{ borderBottom: 1, borderColor: 'divider' }}>
          <Tabs value={tabValue} onChange={(e, newValue) => setTabValue(newValue)}>
            <Tab label="Основное" />
            <Tab label="Подписки" />
            <Tab label="Устройства" />
            <Tab label="История" />
            <Tab label="Диагностика" />
          </Tabs>
        </Box>

        <TabPanel value={tabValue} index={0}>
          <Box>
            <Button
              variant="contained"
              startIcon={<Edit />}
              onClick={() => setEditDialogOpen(true)}
              sx={{ mb: 2 }}
            >
              Редактировать
            </Button>
            <Button
              variant="outlined"
              startIcon={<Add />}
              onClick={() => setSubscriptionDialogOpen(true)}
              sx={{ mb: 2, ml: 2 }}
            >
              Создать подписку
            </Button>
            <Button
              variant="outlined"
              onClick={() => setTrialDialogOpen(true)}
              sx={{ mb: 2, ml: 2 }}
            >
              Установить Trial
            </Button>
          </Box>
        </TabPanel>

        <TabPanel value={tabValue} index={1}>
          <Box>
            <Button
              variant="contained"
              startIcon={<Add />}
              onClick={() => setSubscriptionDialogOpen(true)}
              sx={{ mb: 2 }}
            >
              Создать подписку
            </Button>
            {user.current_subscription && (
              <Card sx={{ mb: 2 }}>
                <CardContent>
                  <Typography variant="h6">Текущая подписка</Typography>
                  <Typography>Статус: {user.current_subscription.status}</Typography>
                  <Typography>До: {formatDate(user.current_subscription.end_date)}</Typography>
                </CardContent>
              </Card>
            )}
            <TableContainer component={Paper}>
              <Table>
                <TableHead>
                  <TableRow>
                    <TableCell>ID</TableCell>
                    <TableCell>План</TableCell>
                    <TableCell>Статус</TableCell>
                    <TableCell>Начало</TableCell>
                    <TableCell>Конец</TableCell>
                    <TableCell>Источник</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {user.subscriptions?.map((sub: any) => (
                    <TableRow key={sub.id}>
                      <TableCell>{sub.id}</TableCell>
                      <TableCell>{sub.plan_id}</TableCell>
                      <TableCell>
                        <Chip
                          label={sub.status}
                          color={sub.status === 'active' ? 'success' : 'default'}
                          size="small"
                        />
                      </TableCell>
                      <TableCell>{formatDate(sub.start_date)}</TableCell>
                      <TableCell>{formatDate(sub.end_date)}</TableCell>
                      <TableCell>{sub.source || '-'}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        </TabPanel>

        <TabPanel value={tabValue} index={2}>
          <Box>
            <Button
              variant="outlined"
              color="error"
              onClick={handleResetDevices}
              sx={{ mb: 2 }}
            >
              Сбросить все устройства
            </Button>
            <TableContainer component={Paper}>
              <Table>
                <TableHead>
                  <TableRow>
                    <TableCell>ID</TableCell>
                    <TableCell>Название</TableCell>
                    <TableCell>Платформа</TableCell>
                    <TableCell>Модель</TableCell>
                    <TableCell>Версия ОС</TableCell>
                    <TableCell>Версия приложения</TableCell>
                    <TableCell>Последний IP</TableCell>
                    <TableCell>Последнее подключение</TableCell>
                    <TableCell>Статус</TableCell>
                    <TableCell>Действия</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {user.devices?.map((device: any) => (
                    <TableRow key={device.id}>
                      <TableCell>{device.id}</TableCell>
                      <TableCell>{device.device_name || '-'}</TableCell>
                      <TableCell>{device.platform || '-'}</TableCell>
                      <TableCell>{device.model || '-'}</TableCell>
                      <TableCell>{device.os_version || '-'}</TableCell>
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
                        <IconButton
                          size="small"
                          color="error"
                          onClick={() => handleDeleteDevice(device.id)}
                        >
                          <Delete />
                        </IconButton>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        </TabPanel>

        <TabPanel value={tabValue} index={3}>
          <UserEventsTab userId={Number(id)} />
        </TabPanel>
        <TabPanel value={tabValue} index={4}>
          <UserDiagnosticsView userId={Number(id)} showTitle={false} />
        </TabPanel>
      </Card>

      {/* Диалог редактирования */}
      <Dialog open={editDialogOpen} onClose={() => setEditDialogOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Редактировать пользователя</DialogTitle>
        <DialogContent>
          <TextField
            label="Email"
            value={editForm.email}
            onChange={(e) => setEditForm({ ...editForm, email: e.target.value })}
            fullWidth
            margin="normal"
          />
          <TextField
            label="Заметки"
            value={editForm.notes}
            onChange={(e) => setEditForm({ ...editForm, notes: e.target.value })}
            fullWidth
            margin="normal"
            multiline
            rows={4}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditDialogOpen(false)}>Отмена</Button>
          <Button onClick={handleEdit} variant="contained">Сохранить</Button>
        </DialogActions>
      </Dialog>

      {/* Диалог создания подписки */}
      <Dialog open={subscriptionDialogOpen} onClose={() => setSubscriptionDialogOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Создать подписку</DialogTitle>
        <DialogContent>
          <FormControl fullWidth margin="normal">
            <InputLabel>Тариф</InputLabel>
            <Select
              value={subscriptionForm.plan_id}
              label="Тариф"
              onChange={(e) => setSubscriptionForm({ ...subscriptionForm, plan_id: e.target.value })}
            >
              {plans.map((plan) => (
                <MenuItem key={plan.id} value={plan.id}>
                  {plan.name} - {plan.price}₽
                </MenuItem>
              ))}
            </Select>
          </FormControl>
          <TextField
            label="Дата окончания"
            type="datetime-local"
            value={subscriptionForm.end_date}
            onChange={(e) => setSubscriptionForm({ ...subscriptionForm, end_date: e.target.value })}
            fullWidth
            margin="normal"
            InputLabelProps={{ shrink: true }}
          />
          <TextField
            label="Причина"
            value={subscriptionForm.reason}
            onChange={(e) => setSubscriptionForm({ ...subscriptionForm, reason: e.target.value })}
            fullWidth
            margin="normal"
            multiline
            rows={3}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setSubscriptionDialogOpen(false)}>Отмена</Button>
          <Button onClick={handleCreateSubscription} variant="contained">Создать</Button>
        </DialogActions>
      </Dialog>

      {/* Диалог установки trial */}
      <Dialog open={trialDialogOpen} onClose={() => setTrialDialogOpen(false)} maxWidth="xs" fullWidth>
        <DialogTitle>Установить Trial</DialogTitle>
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
          <Button onClick={() => setTrialDialogOpen(false)}>Отмена</Button>
          <Button onClick={handleSetTrial} variant="contained">Установить</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default UserDetailPage;
