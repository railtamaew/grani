import React, { useState, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import {
  Box,
  Typography,
  TextField,
  Button,
  Alert,
  Paper,
  InputAdornment,
} from '@mui/material';
import { Person, Search } from '@mui/icons-material';
import PageHeader from '../components/PageHeader';
import UserDiagnosticsView from '../components/UserDiagnosticsView';
import { usersService } from '../services/usersService';

const UserLogsPage: React.FC = () => {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const userIdFromUrl = searchParams.get('userId');
  const [userIdInput, setUserIdInput] = useState(userIdFromUrl || '');
  const [emailSearch, setEmailSearch] = useState('');
  const [userId, setUserId] = useState<number | null>(userIdFromUrl ? parseInt(userIdFromUrl, 10) : null);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);

  useEffect(() => {
    const id = searchParams.get('userId');
    if (id) {
      const n = parseInt(id, 10);
      if (!Number.isNaN(n) && n > 0) {
        setUserId(n);
        setUserIdInput(id);
      }
    }
  }, [searchParams]);

  const handleShowByUserId = () => {
    const id = parseInt(userIdInput.trim(), 10);
    if (Number.isNaN(id) || id <= 0) {
      setSearchError('Введите корректный ID пользователя (число больше 0)');
      return;
    }
    setSearchError(null);
    setUserId(id);
  };

  const handleSearchByEmail = async () => {
    const email = emailSearch.trim();
    if (!email) {
      setSearchError('Введите email для поиска');
      return;
    }
    setSearching(true);
    setSearchError(null);
    try {
      const data = await usersService.getUsers({ search: email, limit: 5 });
      const users = data.users || [];
      const match = users.find((u: any) => u.email && u.email.toLowerCase() === email.toLowerCase())
        || users[0];
      if (match) {
        setUserId(match.id);
        setUserIdInput(String(match.id));
      } else {
        setSearchError('Пользователь с таким email не найден');
      }
    } catch (err: any) {
      setSearchError(err.response?.data?.detail || 'Ошибка поиска');
    } finally {
      setSearching(false);
    }
  };

  return (
    <Box>
      <PageHeader
        title="Логи по пользователю"
      />
      <Paper sx={{ p: 2, mb: 2 }}>
        <Typography variant="subtitle1" gutterBottom>
          Выберите пользователя по ID или найдите по email
        </Typography>
        <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 2, alignItems: 'flex-start' }}>
          <TextField
            size="small"
            label="User ID"
            value={userIdInput}
            onChange={(e) => setUserIdInput(e.target.value)}
            placeholder="Например: 42"
            sx={{ width: 140 }}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <Person fontSize="small" />
                </InputAdornment>
              ),
            }}
          />
          <Button variant="contained" onClick={handleShowByUserId}>
            Показать логи
          </Button>
          <Box sx={{ flexBasis: '100%', height: 0 }} />
          <TextField
            size="small"
            label="Поиск по email"
            value={emailSearch}
            onChange={(e) => setEmailSearch(e.target.value)}
            placeholder="user@example.com"
            sx={{ minWidth: 260 }}
            disabled={searching}
            InputProps={{
              startAdornment: (
                <InputAdornment position="start">
                  <Search fontSize="small" />
                </InputAdornment>
              ),
            }}
          />
          <Button variant="outlined" onClick={handleSearchByEmail} disabled={searching}>
            {searching ? 'Поиск…' : 'Найти и показать логи'}
          </Button>
        </Box>
        {searchError && (
          <Alert severity="warning" sx={{ mt: 2 }} onClose={() => setSearchError(null)}>
            {searchError}
          </Alert>
        )}
        {userId !== null && (
          <Box sx={{ mt: 2 }}>
            <Button
              size="small"
              variant="outlined"
              onClick={() => navigate(`/users/${userId}`)}
            >
              Открыть карточку пользователя
            </Button>
          </Box>
        )}
      </Paper>

      {userId !== null && (
        <UserDiagnosticsView userId={userId} showTitle={true} />
      )}

      {userId === null && (
        <Typography color="textSecondary" sx={{ py: 4 }}>
          Введите ID пользователя или найдите по email и нажмите «Показать логи» или «Найти и показать логи».
        </Typography>
      )}
    </Box>
  );
};

export default UserLogsPage;
