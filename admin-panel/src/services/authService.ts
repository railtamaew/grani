import { api } from './api';

export interface LoginCredentials {
  email: string;
  password: string;
}

export interface LoginResponse {
  access_token: string;
  token_type: string;
  user: {
    id: number;
    email: string;
    role: string;
    is_active: boolean;
  };
}

export interface User {
  id: number;
  email: string;
  username?: string;
  role: 'owner' | 'admin' | 'support' | 'read_only';
  isActive: boolean;
  createdAt: string;
}

class AuthService {
  async login(credentials: LoginCredentials): Promise<LoginResponse> {
    try {
      const response = await api.post('/api/admin/auth/login', credentials);
      // Сохраняем токен
      localStorage.setItem('token', response.data.access_token);
      return response.data;
    } catch (error: any) {
      console.error('Login error:', error);
      throw error;
    }
  }

  async logout(): Promise<void> {
    try {
      const token = localStorage.getItem('token');
      if (token) {
        await api.post('/api/admin/auth/logout', {}, {
          headers: { Authorization: `Bearer ${token}` }
        });
      }
    } catch (error: any) {
      console.error('Logout error:', error);
      // Даже если logout на сервере не удался, очищаем локальное состояние
    } finally {
      localStorage.removeItem('token');
    }
  }

  async getCurrentUser(): Promise<User> {
    try {
      const token = localStorage.getItem('token');
      if (!token) {
        throw new Error('No token found');
      }

      const response = await api.get('/api/admin/auth/me', {
        headers: { Authorization: `Bearer ${token}` }
      });
      return {
        ...response.data,
        username: response.data.email.split('@')[0],
        role: response.data.role || 'admin',
      };
    } catch (error: any) {
      console.error('Get current user error:', error);
      throw error;
    }
  }

  async refreshToken(): Promise<{ access_token: string }> {
    try {
      const token = localStorage.getItem('token');
      if (!token) {
        throw new Error('No token found');
      }

      const response = await api.post('/api/auth/refresh-token', {}, {
        headers: { Authorization: `Bearer ${token}` }
      });
      
      // Обновляем токен в localStorage
      localStorage.setItem('token', response.data.access_token);
      return response.data;
    } catch (error: any) {
      console.error('Refresh token error:', error);
      throw error;
    }
  }

  isAuthenticated(): boolean {
    const token = localStorage.getItem('token');
    return !!token;
  }

  getToken(): string | null {
    return localStorage.getItem('token');
  }
}

export const authService = new AuthService();


