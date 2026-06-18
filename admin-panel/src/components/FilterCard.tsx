import React from 'react';
import { Card, CardContent } from '@mui/material';

interface FilterCardProps {
  children: React.ReactNode;
}

const FilterCard: React.FC<FilterCardProps> = ({ children }) => (
  <Card sx={{ mb: 3 }}>
    <CardContent>
      {children}
    </CardContent>
  </Card>
);

export default FilterCard;
