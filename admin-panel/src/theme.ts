import { createTheme } from '@mui/material/styles';

const theme = createTheme({
  palette: {
    mode: 'light',
    primary: {
      main: '#192F3F', // primaryText из GRANI
      light: '#4F6E84',
      dark: '#023E53',
    },
    secondary: {
      main: '#2EC07E', // accent/xrayActive из GRANI
      light: '#4ED99C',
      dark: '#20704C',
    },
    background: {
      default: '#F7F4F8', // primaryBackground из GRANI
      paper: '#F4F6F8', // cardBackground из GRANI
    },
    text: {
      primary: '#192F3F', // primaryText
      secondary: '#A4ACB5', // secondaryText
    },
    error: {
      main: '#B40000',
      light: '#FFDEDE',
      dark: '#E63946',
    },
    success: {
      main: '#2EC07E',
    },
  },
  typography: {
    fontFamily: '"Montserrat", "Roboto", "Helvetica", "Arial", sans-serif',
    h1: {
      fontSize: '2.5rem',
      fontWeight: 600,
      color: '#192F3F',
    },
    h2: {
      fontSize: '2rem',
      fontWeight: 600,
      color: '#192F3F',
    },
    h3: {
      fontSize: '1.75rem',
      fontWeight: 600,
      color: '#192F3F',
    },
    h4: {
      fontSize: '1.5rem',
      fontWeight: 600,
      color: '#192F3F',
    },
    h5: {
      fontSize: '1.25rem',
      fontWeight: 500,
      color: '#192F3F',
    },
    h6: {
      fontSize: '1rem',
      fontWeight: 500,
      color: '#192F3F',
    },
    body1: {
      color: '#192F3F',
    },
    body2: {
      color: '#A4ACB5',
    },
  },
  components: {
    MuiButton: {
      styleOverrides: {
        root: {
          textTransform: 'none',
          borderRadius: 12,
          fontWeight: 500,
          padding: '10px 24px',
        },
        contained: {
          boxShadow: '0 2px 8px rgba(25, 47, 63, 0.15)',
          '&:hover': {
            boxShadow: '0 4px 12px rgba(25, 47, 63, 0.25)',
          },
        },
      },
    },
    MuiCard: {
      styleOverrides: {
        root: {
          borderRadius: 16,
          boxShadow: '0 2px 12px rgba(0, 0, 0, 0.08)',
          backgroundColor: '#F4F6F8',
          border: '1px solid rgba(164, 172, 181, 0.2)',
          backdropFilter: 'blur(10px)',
        },
      },
    },
    MuiPaper: {
      styleOverrides: {
        root: {
          borderRadius: 16,
          backgroundColor: '#F4F6F8',
          boxShadow: '0 2px 12px rgba(0, 0, 0, 0.08)',
        },
        elevation1: {
          boxShadow: '0 2px 8px rgba(0, 0, 0, 0.1)',
        },
      },
    },
    MuiTextField: {
      styleOverrides: {
        root: {
          '& .MuiOutlinedInput-root': {
            borderRadius: 12,
            backgroundColor: '#FFFFFF',
          },
        },
      },
    },
    MuiChip: {
      styleOverrides: {
        root: {
          borderRadius: 8,
        },
      },
    },
  },
  shape: {
    borderRadius: 12,
  },
});

export default theme;
