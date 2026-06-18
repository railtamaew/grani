import React, { useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import {
  Box,
  Drawer,
  AppBar,
  Toolbar,
  Typography,
  IconButton,
  Avatar,
  Menu,
  MenuItem,
  Divider,
  List,
  ListItem,
  ListItemButton,
  ListItemIcon,
  ListItemText,
} from '@mui/material';
import {
  Menu as MenuIcon,
  Dashboard,
  People,
  Dns,
  Payment,
  AccountCircle,
  Logout,
  BugReport,
  Security,
  Router,
  Warning,
  History,
  Settings,
  PhoneIphone,
  Timer,
  PersonSearch,
  Hub,
  Insights,
  SupportAgent,
  Timeline,
} from '@mui/icons-material';
import Logo from '../Logo';
import { User } from '../../store/slices/authSlice';

interface SidebarProps {
  user: User | null;
  onLogout: () => void;
}

const drawerWidth = 240;

// Функция проверки роли для отображения пунктов меню
const canAccess = (userRole: string | undefined, requiredRoles: string[]): boolean => {
  if (!userRole) return false;
  const roleHierarchy: { [key: string]: number } = {
    'owner': 4,
    'admin': 3,
    'support': 2,
    'read_only': 1,
  };
  return requiredRoles.some(role => roleHierarchy[userRole] >= roleHierarchy[role]);
};

const Sidebar: React.FC<SidebarProps> = ({ user, onLogout }) => {
  const [mobileOpen, setMobileOpen] = useState(false);
  const [anchorEl, setAnchorEl] = useState<null | HTMLElement>(null);
  const navigate = useNavigate();
  const location = useLocation();

  const handleDrawerToggle = () => {
    setMobileOpen(!mobileOpen);
  };

  const handleProfileMenuOpen = (event: React.MouseEvent<HTMLElement>) => {
    setAnchorEl(event.currentTarget);
  };

  const handleProfileMenuClose = () => {
    setAnchorEl(null);
  };

  const handleLogout = () => {
    onLogout();
    handleProfileMenuClose();
    navigate('/login');
  };

  const menuItems = [
    { text: 'Дашборд', icon: <Dashboard />, path: '/dashboard', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Пользователи', icon: <People />, path: '/users', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Устройства', icon: <PhoneIphone />, path: '/devices', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Триалы', icon: <Timer />, path: '/trials', roles: ['support', 'admin', 'owner'] },
    { text: 'Протоколы', icon: <Router />, path: '/protocols', roles: ['admin', 'owner'] },
    { text: 'Серверы', icon: <Dns />, path: '/servers', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Инциденты', icon: <Warning />, path: '/incidents', roles: ['support', 'admin', 'owner'] },
    { text: 'Платежи', icon: <Payment />, path: '/payments', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Подписки', icon: <Payment />, path: '/subscriptions', roles: ['read_only', 'support', 'admin', 'owner'] },
    { text: 'Логи клиента', icon: <BugReport />, path: '/client-logs', roles: ['support', 'admin', 'owner'] },
    { text: 'Логи подключений', icon: <Hub />, path: '/connection-logs', roles: ['support', 'admin', 'owner'] },
    { text: 'Логи по пользователю', icon: <PersonSearch />, path: '/user-logs', roles: ['support', 'admin', 'owner'] },
    { text: 'Диагностика поддержки', icon: <SupportAgent />, path: '/support-diagnostics', roles: ['support', 'admin', 'owner'] },
    { text: 'Observability', icon: <Insights />, path: '/observability', roles: ['support', 'admin', 'owner'] },
    { text: 'График продукта', icon: <Timeline />, path: '/product-timeline', roles: ['support', 'admin', 'owner'] },
    { text: 'Audit Log', icon: <History />, path: '/audit-log', roles: ['owner'] },
    { text: 'Настройки', icon: <Settings />, path: '/settings', roles: ['owner'] },
    { text: 'Коды авторизации', icon: <Security />, path: '/auth-codes', roles: ['admin', 'owner'] },
  ].filter(item => canAccess(user?.role, item.roles));

  const drawer = (
    <Box>
      <Toolbar>
        <Logo size="small" />
      </Toolbar>
      <Divider />
      <List>
        {menuItems.map((item) => (
          <ListItem key={item.text} disablePadding>
            <ListItemButton
              selected={location.pathname === item.path}
              onClick={() => navigate(item.path)}
            >
              <ListItemIcon>{item.icon}</ListItemIcon>
              <ListItemText primary={item.text} />
            </ListItemButton>
          </ListItem>
        ))}
      </List>
    </Box>
  );

  return (
    <>
      <AppBar
        position="fixed"
        sx={{
          width: { sm: `calc(100% - ${drawerWidth}px)` },
          ml: { sm: `${drawerWidth}px` },
        }}
      >
        <Toolbar>
          <IconButton
            color="inherit"
            aria-label="open drawer"
            edge="start"
            onClick={handleDrawerToggle}
            sx={{ mr: 2, display: { sm: 'none' } }}
          >
            <MenuIcon />
          </IconButton>
          <Box sx={{ flexGrow: 1 }} />
          <IconButton
            size="large"
            edge="end"
            aria-label="account of current user"
            aria-controls="primary-search-account-menu"
            aria-haspopup="true"
            onClick={handleProfileMenuOpen}
            color="inherit"
          >
            <Avatar sx={{ width: 32, height: 32 }}>
              {user?.username?.charAt(0) || <AccountCircle />}
            </Avatar>
          </IconButton>
          <Menu
            anchorEl={anchorEl}
            anchorOrigin={{
              vertical: 'top',
              horizontal: 'right',
            }}
            keepMounted
            transformOrigin={{
              vertical: 'top',
              horizontal: 'right',
            }}
            open={Boolean(anchorEl)}
            onClose={handleProfileMenuClose}
          >
            <MenuItem disabled>
              <Typography variant="body2">
                {user?.email}
              </Typography>
            </MenuItem>
            <Divider />
            <MenuItem onClick={handleLogout}>
              <Logout sx={{ mr: 1 }} />
              Выйти
            </MenuItem>
          </Menu>
        </Toolbar>
      </AppBar>
      <Box
        component="nav"
        sx={{ width: { sm: drawerWidth }, flexShrink: { sm: 0 } }}
      >
        <Drawer
          variant="temporary"
          open={mobileOpen}
          onClose={handleDrawerToggle}
          ModalProps={{
            keepMounted: true,
          }}
          sx={{
            display: { xs: 'block', sm: 'none' },
            '& .MuiDrawer-paper': {
              boxSizing: 'border-box',
              width: drawerWidth,
            },
          }}
        >
          {drawer}
        </Drawer>
        <Drawer
          variant="permanent"
          sx={{
            display: { xs: 'none', sm: 'block' },
            '& .MuiDrawer-paper': {
              boxSizing: 'border-box',
              width: drawerWidth,
            },
          }}
          open
        >
          {drawer}
        </Drawer>
      </Box>
    </>
  );
};

export default Sidebar;
