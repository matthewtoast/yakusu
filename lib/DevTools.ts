export const safeConfigValue = (
  value: string | null | undefined,
  fallback: string
): string => {
  if (!value) return `${fallback}`;
  return /[\s@/]/.test(value) ? `"${value}"` : value;
};
