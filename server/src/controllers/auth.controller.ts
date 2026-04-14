import { Request, Response, NextFunction } from 'express';
import { authService } from '../services/auth.service';
import type { RegisterInput, LoginInput } from '../schemas';

export async function register(req: Request, res: Response, next: NextFunction) {
  try {
    const input: RegisterInput = req.body;
    const result = await authService.register(input);

    res.status(201).json({
      user: result.user,
      tokens: result.tokens,
    });
  } catch (error) {
    next(error);
  }
}

export async function login(req: Request, res: Response, next: NextFunction) {
  try {
    const input: LoginInput = req.body;
    const result = await authService.login(input);

    res.json({
      user: result.user,
      tokens: result.tokens,
    });
  } catch (error) {
    next(error);
  }
}

export async function refreshToken(req: Request, res: Response, next: NextFunction) {
  try {
    const { refresh_token } = req.body;
    const tokens = await authService.refreshAccessToken(refresh_token);

    res.json({ tokens });
  } catch (error) {
    next(error);
  }
}

export async function logout(req: Request, res: Response, next: NextFunction) {
  try {
    const { refresh_token } = req.body;
    await authService.logout(refresh_token);

    res.json({ message: 'Logged out successfully' });
  } catch (error) {
    next(error);
  }
}

export async function logoutAll(req: Request, res: Response, next: NextFunction) {
  try {
    await authService.logoutAllDevices(req.user!.sub);

    res.json({ message: 'Logged out from all devices' });
  } catch (error) {
    next(error);
  }
}

export async function me(req: Request, res: Response, next: NextFunction) {
  try {
    const { query: dbQuery } = await import('../config/database');
    const result = await dbQuery(
      `SELECT id, email, role, first_name, last_name, company, phone,
              avatar_url, is_active, email_verified, last_login_at, created_at
       FROM users WHERE id = $1`,
      [req.user!.sub]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: { message: 'User not found' } });
    }

    res.json({ user: result.rows[0] });
  } catch (error) {
    next(error);
  }
}
