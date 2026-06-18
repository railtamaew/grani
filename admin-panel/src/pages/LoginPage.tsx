import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useSelector } from 'react-redux';
import { 
  Container, 
  Paper, 
  TextField, 
  Button, 
  Typography, 
  Box,
  Alert,
  CircularProgress
} from '@mui/material';
import Logo from '../components/Logo';
import { useAppDispatch, RootState } from '../store';
import { loginUser, clearError } from '../store/slices/authSlice';

const LoginPage: React.FC = () => {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [blockedUntil, setBlockedUntil] = useState<Date | null>(null);
  
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  
  const { isLoading, error, isAuthenticated } = useSelector((state: RootState) => state.auth);

  useEffect(() => {
    if (isAuthenticated) {
      navigate('/dashboard');
    }
  }, [isAuthenticated, navigate]);

  useEffect(() => {
    // Проверяем сообщение об ошибке на наличие информации о блокировке
    if (error && error.includes('заблокирован')) {
      const match = error.match(/(\d+)\s*минут/);
      if (match) {
        const minutes = parseInt(match[1]);
        const blocked = new Date();
        blocked.setMinutes(blocked.getMinutes() + minutes);
        setBlockedUntil(blocked);
      }
    }
  }, [error]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    dispatch(clearError());
    setBlockedUntil(null);
    
    if (!email || !password) {
      return;
    }

    try {
      await dispatch(loginUser({ email, password })).unwrap();
      // navigate будет вызван автоматически через useEffect
    } catch (error: any) {
      // Ошибка уже обработана в slice
      console.error('Login failed:', error);
      // Проверяем на rate limiting
      if (error?.response?.status === 429) {
        const detail = error?.response?.data?.detail || error?.response?.data?.error?.message || error?.message || '';
        if (detail.includes('заблокирован')) {
          const match = detail.match(/(\d+)\s*минут/);
          if (match) {
            const minutes = parseInt(match[1]);
            const blocked = new Date();
            blocked.setMinutes(blocked.getMinutes() + minutes);
            setBlockedUntil(blocked);
          }
        }
      }
    }
  };

  const isBlocked = blockedUntil && blockedUntil > new Date();
  const minutesLeft = blockedUntil 
    ? Math.ceil((blockedUntil.getTime() - new Date().getTime()) / 60000)
    : 0;

  return (
    <Container component="main" maxWidth="xs">
      <Box
        sx={{
          marginTop: 8,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
        }}
      >
        <Paper
          elevation={3}
          sx={{
            padding: 4,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            width: '100%',
          }}
        >
          <Logo size="large" />
          
          <Typography variant="body2" color="text.secondary" sx={{ mb: 3, mt: 2 }}>
            Войдите в систему управления
          </Typography>

          {error && (
            <Alert 
              severity={error.includes('заблокирован') ? 'warning' : 'error'} 
              sx={{ width: '100%', mb: 2 }}
            >
              {error}
            </Alert>
          )}

          {isBlocked && (
            <Alert severity="warning" sx={{ width: '100%', mb: 2 }}>
              Аккаунт заблокирован. Попробуйте через {minutesLeft} минут.
            </Alert>
          )}

          <Box component="form" onSubmit={handleSubmit} sx={{ width: '100%' }}>
            <TextField
              margin="normal"
              required
              fullWidth
              id="email"
              label="Email"
              name="email"
              autoComplete="email"
              autoFocus
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              disabled={isLoading}
            />
            <TextField
              margin="normal"
              required
              fullWidth
              name="password"
              label="Пароль"
              type="password"
              id="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              disabled={isLoading}
            />
            <Button
              type="submit"
              fullWidth
              variant="contained"
              sx={{ mt: 3, mb: 2 }}
              disabled={isLoading || !email || !password}
            >
              {isLoading ? (
                <CircularProgress size={24} color="inherit" />
              ) : (
                'Войти'
              )}
            </Button>
          </Box>
        </Paper>
      </Box>
    </Container>
  );
};

export default LoginPage;
