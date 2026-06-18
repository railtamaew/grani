import React, { useState } from 'react';
import {
  Box,
  Card,
  CardContent,
  Typography,
  Button,
  TextField,
  Alert,
  CircularProgress,
  Grid,
  Divider,
} from '@mui/material';
import { api } from '../services/api';

interface ApiResponse {
  success: boolean;
  data?: any;
  error?: string;
}

const ApiTester: React.FC = () => {
  const [responses, setResponses] = useState<Record<string, ApiResponse>>({});
  const [loading, setLoading] = useState<Record<string, boolean>>({});
  const [testEmail, setTestEmail] = useState('rail.tamaew@gmail.com');
  const [testPassword, setTestPassword] = useState('ChangeThisPassword123!');

  const testEndpoint = async (name: string, method: string, url: string, data?: any) => {
    setLoading(prev => ({ ...prev, [name]: true }));
    
    try {
      let response: any;
      let responseData: any;
      if (method === 'GET') {
        response = await api.get(url);
        responseData = response.data;
      } else if (method === 'POST') {
        response = await api.post(url, data);
        responseData = response.data;
      }
      
      setResponses(prev => ({
        ...prev,
        [name]: { success: true, data: responseData }
      }));
      return responseData;
    } catch (error: any) {
      setResponses(prev => ({
        ...prev,
        [name]: { 
          success: false, 
          error: error.response?.data?.detail || error.message 
        }
      }));
      return null;
    } finally {
      setLoading(prev => ({ ...prev, [name]: false }));
    }
  };

  const testAuth = async () => {
    const data = await testEndpoint(
      'auth',
      'POST',
      '/api/auth/login',
      { email: testEmail, password: testPassword }
    );
    
    // Если авторизация успешна, сохраняем токен
    if (data?.access_token) {
      localStorage.setItem('token', data.access_token);
    }
  };

  const clearResponses = () => {
    setResponses({});
  };

  return (
    <Box>
      <Typography variant="h5" gutterBottom>
        Тестирование API
      </Typography>
      
      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Typography variant="h6" gutterBottom>
            Тестовые данные
          </Typography>
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Email"
                value={testEmail}
                onChange={(e) => setTestEmail(e.target.value)}
                size="small"
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Пароль"
                type="password"
                value={testPassword}
                onChange={(e) => setTestPassword(e.target.value)}
                size="small"
              />
            </Grid>
          </Grid>
        </CardContent>
      </Card>

      <Grid container spacing={2}>
        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Основные endpoints
              </Typography>
              
              <Box display="flex" flexDirection="column" gap={2}>
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('health', 'GET', '/health')}
                  disabled={loading.health}
                >
                  {loading.health ? <CircularProgress size={20} /> : 'Health Check'}
                </Button>
                
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('root', 'GET', '/')}
                  disabled={loading.root}
                >
                  {loading.root ? <CircularProgress size={20} /> : 'Root Endpoint'}
                </Button>
                
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('test', 'GET', '/api/test')}
                  disabled={loading.test}
                >
                  {loading.test ? <CircularProgress size={20} /> : 'Test Endpoint'}
                </Button>
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Аутентификация
              </Typography>
              
              <Box display="flex" flexDirection="column" gap={2}>
                <Button
                  variant="contained"
                  onClick={testAuth}
                  disabled={loading.auth}
                >
                  {loading.auth ? <CircularProgress size={20} /> : 'Login'}
                </Button>
                
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('me', 'GET', '/api/admin/me')}
                  disabled={loading.me || !localStorage.getItem('token')}
                >
                  {loading.me ? <CircularProgress size={20} /> : 'Get Current User'}
                </Button>
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Admin endpoints
              </Typography>
              
              <Box display="flex" flexDirection="column" gap={2}>
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('users', 'GET', '/api/admin/users')}
                  disabled={loading.users || !localStorage.getItem('token')}
                >
                  {loading.users ? <CircularProgress size={20} /> : 'Get Users'}
                </Button>
                
                <Button
                  variant="outlined"
                  onClick={() => testEndpoint('dashboard', 'GET', '/api/admin/dashboard')}
                  disabled={loading.dashboard || !localStorage.getItem('token')}
                >
                  {loading.dashboard ? <CircularProgress size={20} /> : 'Get Dashboard Stats'}
                </Button>
              </Box>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} md={6}>
          <Card>
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Действия
              </Typography>
              
              <Box display="flex" flexDirection="column" gap={2}>
                <Button
                  variant="outlined"
                  onClick={clearResponses}
                  color="secondary"
                >
                  Очистить результаты
                </Button>
                
                <Button
                  variant="outlined"
                  onClick={() => localStorage.removeItem('token')}
                  color="error"
                >
                  Очистить токен
                </Button>
              </Box>
            </CardContent>
          </Card>
        </Grid>
      </Grid>

      <Divider sx={{ my: 3 }} />

      <Typography variant="h6" gutterBottom>
        Результаты тестирования
      </Typography>

      {Object.entries(responses).map(([name, response]) => (
        <Card key={name} sx={{ mb: 2 }}>
          <CardContent>
            <Typography variant="subtitle1" gutterBottom>
              {name}
            </Typography>
            
            {response.success ? (
              <Alert severity="success" sx={{ mb: 2 }}>
                Успешно
              </Alert>
            ) : (
              <Alert severity="error" sx={{ mb: 2 }}>
                {response.error}
              </Alert>
            )}
            
            {response.data && (
              <Box>
                <Typography variant="body2" component="pre" sx={{ 
                  backgroundColor: '#f5f5f5', 
                  padding: 1, 
                  borderRadius: 1,
                  overflow: 'auto'
                }}>
                  {JSON.stringify(response.data, null, 2)}
                </Typography>
              </Box>
            )}
          </CardContent>
        </Card>
      ))}
    </Box>
  );
};

export default ApiTester;




