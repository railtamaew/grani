import React from 'react';
import { Box, Typography } from '@mui/material';

interface PageHeaderProps {
  title: string;
  actions?: React.ReactNode;
}

const PageHeader: React.FC<PageHeaderProps> = ({ title, actions }) => (
  <Box display="flex" justifyContent="space-between" alignItems="center" mb={3}>
    <Typography variant="h4" component="h1">
      {title}
    </Typography>
    {actions}
  </Box>
);

export default PageHeader;
