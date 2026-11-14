import { ConfigService } from '@nestjs/config';
import { AwsSesService } from '../aws/aws-ses.service';
import { Configurations } from '../config';
import { LoggerService } from '../logger/logger.service';
import { DevEmailCaptureService } from './dev-email-capture.service';
import { EmailService } from './email.service';

describe('Local email safety (SES transport replaced, no external email)', () => {
  const originalSkip = process.env.SKIP_EMAIL_NOTIFICATION;
  afterEach(() => {
    if (originalSkip === undefined) delete process.env.SKIP_EMAIL_NOTIFICATION;
    else process.env.SKIP_EMAIL_NOTIFICATION = originalSkip;
  });

  function fixture(sender = 'sender@example.invalid') {
    const sendEmail = jest.fn().mockResolvedValue(undefined);
    const service = new EmailService(
      { info: jest.fn() } as unknown as LoggerService,
      { sendEmail } as unknown as AwsSesService,
      {
        get: (key: string) =>
          key === 'APP.BASE_URL' ? 'https://example.invalid' : sender,
      } as unknown as ConfigService<Configurations>,
      { capture: () => false } as unknown as DevEmailCaptureService,
    );
    return { service, sendEmail };
  }

  it('explicit skip prevents transport even when a sender exists', async () => {
    process.env.SKIP_EMAIL_NOTIFICATION = 'true';
    const { service, sendEmail } = fixture();
    await service.sendWelcomeNotification('recipient@example.invalid', 'Test', 'synthetic-token');
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it('empty sender independently prevents transport', async () => {
    process.env.SKIP_EMAIL_NOTIFICATION = 'false';
    const { service, sendEmail } = fixture('');
    await service.sendWelcomeNotification('recipient@example.invalid', 'Test', 'synthetic-token');
    expect(sendEmail).not.toHaveBeenCalled();
  });

  it('configured sender and false invoke only the mocked transport', async () => {
    process.env.SKIP_EMAIL_NOTIFICATION = 'false';
    const { service, sendEmail } = fixture();
    await service.sendWelcomeNotification('recipient@example.invalid', 'Test', 'synthetic-token');
    expect(sendEmail).toHaveBeenCalledTimes(1);
  });

  it('absence of skip is not an approval barrier in the existing service', async () => {
    delete process.env.SKIP_EMAIL_NOTIFICATION;
    const { service, sendEmail } = fixture();
    await service.sendWelcomeNotification('recipient@example.invalid', 'Test', 'synthetic-token');
    expect(sendEmail).toHaveBeenCalledTimes(1);
  });
});
