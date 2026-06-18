import React, { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Box,
  Typography,
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
  Pagination,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
} from '@mui/material';
import {
  Search,
  Visibility,
  Refresh,
  ArrowUpward,
  ArrowDownward,
} from '@mui/icons-material';

import { RootState } from '../store';
import { fetchPayments } from '../store/slices/paymentsSlice';
import { downloadCsv } from '../utils/csv';
import PageHeader from '../components/PageHeader';
import FilterCard from '../components/FilterCard';

const PaymentsPage: React.FC = () => {
  const dispatch = useDispatch<any>();
  const { payments, loading, error, total, page, limit } = useSelector((state: RootState) => state.payments);
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [createdFrom, setCreatedFrom] = useState('');
  const [createdTo, setCreatedTo] = useState('');
  const [selectedPayment, setSelectedPayment] = useState<any>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [sortField, setSortField] = useState<string>('id');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('asc');

  useEffect(() => {
    dispatch(fetchPayments({ page, limit }));
  }, [dispatch, page, limit]);

  const handleSearch = () => {
    dispatch(fetchPayments({
      page: 1,
      limit,
      status: statusFilter || undefined,
      search: searchTerm || undefined,
      created_from: createdFrom || undefined,
      created_to: createdTo || undefined,
    }));
  };

  const handleReset = () => {
    setSearchTerm('');
    setStatusFilter('');
    setCreatedFrom('');
    setCreatedTo('');
    dispatch(fetchPayments({ page: 1, limit }));
  };

  const handleViewPayment = (payment: any) => {
    setSelectedPayment(payment);
    setDialogOpen(true);
  };

  const handlePageChange = (event: React.ChangeEvent<unknown>, value: number) => {
    dispatch(fetchPayments({
      page: value,
      limit,
      status: statusFilter || undefined,
      search: searchTerm || undefined,
      created_from: createdFrom || undefined,
      created_to: createdTo || undefined,
    }));
  };

  const handleExport = () => {
    downloadCsv(
      'payments-export.csv',
      ['ID', 'User Email', 'Amount', 'Currency', 'Method', 'Status', 'Plan', 'Created At'],
      payments.map((payment) => [
        payment.id,
        payment.user_email,
        payment.amount,
        payment.currency,
        payment.payment_method,
        payment.status,
        payment.plan_name || '',
        payment.created_at,
      ])
    );
  };

  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('ru-RU', {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  const getStatusColor = (status: string) => {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'success':
        return 'success';
      case 'pending':
        return 'warning';
      case 'failed':
      case 'cancelled':
        return 'error';
      default:
        return 'default';
    }
  };

  const getStatusLabel = (status: string) => {
    switch (status.toLowerCase()) {
      case 'completed':
      case 'success':
        return 'Успешно';
      case 'pending':
        return 'В обработке';
      case 'failed':
        return 'Ошибка';
      case 'cancelled':
        return 'Отменен';
      default:
        return status;
    }
  };

  const handleSort = (field: string) => {
    if (sortField === field) setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    else { setSortField(field); setSortDirection('asc'); }
  };
  const sortedPayments = [...payments].sort((a, b) => {
    let aVal: any = (a as any)[sortField];
    let bVal: any = (b as any)[sortField];
    if (sortField === 'created_at' || sortField === 'updated_at') {
      aVal = aVal ? new Date(aVal).getTime() : 0;
      bVal = bVal ? new Date(bVal).getTime() : 0;
    } else if (sortField === 'amount') {
      aVal = Number(aVal) || 0;
      bVal = Number(bVal) || 0;
    } else if (typeof aVal === 'string') {
      aVal = (aVal || '').toLowerCase();
      bVal = (bVal || '').toLowerCase();
    }
    if (aVal < bVal) return sortDirection === 'asc' ? -1 : 1;
    if (aVal > bVal) return sortDirection === 'asc' ? 1 : -1;
    return 0;
  });
  const SortableHeader = ({ field, children }: { field: string; children: React.ReactNode }) => (
    <TableCell sx={{ cursor: 'pointer', userSelect: 'none' }} onClick={() => handleSort(field)}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
        {children}
        {sortField === field && (sortDirection === 'asc' ? <ArrowUpward fontSize="small" /> : <ArrowDownward fontSize="small" />)}
      </Box>
    </TableCell>
  );

  if (loading && payments.length === 0) {
    return (
      <Box display="flex" justifyContent="center" alignItems="center" minHeight="400px">
        <CircularProgress />
      </Box>
    );
  }

  return (
    <Box>
      <PageHeader
        title="Платежи"
        actions={(
          <Box display="flex" gap={1}>
            <Button variant="outlined" onClick={handleExport} disabled={payments.length === 0}>
              Экспорт CSV
            </Button>
            <Button
              variant="outlined"
              startIcon={<Refresh />}
              onClick={() => dispatch(fetchPayments({ page, limit }))}
              disabled={loading}
            >
              Обновить
            </Button>
          </Box>
        )}
      />

      {error && (
        <Alert severity="error" sx={{ mb: 3 }}>
          {error}
        </Alert>
      )}

      <FilterCard>
        <Box display="flex" gap={2} alignItems="center" flexWrap="wrap">
            <TextField
              label="Поиск по email"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              onKeyPress={(e) => e.key === 'Enter' && handleSearch()}
              sx={{ minWidth: 200 }}
            />
            <FormControl sx={{ minWidth: 150 }}>
              <InputLabel>Статус</InputLabel>
              <Select
                value={statusFilter}
                label="Статус"
                onChange={(e) => setStatusFilter(e.target.value)}
              >
                <MenuItem value="">Все</MenuItem>
                <MenuItem value="completed">Успешно</MenuItem>
                <MenuItem value="pending">В обработке</MenuItem>
                <MenuItem value="failed">Ошибка</MenuItem>
                <MenuItem value="cancelled">Отменен</MenuItem>
              </Select>
            </FormControl>
            <TextField
              label="Дата от"
              type="date"
              value={createdFrom}
              onChange={(e) => setCreatedFrom(e.target.value)}
              InputLabelProps={{ shrink: true }}
              sx={{ minWidth: 160 }}
            />
            <TextField
              label="Дата до"
              type="date"
              value={createdTo}
              onChange={(e) => setCreatedTo(e.target.value)}
              InputLabelProps={{ shrink: true }}
              sx={{ minWidth: 160 }}
            />
            <Button
              variant="contained"
              startIcon={<Search />}
              onClick={handleSearch}
              disabled={loading}
            >
              Найти
            </Button>
            <Button
              variant="outlined"
              onClick={handleReset}
              disabled={loading}
            >
              Сбросить
            </Button>
        </Box>
      </FilterCard>

      <TableContainer component={Paper}>
        <Table>
          <TableHead>
            <TableRow>
              <SortableHeader field="id">ID</SortableHeader>
              <SortableHeader field="user_email">Email пользователя</SortableHeader>
              <SortableHeader field="amount">Сумма</SortableHeader>
              <SortableHeader field="payment_method">Метод оплаты</SortableHeader>
              <TableCell>Статус</TableCell>
              <SortableHeader field="plan_name">План</SortableHeader>
              <SortableHeader field="created_at">Дата создания</SortableHeader>
              <TableCell>Действия</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {sortedPayments.map((payment) => (
              <TableRow key={payment.id}>
                <TableCell>{payment.id}</TableCell>
                <TableCell>{payment.user_email}</TableCell>
                <TableCell>
                  {payment.amount} {payment.currency}
                </TableCell>
                <TableCell>{payment.payment_method}</TableCell>
                <TableCell>
                  <Chip
                    label={getStatusLabel(payment.status)}
                    color={getStatusColor(payment.status) as any}
                    size="small"
                  />
                </TableCell>
                <TableCell>
                  {payment.plan_name || '-'}
                </TableCell>
                <TableCell>{formatDate(payment.created_at)}</TableCell>
                <TableCell>
                  <IconButton
                    size="small"
                    onClick={() => handleViewPayment(payment)}
                    title="Просмотр"
                  >
                    <Visibility />
                  </IconButton>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>

      <Box display="flex" justifyContent="center" mt={3}>
        <Pagination
          count={Math.ceil(total / limit)}
          page={page}
          onChange={handlePageChange}
          color="primary"
        />
      </Box>

      <Dialog open={dialogOpen} onClose={() => setDialogOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle>Детали платежа</DialogTitle>
        <DialogContent>
          {selectedPayment && (
            <Box>
              <Typography variant="body1" gutterBottom>
                <strong>ID платежа:</strong> {selectedPayment.id}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Email пользователя:</strong> {selectedPayment.user_email}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Сумма:</strong> {selectedPayment.amount} {selectedPayment.currency}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Метод оплаты:</strong> {selectedPayment.payment_method}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Статус:</strong> {getStatusLabel(selectedPayment.status)}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Дата создания:</strong> {formatDate(selectedPayment.created_at)}
              </Typography>
              <Typography variant="body1" gutterBottom>
                <strong>Дата обновления:</strong> {formatDate(selectedPayment.updated_at)}
              </Typography>
              {selectedPayment.subscription_id && (
                <Typography variant="body1" gutterBottom>
                  <strong>ID подписки:</strong> {selectedPayment.subscription_id}
                </Typography>
              )}
              {selectedPayment.plan_name && (
                <Typography variant="body1" gutterBottom>
                  <strong>План:</strong> {selectedPayment.plan_name}
                </Typography>
              )}
            </Box>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setDialogOpen(false)}>Закрыть</Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
};

export default PaymentsPage;
