import React from 'react';
import { Box, Button, Typography, Alert } from '@mui/material';

type ErrorBoundaryState = {
  hasError: boolean;
  error?: Error;
};

class ErrorBoundary extends React.Component<React.PropsWithChildren, ErrorBoundaryState> {
  state: ErrorBoundaryState = {
    hasError: false,
  };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    // Логируем в консоль, чтобы это было видно в DevTools
    // В будущем можно отправлять в backend audit/logs
    console.error('Admin UI crashed:', error, errorInfo);
  }

  handleReload = () => {
    window.location.reload();
  };

  render() {
    if (this.state.hasError) {
      return (
        <Box
          sx={{
            minHeight: '100vh',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            p: 4,
          }}
        >
          <Box sx={{ maxWidth: 560 }}>
            <Typography variant="h4" gutterBottom>
              Ошибка в интерфейсе админ‑панели
            </Typography>
            <Alert severity="error" sx={{ mb: 2 }}>
              {this.state.error?.message || 'Не удалось отрисовать интерфейс.'}
            </Alert>
            <Button variant="contained" onClick={this.handleReload}>
              Перезагрузить
            </Button>
          </Box>
        </Box>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
