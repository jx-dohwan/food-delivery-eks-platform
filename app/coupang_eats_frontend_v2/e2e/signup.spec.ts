/**
 * 사람이 브라우저에서 하는 것과 같은 회원가입 E2E (Playwright)
 *
 * 설치(최초 1회):
 *   cd app/coupang_eats_frontend_v2 && npm i -D @playwright/test && npx playwright install chromium
 *
 * 실행:
 *   BASE_URL=https://dev.example.com npx playwright test e2e/signup.spec.ts --headed
 */
import { test, expect } from '@playwright/test';

const BASE_URL = process.env.BASE_URL ?? 'https://dev.example.com';

test.describe('회원가입 (사람처럼 클릭)', () => {
  test('로그인 → 계정 만들기 → 폼 제출 → 성공 메시지', async ({ page }) => {
    const email = `e2e-${Date.now()}@example.com`;

    await page.goto(BASE_URL);
    await expect(page.getByPlaceholder('이메일')).toBeVisible();

    await page.getByRole('link', { name: '계정 만들기' }).click();
    await expect(page).toHaveURL(/\/create-account/);

    await page.getByPlaceholder('이름').fill('E2E Tester');
    await page.getByPlaceholder('이메일').fill(email);
    await page.getByPlaceholder(/비밀번호/).fill('Password123!');
    await page.getByRole('button', { name: '계정 만들기' }).click();

    await expect(
      page.getByText(/계정이 생성되었습니다|이메일 인증/),
    ).toBeVisible({ timeout: 15000 });
  });
});
