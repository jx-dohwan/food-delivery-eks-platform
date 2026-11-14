import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { INotificationService } from './notification.interface';
import { LoggerService } from '../logger/logger.service';
import { AwsSesService } from '../aws/aws-ses.service';
import { Configurations } from '../config';
import { DevEmailCaptureService } from './dev-email-capture.service';

@Injectable()
export class EmailService implements INotificationService {
  constructor(
    private readonly loggerService: LoggerService,
    private readonly awsSesService: AwsSesService,
    private readonly configService: ConfigService<Configurations>,
    private readonly devEmailCapture: DevEmailCaptureService,
  ) {}

  async sendWelcomeNotification(
    email: string,
    nickname: string,
    token: string,
  ): Promise<void> {
    const baseUrl = this.configService.get('APP.BASE_URL', { infer: true });
    const verifyUrl = `${baseUrl}/verify-email?token=${token}`;

    if (this.devEmailCapture.capture(email, verifyUrl)) return;

    this.loggerService.info(
      this.sendWelcomeNotification.name,
      { email },
      'Sending welcome email',
    );

    // HTML 메일 내용 작성
    const subject = `[Food Delivery] ${nickname}님, 이메일 인증을 완료해주세요.`;
    const htmlBody = `
      <div style="padding: 20px; border: 1px solid #ddd;">
        <h3>이메일 인증</h3>
        <p>아래 링크를 클릭하여 인증을 완료하세요</p>
        <a href="${verifyUrl}" style="padding: 10px; background: blue; color: white;">인증하기</a>
        <br>
        <small>${verifyUrl}</small>
      </div>
    `;

    // AWS 스모크/로컬: SES 미구성 시 회원가입이 막히지 않도록 스킵
    const senderEmail =
      this.configService.get('AWS.SES_SENDER_EMAIL', { infer: true }) || '';
    if (process.env.SKIP_EMAIL_NOTIFICATION === 'true' || !senderEmail.trim()) {
      this.loggerService.info(
        this.sendWelcomeNotification.name,
        { skipped: true, senderConfigured: Boolean(senderEmail.trim()) },
        'SES skipped',
      );
      return;
    }

    //  실제 전송 (Keyless)
    // 샌드박스 모드에서는 '수신자(email)'도 AWS 콘솔에서 검증된 이메일이어야 합니다.
    await this.awsSesService.sendEmail(email, subject, htmlBody);

    this.loggerService.info(
      this.sendWelcomeNotification.name,
      { email },
      'Email sent successfully',
    );
  }
}
