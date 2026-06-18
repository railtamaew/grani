export {};

declare global {
  interface Window {
    __GRANI_CONFIG__?: {
      apiBaseUrl?: string;
    };
  }
}
