import { escapeCsvValue, buildCsvContent } from './csv';

describe('escapeCsvValue', () => {
  it('returns empty string for null and undefined', () => {
    expect(escapeCsvValue(null)).toBe('');
    expect(escapeCsvValue(undefined)).toBe('');
  });

  it('returns string as-is when no special chars', () => {
    expect(escapeCsvValue('hello')).toBe('hello');
    expect(escapeCsvValue(42)).toBe('42');
    expect(escapeCsvValue(true)).toBe('true');
  });

  it('escapes comma and newline', () => {
    expect(escapeCsvValue('a,b')).toBe('"a,b"');
    expect(escapeCsvValue('line1\nline2')).toBe('"line1\nline2"');
  });

  it('doubles quotes inside value', () => {
    expect(escapeCsvValue('say "hi"')).toBe('"say ""hi"""');
  });
});

describe('buildCsvContent', () => {
  it('builds valid CSV with headers and rows', () => {
    const csv = buildCsvContent(['Name', 'Count'], [
      ['Alice', 1],
      ['Bob', 2],
    ]);
    expect(csv).toBe('Name,Count\nAlice,1\nBob,2');
  });

  it('handles empty rows', () => {
    const csv = buildCsvContent(['A', 'B'], []);
    expect(csv).toBe('A,B');
  });

  it('escapes values with commas', () => {
    const csv = buildCsvContent(['Name'], [['Doe, John']]);
    expect(csv).toBe('Name\n"Doe, John"');
  });
});
