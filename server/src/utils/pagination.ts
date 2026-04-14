import { PaginationInput } from '../schemas';

export interface PaginatedResult<T> {
  data: T[];
  pagination: {
    page: number;
    limit: number;
    total: number;
    total_pages: number;
    has_next: boolean;
    has_prev: boolean;
  };
}

export function buildPaginationClause(input: PaginationInput): {
  limit: number;
  offset: number;
  orderClause: string;
} {
  const limit = input.limit;
  const offset = (input.page - 1) * limit;
  const sortCol = input.sort_by || 'created_at';
  const sortDir = input.sort_order.toUpperCase();
  const orderClause = `ORDER BY ${sortCol} ${sortDir}`;
  return { limit, offset, orderClause };
}

export function formatPaginatedResponse<T>(
  data: T[],
  total: number,
  page: number,
  limit: number
): PaginatedResult<T> {
  const total_pages = Math.ceil(total / limit);
  return {
    data,
    pagination: {
      page,
      limit,
      total,
      total_pages,
      has_next: page < total_pages,
      has_prev: page > 1,
    },
  };
}
