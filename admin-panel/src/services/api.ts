import axios, { AxiosInstance, AxiosResponse, AxiosError } from 'axios';

export type BackendError = {
  error: {
    code: string;
    message: string;
    details?: any;
  };
};

export const extractBackendError = (err: unknown): { code?: string; message: string; details?: any } => {
  const ax = err as AxiosError<BackendError>;
  const be = ax?.response?.data?.error;
  if (be && typeof be === 'object') {
    return { code: be.code, message: be.message, details: be.details };
  }
  const fallback = (ax?.response as any)?.data?.message || ax?.message || 'Unexpected error';
  return { message: String(fallback) };
};

const getApiBaseUrl = (): string => {
  if (typeof window !== 'undefined' && window.__GRANI_CONFIG__?.apiBaseUrl !== undefined) {
    return window.__GRANI_CONFIG__.apiBaseUrl || '';
  }
  return process.env.REACT_APP_API_URL || '';
};

// Создаем экземпляр axios с базовой конфигурацией
// Используем относительные пути (пустая строка), так как Nginx проксирует /api на backend
// Все пути в сервисах уже содержат /api/ в начале (например, /api/admin/auth/login)
const api: AxiosInstance = axios.create({
  baseURL: getApiBaseUrl(),
  timeout: 30000, // Увеличено для медленных соединений
  headers: {
    'Content-Type': 'application/json',
  },
  // Оптимизация: включить сжатие ответов
  decompress: true,
});

// Интерцептор для добавления токена к каждому запросу
api.interceptors.request.use(
  (config) => {
    const token = localStorage.getItem('token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  },
  (error) => {
    return Promise.reject(error);
  }
);

// Интерцептор для обработки ответов
api.interceptors.response.use(
  (response: AxiosResponse) => {
    return response;
  },
  async (error: AxiosError) => {
    const originalRequest = error.config as any;

    // Если получили 401 и это не повторный запрос
    if (error.response?.status === 401 && !originalRequest._retry) {
      originalRequest._retry = true;

      try {
        // Пытаемся обновить токен
        const token = localStorage.getItem('token');
        if (token) {
          // Используем относительный путь, так как Nginx проксирует /api
          const baseUrl = getApiBaseUrl();
          const refreshUrl = `${baseUrl}/api/auth/refresh-token`;
          const response = await axios.post(
            refreshUrl,
            {},
            { headers: { Authorization: `Bearer ${token}` } }
          );

          if (response.data.access_token) {
            localStorage.setItem('token', response.data.access_token);
            originalRequest.headers.Authorization = `Bearer ${response.data.access_token}`;
            return api(originalRequest);
          }
        }
      } catch (refreshError) {
        // Если не удалось обновить токен — централизованная обработка
        localStorage.removeItem('token');
        window.dispatchEvent(new CustomEvent('auth:unauthorized'));
        window.location.href = '/login';
        return Promise.reject(refreshError);
      }
    }

    // 403 — нет прав: централизуем
    if (error.response?.status === 403) {
      window.dispatchEvent(new CustomEvent('auth:forbidden'));
    }

    // Нормализуем сообщение ошибки под error envelope
    const norm = extractBackendError(error);
    (error as any).normalized = norm;
    return Promise.reject(error);
  }
);

export { api };


