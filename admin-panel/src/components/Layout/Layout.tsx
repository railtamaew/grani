import React from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Box, CssBaseline } from '@mui/material';
import { AppDispatch, RootState } from '../../store';
import { logoutUser } from '../../store/slices/authSlice';
import Sidebar from './Sidebar';

interface LayoutProps {
  children: React.ReactNode;
}

const Layout: React.FC<LayoutProps> = ({ children }) => {
  const dispatch = useDispatch<AppDispatch>();
  const { user } = useSelector((state: RootState) => state.auth);

  const handleLogout = () => {
    dispatch(logoutUser());
  };

  return (
    <Box sx={{ display: 'flex' }}>
      <CssBaseline />
      <Sidebar user={user} onLogout={handleLogout} />
      <Box
        component="main"
        sx={{
          flexGrow: 1,
          minWidth: 0,
          py: 3,
          px: 3,
          marginTop: '64px',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'stretch',
          '& > *': {
            width: '100%',
            maxWidth: 'none',
          },
        }}
      >
        {children}
      </Box>
    </Box>
  );
};

export default Layout;
