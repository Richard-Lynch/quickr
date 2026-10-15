export type ClassValue = string | false | null | undefined | 0;

/** Join class names, skipping falsy values. */
export function cn(...parts: ClassValue[]): string {
  return parts.filter(Boolean).join(' ');
}
