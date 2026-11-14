import { minutes, type ThrottlerModuleOptions } from '@nestjs/throttler';

export const RATE_LIMITS = {
  signIn: { limit: 12, ttl: minutes(1) },
  signUp: { limit: 6, ttl: minutes(10) },
  refresh: { limit: 30, ttl: minutes(1) },
  verifyEmail: { limit: 12, ttl: minutes(5) },
  signOut: { limit: 30, ttl: minutes(1) },
  profile: { limit: 10, ttl: minutes(1) },
  restaurantCreate: { limit: 10, ttl: minutes(1) },
  mutation: { limit: 30, ttl: minutes(1) },
  orderCreate: { limit: 20, ttl: minutes(1) },
  orderStatus: { limit: 60, ttl: minutes(1) },
  payment: { limit: 20, ttl: minutes(1) },
  reviewCreate: { limit: 10, ttl: minutes(1) },
  categoryCreate: { limit: 15, ttl: minutes(1) },
  upload: { limit: 12, ttl: minutes(1) },
  uploadBatch: { limit: 8, ttl: minutes(1) },
};

export function rateLimitOptions(): ThrottlerModuleOptions {
  return {
    errorMessage: 'Too many requests. Please try again later.',
    throttlers: [
      { name: 'baseline', limit: 600, ttl: minutes(1) },
      { name: 'default', limit: 120, ttl: minutes(1) },
    ],
  };
}
