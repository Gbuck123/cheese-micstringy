import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { query, withTransaction } from '../config/database';
import { env } from '../config/env';
import { redis } from '../config/redis';
import {
  UnauthorizedError,
  ConflictError,
  NotFoundError,
} from '../utils/errors';
import type { RegisterInput, LoginInput } from '../schemas';
import type { JwtPayload } from '../middleware/auth';

const SALT_ROUNDS = 12;
const REFRESH_TOKEN_BYTES = 48;

interface AuthTokens {
  access_token: string;
  refresh_token: string;
  expires_in: number; // seconds
}

interface UserRow {
  id: string;
  email: string;
  password_hash: string;
  role: 'admin' | 'operator' | 'guest';
  first_name: string;
  last_name: string;
  is_active: boolean;
}

export class AuthService {
  async register(input: RegisterInput): Promise<{ user: Omit<UserRow, 'password_hash'>; tokens: AuthTokens }> {
    // Check existing
    const existing = await query('SELECT 1 FROM users WHERE email = $1', [input.email]);
    if (existing.rows.length > 0) {
      throw new ConflictError('A user with this email already exists');
    }

    const passwordHash = await bcrypt.hash(input.password, SALT_ROUNDS);

    const result = await query<UserRow>(
      `INSERT INTO users (email, password_hash, first_name, last_name, company, phone, role)
       VALUES ($1, $2, $3, $4, $5, $6, 'operator')
       RETURNING id, email, role, first_name, last_name, is_active`,
      [input.email, passwordHash, input.first_name, input.last_name, input.company, input.phone]
    );

    const user = result.rows[0];
    const tokens = await this.generateTokens(user);

    return { user, tokens };
  }

  async login(input: LoginInput): Promise<{ user: Omit<UserRow, 'password_hash'>; tokens: AuthTokens }> {
    const result = await query<UserRow>(
      `SELECT id, email, password_hash, role, first_name, last_name, is_active
       FROM users WHERE email = $1`,
      [input.email]
    );

    if (result.rows.length === 0) {
      throw new UnauthorizedError('Invalid email or password');
    }

    const user = result.rows[0];

    if (!user.is_active) {
      throw new UnauthorizedError('Account has been deactivated');
    }

    const validPassword = await bcrypt.compare(input.password, user.password_hash);
    if (!validPassword) {
      throw new UnauthorizedError('Invalid email or password');
    }

    // Update last login
    await query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [user.id]);

    const tokens = await this.generateTokens(user, input.device_info);

    const { password_hash, ...safeUser } = user;
    return { user: safeUser, tokens };
  }

  async refreshAccessToken(refreshToken: string): Promise<AuthTokens> {
    const tokenHash = this.hashToken(refreshToken);

    const result = await query<{
      id: string;
      user_id: string;
      expires_at: Date;
      revoked_at: Date | null;
    }>(
      `SELECT rt.id, rt.user_id, rt.expires_at, rt.revoked_at
       FROM refresh_tokens rt
       WHERE rt.token_hash = $1`,
      [tokenHash]
    );

    if (result.rows.length === 0) {
      throw new UnauthorizedError('Invalid refresh token');
    }

    const storedToken = result.rows[0];

    if (storedToken.revoked_at) {
      // Token reuse detected - revoke all tokens for this user (security measure)
      await query(
        'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
        [storedToken.user_id]
      );
      throw new UnauthorizedError('Refresh token has been revoked. Please log in again.');
    }

    if (new Date(storedToken.expires_at) < new Date()) {
      throw new UnauthorizedError('Refresh token has expired');
    }

    // Rotate: revoke current token and issue new pair
    await query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1',
      [storedToken.id]
    );

    const userResult = await query<UserRow>(
      'SELECT id, email, role, first_name, last_name, is_active FROM users WHERE id = $1',
      [storedToken.user_id]
    );

    if (userResult.rows.length === 0 || !userResult.rows[0].is_active) {
      throw new UnauthorizedError('User account not found or deactivated');
    }

    return this.generateTokens(userResult.rows[0]);
  }

  async logout(refreshToken: string): Promise<void> {
    const tokenHash = this.hashToken(refreshToken);
    await query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = $1',
      [tokenHash]
    );
  }

  async logoutAllDevices(userId: string): Promise<void> {
    await query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
      [userId]
    );
    // Also blacklist all existing access tokens by incrementing a version counter in Redis
    await redis.incr(`auth:token_version:${userId}`);
  }

  // ------ Private helpers ------

  private async generateTokens(
    user: Pick<UserRow, 'id' | 'email' | 'role'>,
    deviceInfo?: Record<string, any>
  ): Promise<AuthTokens> {
    const payload: Omit<JwtPayload, 'iat' | 'exp'> = {
      sub: user.id,
      email: user.email,
      role: user.role,
    };

    const accessToken = jwt.sign(payload, env.JWT_ACCESS_SECRET, {
      expiresIn: env.JWT_ACCESS_EXPIRES_IN,
    });

    // Generate opaque refresh token
    const refreshToken = crypto.randomBytes(REFRESH_TOKEN_BYTES).toString('base64url');
    const tokenHash = this.hashToken(refreshToken);

    // Parse expiry
    const expiresIn = this.parseDuration(env.JWT_REFRESH_EXPIRES_IN);
    const expiresAt = new Date(Date.now() + expiresIn * 1000);

    await query(
      `INSERT INTO refresh_tokens (user_id, token_hash, device_info, expires_at)
       VALUES ($1, $2, $3, $4)`,
      [user.id, tokenHash, deviceInfo ? JSON.stringify(deviceInfo) : null, expiresAt]
    );

    // Parse access token expiry for response
    const accessExpiresIn = this.parseDuration(env.JWT_ACCESS_EXPIRES_IN);

    return {
      access_token: accessToken,
      refresh_token: refreshToken,
      expires_in: accessExpiresIn,
    };
  }

  private hashToken(token: string): string {
    return crypto.createHash('sha256').update(token).digest('hex');
  }

  private parseDuration(str: string): number {
    const match = str.match(/^(\d+)(s|m|h|d)$/);
    if (!match) return 900; // default 15m
    const val = parseInt(match[1], 10);
    switch (match[2]) {
      case 's': return val;
      case 'm': return val * 60;
      case 'h': return val * 3600;
      case 'd': return val * 86400;
      default: return 900;
    }
  }
}

export const authService = new AuthService();
