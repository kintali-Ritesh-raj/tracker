// Errors and request-body validation. Errors use the FastAPI shape
// {"detail": "..."} that the Flutter client already understands.

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export const fail = (status: number, message: string): never => {
  throw new ApiError(status, message);
};

type Json = Record<string, unknown>;

/** Tiny field validator so every endpoint rejects bad input consistently. */
export class Body {
  constructor(private readonly data: Json) {}

  static async from(req: Request): Promise<Body> {
    let data: unknown;
    try {
      data = await req.json();
    } catch {
      fail(422, 'Request body must be JSON.');
    }
    if (data === null || typeof data !== 'object' || Array.isArray(data)) fail(422, 'Request body must be a JSON object.');
    return new Body(data as Json);
  }

  has(key: string): boolean {
    return Object.prototype.hasOwnProperty.call(this.data, key);
  }

  raw(key: string): unknown {
    return this.data[key];
  }

  str(key: string, opts: { required?: boolean; min?: number; max: number; pattern?: RegExp }): string | null {
    const v = this.data[key];
    if (v === undefined || v === null) {
      if (opts.required) fail(422, `${key} is required.`);
      return null;
    }
    if (typeof v !== 'string') return fail(422, `${key} must be text.`);
    const s = v.trim();
    if (s.length < (opts.min ?? (opts.required ? 1 : 0))) fail(422, `${key} is too short.`);
    if (s.length > opts.max) fail(422, `${key} must be at most ${opts.max} characters.`);
    if (opts.pattern && !opts.pattern.test(s)) fail(422, `${key} has an invalid format.`);
    return s;
  }

  num(key: string, opts: { required?: boolean; min: number; max: number; int?: boolean }): number | null {
    const v = this.data[key];
    if (v === undefined || v === null) {
      if (opts.required) fail(422, `${key} is required.`);
      return null;
    }
    if (typeof v !== 'number' || !Number.isFinite(v)) return fail(422, `${key} must be a number.`);
    if (opts.int && !Number.isInteger(v)) fail(422, `${key} must be a whole number.`);
    if (v < opts.min || v > opts.max) fail(422, `${key} must be between ${opts.min} and ${opts.max}.`);
    return v;
  }

  bool(key: string, fallback?: boolean): boolean {
    const v = this.data[key];
    if (v === undefined || v === null) {
      if (fallback === undefined) fail(422, `${key} is required.`);
      return fallback!;
    }
    if (typeof v !== 'boolean') fail(422, `${key} must be true or false.`);
    return v as boolean;
  }

  oneOf<T extends string>(key: string, values: readonly T[], fallback?: T): T {
    const v = this.data[key] ?? fallback;
    if (typeof v !== 'string' || !values.includes(v as T)) fail(422, `${key} must be one of: ${values.join(', ')}.`);
    return v as T;
  }
}

export const toBool = (v: unknown): boolean => v === 1 || v === true;
