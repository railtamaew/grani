import React, { useCallback, useEffect, useState } from 'react';
import {
  Box,
  Typography,
  Tabs,
  Tab,
  Card,
  CardContent,
  TextField,
  Button,
  Switch,
  FormControlLabel,
  Grid,
  Alert,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Paper,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  MenuItem,
} from '@mui/material';
import { settingsService, SystemSettings, AdminUser } from '../services/settingsService';

interface TabPanelProps {
  value: number;
  index: number;
  children: React.ReactNode;
}

const TabPanel: React.FC<TabPanelProps> = ({ value, index, children }) => {
  if (value !== index) return null;
  return <Box sx={{ pt: 2 }}>{children}</Box>;
};

const SettingsPage: React.FC = () => {
  const [tab, setTab] = useState(0);
  const [settings, setSettings] = useState<SystemSettings | null>(null);
  const [admins, setAdmins] = useState<AdminUser[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [createDialogOpen, setCreateDialogOpen] = useState(false);
  const [newAdmin, setNewAdmin] = useState({ email: '', password: '', role: 'admin' });
  const [passwordForm, setPasswordForm] = useState({ current: '', new: '', confirm: '' });
  const [passwordSaving, setPasswordSaving] = useState(false);
  const [passwordSuccess, setPasswordSuccess] = useState<string | null>(null);

  const getErrorMessage = useCallback((err: any, fallback: string) =>
    err?.normalized?.message ||
    err?.response?.data?.detail ||
    err?.response?.data?.error?.message ||
    fallback, []);

  const loadSettings = useCallback(async () => {
    try {
      const data = await settingsService.getSettings();
      setSettings(data);
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка загрузки настроек'));
    }
  }, [getErrorMessage]);

  const loadAdmins = useCallback(async () => {
    try {
      const data = await settingsService.getAdmins();
      setAdmins(data);
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка загрузки администраторов'));
    }
  }, [getErrorMessage]);

  useEffect(() => {
    loadSettings();
    loadAdmins();
  }, [loadSettings, loadAdmins]);

  const handleSave = async () => {
    if (!settings) return;
    setSaving(true);
    try {
      await settingsService.updateSettings({
        feature_flags: settings.feature_flags_override || {},
        min_versions: settings.min_versions_override || {},
      });
      await loadSettings();
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка сохранения настроек'));
    } finally {
      setSaving(false);
    }
  };

  const handleAdminUpdate = async (adminId: number, payload: { role?: string; is_active?: boolean }) => {
    try {
      const updated = await settingsService.updateAdmin(adminId, payload);
      setAdmins((prev) => prev.map((a) => (a.id === updated.id ? updated : a)));
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка обновления администратора'));
    }
  };

  const handleCreateAdmin = async () => {
    try {
      const created = await settingsService.createAdmin(newAdmin);
      setAdmins((prev) => [created, ...prev]);
      setCreateDialogOpen(false);
      setNewAdmin({ email: '', password: '', role: 'admin' });
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка создания администратора'));
    }
  };

  const handleChangePassword = async () => {
    if (passwordForm.new !== passwordForm.confirm) {
      setError('Новый пароль и подтверждение не совпадают');
      return;
    }
    if (passwordForm.new.length < 8 || passwordForm.new.length > 64) {
      setError('Пароль должен содержать от 8 до 64 символов');
      return;
    }
    setPasswordSaving(true);
    setError(null);
    setPasswordSuccess(null);
    try {
      await settingsService.changePassword(passwordForm.current, passwordForm.new);
      setPasswordSuccess('Пароль успешно изменён');
      setPasswordForm({ current: '', new: '', confirm: '' });
    } catch (err: any) {
      setError(getErrorMessage(err, 'Ошибка смены пароля'));
    } finally {
      setPasswordSaving(false);
    }
  };

  return (
    <Box>
      <Typography variant="h4" gutterBottom>
        Настройки
      </Typography>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Tabs value={tab} onChange={(_, value) => setTab(value)}>
        <Tab label="Feature Flags" />
        <Tab label="Минимальные версии" />
        <Tab label="Администраторы" />
        <Tab label="Мой пароль" />
      </Tabs>

      <TabPanel value={tab} index={0}>
        {settings ? (
          <Card>
            <CardContent>
              <Typography variant="subtitle2" color="textSecondary" gutterBottom>
                Overrides (применяются поверх вычисленных флагов)
              </Typography>
              <Grid container spacing={2}>
                {Object.keys(settings.feature_flags).map((key) => (
                  <Grid item xs={12} sm={6} md={4} key={key}>
                    <FormControlLabel
                      control={
                        <Switch
                          checked={!!(settings.feature_flags_override || {})[key]}
                          onChange={(e) =>
                            setSettings({
                              ...settings,
                              feature_flags_override: {
                                ...(settings.feature_flags_override || {}),
                                [key]: e.target.checked,
                              },
                            })
                          }
                        />
                      }
                      label={`${key} (base: ${settings.feature_flags[key] ? 'on' : 'off'})`}
                    />
                  </Grid>
                ))}
              </Grid>
              <Box sx={{ mt: 2 }}>
                <Button variant="contained" onClick={handleSave} disabled={saving}>
                  Сохранить overrides
                </Button>
              </Box>
            </CardContent>
          </Card>
        ) : (
          <Typography>Загрузка...</Typography>
        )}
      </TabPanel>

      <TabPanel value={tab} index={1}>
        {settings ? (
          <Card>
            <CardContent>
              <Typography variant="subtitle2" color="textSecondary" gutterBottom>
                Overrides минимальных версий
              </Typography>
              <Grid container spacing={2}>
                {Object.keys(settings.min_versions).map((platform) => (
                  <Grid item xs={12} sm={6} md={4} key={platform}>
                    <TextField
                      label={`${platform} (base: ${settings.min_versions[platform]})`}
                      value={(settings.min_versions_override || {})[platform] || ''}
                      onChange={(e) =>
                        setSettings({
                          ...settings,
                          min_versions_override: {
                            ...(settings.min_versions_override || {}),
                            [platform]: e.target.value,
                          },
                        })
                      }
                      fullWidth
                      size="small"
                    />
                  </Grid>
                ))}
              </Grid>
              <Box sx={{ mt: 2 }}>
                <Button variant="contained" onClick={handleSave} disabled={saving}>
                  Сохранить overrides
                </Button>
              </Box>
            </CardContent>
          </Card>
        ) : (
          <Typography>Загрузка...</Typography>
        )}
      </TabPanel>

      <TabPanel value={tab} index={2}>
        <Box display="flex" justifyContent="flex-end" mb={2}>
          <Button variant="contained" onClick={() => setCreateDialogOpen(true)}>
            Добавить администратора
          </Button>
        </Box>
        <TableContainer component={Paper}>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>ID</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>Роль</TableCell>
                <TableCell>Активен</TableCell>
                <TableCell>Последний вход</TableCell>
                <TableCell>Действия</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {admins.map((admin) => (
                <TableRow key={admin.id}>
                  <TableCell>{admin.id}</TableCell>
                  <TableCell>{admin.email}</TableCell>
                  <TableCell>
                    <TextField
                      select
                      size="small"
                      value={admin.role}
                      onChange={(e) => handleAdminUpdate(admin.id, { role: e.target.value })}
                    >
                      <MenuItem value="owner">owner</MenuItem>
                      <MenuItem value="admin">admin</MenuItem>
                      <MenuItem value="support">support</MenuItem>
                      <MenuItem value="read_only">read_only</MenuItem>
                    </TextField>
                  </TableCell>
                  <TableCell>
                    <Switch
                      checked={admin.is_active}
                      onChange={(e) => handleAdminUpdate(admin.id, { is_active: e.target.checked })}
                    />
                  </TableCell>
                  <TableCell>{admin.last_login_at ? new Date(admin.last_login_at).toLocaleString('ru-RU') : '-'}</TableCell>
                  <TableCell>-</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      </TabPanel>

      <TabPanel value={tab} index={3}>
        <Card>
          <CardContent>
            <Typography variant="subtitle1" gutterBottom>
              Сменить пароль
            </Typography>
            {passwordSuccess && (
              <Alert severity="success" sx={{ mb: 2 }} onClose={() => setPasswordSuccess(null)}>
                {passwordSuccess}
              </Alert>
            )}
            <TextField
              fullWidth
              label="Текущий пароль"
              type="password"
              value={passwordForm.current}
              onChange={(e) => setPasswordForm((p) => ({ ...p, current: e.target.value }))}
              margin="normal"
              size="small"
            />
            <TextField
              fullWidth
              label="Новый пароль"
              type="password"
              value={passwordForm.new}
              onChange={(e) => setPasswordForm((p) => ({ ...p, new: e.target.value }))}
              margin="normal"
              size="small"
              helperText="От 8 до 64 символов"
            />
            <TextField
              fullWidth
              label="Подтвердите новый пароль"
              type="password"
              value={passwordForm.confirm}
              onChange={(e) => setPasswordForm((p) => ({ ...p, confirm: e.target.value }))}
              margin="normal"
              size="small"
            />
            <Box sx={{ mt: 2 }}>
              <Button
                variant="contained"
                onClick={handleChangePassword}
                disabled={passwordSaving || !passwordForm.current || !passwordForm.new || !passwordForm.confirm}
              >
                {passwordSaving ? 'Сохранение...' : 'Изменить пароль'}
              </Button>
            </Box>
          </CardContent>
        </Card>
      </TabPanel>

      <Dialog open={createDialogOpen} onClose={() => setCreateDialogOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle>Новый администратор</DialogTitle>
        <DialogContent>
          <TextField
            label="Email"
            value={newAdmin.email}
            onChange={(e) => setNewAdmin({ ...newAdmin, email: e.target.value })}
            fullWidth
            margin="normal"
          />
          <TextField
            label="Пароль"
            type="password"
            value={newAdmin.password}
            onChange={(e) => setNewAdmin({ ...newAdmin, password: e.target.value })}
            fullWidth
            margin="normal"
          />
          <TextField
            label="Роль"
            select
            value={newAdmin.role}
            onChange={(e) => setNewAdmin({ ...newAdmin, role: e.target.value })}
            fullWidth
            margin="normal"
          >
            <MenuItem value="owner">owner</MenuItem>
            <MenuItem value="admin">admin</MenuItem>
            <MenuItem value="support">support</MenuItem>
            <MenuItem value="read_only">read_only</MenuItem>
          </TextField>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setCreateDialogOpen(false)}>Отмена</Button>
          <Button onClick={handleCreateAdmin} variant="contained">
            Создать
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default SettingsPage;



