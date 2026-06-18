import React from 'react';
import { Box } from '@mui/material';

interface LogoProps {
  size?: 'small' | 'medium' | 'large';
  showText?: boolean;
}

const Logo: React.FC<LogoProps> = ({ size = 'medium' }) => {
  const heights = {
    small: 32,
    medium: 40,
    large: 56,
  };
  const height = heights[size];

  return (
    <Box sx={{ display: 'flex', alignItems: 'center' }}>
      <img
        src="/logo.png"
        alt="GRANI"
        style={{
          height,
          width: 'auto',
          objectFit: 'contain',
          display: 'block',
        }}
      />
    </Box>
  );
};

export default Logo;
