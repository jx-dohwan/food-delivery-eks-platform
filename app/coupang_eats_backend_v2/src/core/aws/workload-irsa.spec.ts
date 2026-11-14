import { ConfigService } from '@nestjs/config';
import { InternalServerErrorException } from '@nestjs/common';
import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { SendEmailCommand, SESClient } from '@aws-sdk/client-ses';
import { AwsS3Service } from './aws-s3.service';
import { AwsSesService } from './aws-ses.service';
import { Configurations } from '../config';
import { MoinConfigService } from '../config/config.service';

describe('Workload AWS access (SDK transport mocked, no AWS)', () => {
  const aws = {
    REGION: 'ap-northeast-2',
    S3_BUCKET_NAME: 'food-delivery-dev-assets-test',
    SES_SENDER_EMAIL: 'sender@example.com',
    CDN_URL: '',
  };
  const file = (size = 1024): Express.Multer.File =>
    ({
      buffer: Buffer.alloc(size),
      originalname: 'image.png',
      mimetype: 'image/png',
      size,
    }) as Express.Multer.File;
  let logs: jest.SpyInstance;
  let errors: jest.SpyInstance;

  beforeEach(() => {
    logs = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    errors = jest.spyOn(console, 'error').mockImplementation(() => undefined);
  });
  afterEach(() => jest.restoreAllMocks());

  function s3() {
    return new AwsS3Service(new ConfigService<Configurations>({ AWS: aws }));
  }
  function ses() {
    return new AwsSesService({
      getAwsConfig: () => aws,
    } as MoinConfigService);
  }

  it.each([1, 5 * 1024 * 1024])(
    'uploads %i bytes using only PutObject, including the controller size ceiling',
    async (size) => {
      const send = jest
        .spyOn(S3Client.prototype, 'send')
        .mockResolvedValue({ ETag: 'test-etag' } as never);
      const url = await s3().uploadImage('restaurant', file(size));
      const calls = send.mock.calls.map(
        ([command]) => command as PutObjectCommand,
      );
      expect(calls).toHaveLength(1);
      expect(calls[0]).toBeInstanceOf(PutObjectCommand);
      expect(calls[0].input.Bucket).toBe(aws.S3_BUCKET_NAME);
      expect(calls[0].input.Key).toMatch(/^restaurant\/[a-f0-9-]{36}\.png$/);
      expect(calls[0].input.ACL).toBeUndefined();
      expect(calls[0].input.Tagging).toBeUndefined();
      expect(url).not.toContain('?');
    },
  );

  it('batch uploads produce distinct server-generated keys in an allowed prefix', async () => {
    const send = jest
      .spyOn(S3Client.prototype, 'send')
      .mockResolvedValue({ ETag: 'test' } as never);
    await s3().uploadImages('dish', [file(), file()]);
    const keys = send.mock.calls.map(([command]) => {
      expect(command).toBeInstanceOf(PutObjectCommand);
      return (command as PutObjectCommand).input.Key!;
    });
    expect(new Set(keys).size).toBe(2);
    expect(keys.every((key) => key.startsWith('dish/'))).toBe(true);
  });

  it('uses SendEmail with the configured From address and supplied verification recipient', async () => {
    const send = jest
      .spyOn(SESClient.prototype, 'send')
      .mockResolvedValue({} as never);
    await ses().sendEmail(
      'recipient@example.com',
      'Verify',
      '<p>verification</p>',
    );
    const command = send.mock.calls[0][0] as SendEmailCommand;
    expect(command).toBeInstanceOf(SendEmailCommand);
    expect(command.input.Source).toBe(aws.SES_SENDER_EMAIL);
    expect(command.input.Destination?.ToAddresses).toEqual([
      'recipient@example.com',
    ]);
    expect(JSON.stringify(logs.mock.calls)).not.toContain(
      'recipient@example.com',
    );
  });

  it.each(['AccessDenied', 'CredentialsProviderError'])(
    'redacts %s SDK failures from service exceptions and SES logs',
    async (name) => {
      const secret =
        'SECRET_STS_TOKEN bucket-private arn:aws:iam::123456789012:role/private';
      const failure = Object.assign(new Error(secret), { name });
      jest
        .spyOn(S3Client.prototype, 'send')
        .mockRejectedValue(failure as never);
      jest
        .spyOn(SESClient.prototype, 'send')
        .mockRejectedValue(failure as never);
      for (const operation of [
        () => s3().uploadImage('common', file()),
        () => ses().sendEmail('recipient@example.com', 'Verify', 'body'),
      ]) {
        const error: unknown = await operation().catch(
          (caught: unknown) => caught,
        );
        expect(error).toBeInstanceOf(InternalServerErrorException);
        expect(
          JSON.stringify((error as InternalServerErrorException).getResponse()),
        ).not.toContain(secret);
      }
      expect(JSON.stringify(errors.mock.calls)).not.toContain(secret);
    },
  );
});
