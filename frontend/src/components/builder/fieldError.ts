import type { FieldErrors } from 'react-hook-form';

/** Read a nested RHF error message by dotted path (`questions.0.options.1.value`). */
export function fieldError(errors: FieldErrors, path: string): string | undefined {
  let node: unknown = errors;
  for (const part of path.split('.')) {
    if (typeof node !== 'object' || node === null) return undefined;
    node = (node as Record<string, unknown>)[part];
  }
  if (typeof node !== 'object' || node === null) return undefined;
  // Arrays carry their own-level error under `root` (useFieldArray) or `message`.
  const n = node as { message?: unknown; root?: { message?: unknown } };
  if (typeof n.message === 'string') return n.message;
  if (typeof n.root?.message === 'string') return n.root.message;
  return undefined;
}
