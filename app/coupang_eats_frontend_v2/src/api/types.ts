export type ApiSuccess<T> = {
  success: true;
  data: T;
};

export type ApiErrorBody = {
  success: false;
  statusCode?: number;
  message?: string;
  path?: string;
  error?: string;
};

export type AccessTokenResponse = {
  accessToken: string;
};

export type SignInBody = {
  email: string;
  password: string;
};

export type SignUpRole = 'Client' | 'Owner' | 'Delivery';

export type SignUpBody = {
  email: string;
  password: string;
  name: string;
  role: SignUpRole;
};
