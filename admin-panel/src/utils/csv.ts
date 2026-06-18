type CsvValue = string | number | boolean | null | undefined;

export const escapeCsvValue = (value: CsvValue): string => {
  if (value === null || value === undefined) return '';
  const stringValue = String(value);
  if (/[",\n]/.test(stringValue)) {
    return `"${stringValue.replace(/"/g, '""')}"`;
  }
  return stringValue;
};

/** Собирает CSV-строку (для тестов и отладки). */
export const buildCsvContent = (headers: string[], rows: CsvValue[][]): string => {
  return [
    headers.map(escapeCsvValue).join(','),
    ...rows.map((row) => row.map(escapeCsvValue).join(',')),
  ].join('\n');
};

export const downloadCsv = (filename: string, headers: string[], rows: CsvValue[][]) => {
  const csv = buildCsvContent(headers, rows);
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
};
