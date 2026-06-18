import React, { useEffect, useState } from 'react';
import {
  Box,
  Typography,
  Card,
  CardContent,
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
  Alert,
  CircularProgress,
  IconButton,
  Tooltip,
} from '@mui/material';
import {
  Search,
  Refresh,
  ContentCopy,
  CheckCircle,
  Cancel,
} from '@mui/icons-material';
import { authCodesService, AuthCode } from '../services/authCodesService';

const AuthCodesPage: React.FC = () => {
  const [codes, setCodes] = useState<AuthCode[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searchEmail, setSearchEmail] = useState('');
  const [copiedHash, setCopiedHash] = useState<string | null>(null);

  const loadCodes = async (email?: string) => {
    setLoading(true);
    setError(null);
    try {
      const response = await authCodesService.getAuthCodes(email);
      const nextCodes = Array.isArray(response?.codes) ? response.codes : [];
      setCodes(nextCodes);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Ошибка загрузки кодов');
      console.error('Error loading auth codes:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadCodes();
  }, []);

  const handleSearch = () => {
    loadCodes(searchEmail || undefined);
  };

  const handleCopyHash = (hash: string) => {
    navigator.clipboard.writeText(hash);
    setCopiedHash(hash);
    setTimeout(() => setCopiedHash(null), 2000);
  };

  const formatDate = (dateString: string) => {
    const date = new Date(dateString);
    return date.toLocaleString('ru-RU', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
  };

  const formatTimeLeft = (seconds: number) => {
    if (seconds <= 0) return 'Истек';
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${minutes}м ${secs}с`;
  };

  return (
    <Box sx={{ py: 3, pr: 3, pl: 0 }}>
      <Typography variant="h4" gutterBottom>
        Коды авторизации
      </Typography>

      <Card sx={{ mb: 3 }}>
        <CardContent>
          <Box sx={{ display: 'flex', gap: 2, mb: 2 }}>
            <TextField
              label="Поиск по email"
              value={searchEmail}
              onChange={(e) => setSearchEmail(e.target.value)}
              onKeyPress={(e) => {
                if (e.key === 'Enter') {
                  handleSearch();
                }
              }}
              placeholder="rail.tamaew@gmail.com"
              sx={{ flexGrow: 1 }}
            />
            <Button
              variant="contained"
              startIcon={<Search />}
              onClick={handleSearch}
            >
              Поиск
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => {
                setSearchEmail('');
                loadCodes();
              }}
            >
              Обновить
            </Button>
          </Box>
        </CardContent>
      </Card>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }}>
          {error}
        </Alert>
      )}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', p: 4 }}>
          <CircularProgress />
        </Box>
      ) : (
        <TableContainer component={Paper}>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell>ID</TableCell>
                <TableCell>Email</TableCell>
                <TableCell>Code Hash</TableCell>
                <TableCell>Создан</TableCell>
                <TableCell>Истекает</TableCell>
                <TableCell>Статус</TableCell>
                <TableCell>Попытки</TableCell>
                <TableCell>IP адрес</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {codes.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} align="center">
                    <Typography variant="body2" color="text.secondary">
                      Коды не найдены
                    </Typography>
                  </TableCell>
                </TableRow>
              ) : (
                codes.map((code) => (
                  <TableRow key={code.id}>
                    <TableCell>{code.id}</TableCell>
                    <TableCell>
                      <Typography variant="body2" fontWeight="medium">
                        {code.email}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                        <Typography
                          variant="body2"
                          sx={{
                            fontFamily: 'monospace',
                            fontSize: '0.75rem',
                            maxWidth: '200px',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                          }}
                        >
                          {code.code_hash}
                        </Typography>
                        <Tooltip title={copiedHash === code.code_hash ? 'Скопировано!' : 'Копировать'}>
                          <IconButton
                            size="small"
                            onClick={() => handleCopyHash(code.code_hash)}
                          >
                            {copiedHash === code.code_hash ? (
                              <CheckCircle fontSize="small" color="success" />
                            ) : (
                              <ContentCopy fontSize="small" />
                            )}
                          </IconButton>
                        </Tooltip>
                      </Box>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">
                        {formatDate(code.created_at)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2">
                        {formatDate(code.expires_at)}
                      </Typography>
                    </TableCell>
                    <TableCell>
                      {code.is_expired ? (
                        <Chip
                          label="Истек"
                          color="error"
                          size="small"
                          icon={<Cancel />}
                        />
                      ) : (
                        <Chip
                          label={`Активен (${formatTimeLeft(code.time_left_seconds ?? 0)})`}
                          color="success"
                          size="small"
                          icon={<CheckCircle />}
                        />
                      )}
                    </TableCell>
                    <TableCell>
                      <Chip
                        label={code.attempts_count}
                        color={code.attempts_count >= 5 ? 'error' : 'default'}
                        size="small"
                      />
                    </TableCell>
                    <TableCell>
                      <Typography variant="body2" color="text.secondary">
                        {code.ip_address || '-'}
                      </Typography>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </TableContainer>
      )}

      {codes.length > 0 && (
        <Box sx={{ mt: 2 }}>
          <Typography variant="body2" color="text.secondary">
            Всего найдено: {codes.length}
          </Typography>
        </Box>
      )}
    </Box>
  );
};

export default AuthCodesPage;






