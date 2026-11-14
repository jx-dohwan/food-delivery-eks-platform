// Capture safe telemetry events separately from the fixture result JSON.
const diagnosticEvents = [];
const originalWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk, ...args) => {
  try { const event = JSON.parse(String(chunk)); if (event.event) { diagnosticEvents.push(event); return true; } } catch {}
  return originalWrite(chunk, ...args);
};
// Child-process fixture: tracing is initialized BEFORE any framework/AWS/HTTP
// imports. All AWS transport and trace export stay in memory (never call AWS).
const { tracingOptions } = require('../../dist/src/core/tracing/tracing');
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { InMemorySpanExporter } = require('@opentelemetry/sdk-trace-base');
const { ExportResultCode } = require('@opentelemetry/core');
const exporter = new InMemorySpanExporter();
const failure = process.argv.includes('--export-failure');
const options = tracingOptions({ OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: 'http://adot-collector:4318/v1/traces', OTEL_TRACES_SAMPLER_ARG: '1' }, failure
  ? { export: (_spans, done) => done({ code: ExportResultCode.FAILED }), shutdown: () => Promise.resolve() } : exporter);
const sdk = new NodeSDK(options);
sdk.start();

const { Controller, Get, Module } = require('@nestjs/common');
const { NestFactory } = require('@nestjs/core');
const http = require('node:http');
const { Readable } = require('node:stream');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { SESClient, SendEmailCommand } = require('@aws-sdk/client-ses');
const secret = 'PRIVATE_EMAIL@example.com';
// Explicit fixture credentials avoid consulting IRSA/IMDS or a local AWS profile.
const aws = { region: 'ap-northeast-2', credentials: { accessKeyId: 'TEST_ONLY', secretAccessKey: 'TEST_ONLY' },
  requestHandler: { handle: async () => ({ response: { statusCode: 200, headers: {}, body: Readable.from(
    '<SendEmailResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/"><SendEmailResult><MessageId>test</MessageId></SendEmailResult><ResponseMetadata><RequestId>test</RequestId></ResponseMetadata></SendEmailResponse>') } }) } };
const s3 = new S3Client(aws);
const ses = new SESClient(aws);
let upstreamPort;
function request(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path, headers }, response => {
      response.resume(); response.on('end', () => resolve(response.statusCode));
    }).on('error', reject);
  });
}
class TraceController {
  async business() {
    await s3.send(new PutObjectCommand({ Bucket: 'private-test-bucket', Key: 'common/private-user', Body: secret }));
    await ses.send(new SendEmailCommand({ Source: secret, Destination: { ToAddresses: [secret] }, Message: { Subject: { Data: secret }, Body: { Text: { Data: secret } } } }));
    await request(upstreamPort, '/upstream/123?token=SECRET_JWT');
    return { status: 'ok' };
  }
  fail() { throw new Error('SECRET_ERROR_WITH_PASSWORD'); }
  health() { return { status: 'ok' }; }
}
Controller()(TraceController);
for (const [method, path] of [['business', 'trace/:id'], ['fail', 'fail'], ['health', ['health/live', 'metrics']]]) {
  Get(path)(TraceController.prototype, method, Object.getOwnPropertyDescriptor(TraceController.prototype, method));
}
class TraceModule {}
Module({ controllers: [TraceController] })(TraceModule);

(async () => {
  const upstream = http.createServer((_req, res) => res.end('ok'));
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  upstreamPort = upstream.address().port;
  const app = await NestFactory.create(TraceModule, { logger: false });
  await app.listen(0, '127.0.0.1');
  const port = app.getHttpServer().address().port;
  const status = await request(port, '/trace/123?email=PRIVATE_EMAIL%40example.com', { Authorization: 'Bearer SECRET_JWT', Cookie: 'SECRET_COOKIE' });
  const errorStatus = await request(port, '/fail');
  await options.spanProcessors[0].forceFlush().catch(error => { if (!failure) throw error; });
  const before = exporter.getFinishedSpans().length;
  await request(port, '/health/live');
  await request(port, '/metrics');
  await options.spanProcessors[0].forceFlush().catch(error => { if (!failure) throw error; });
  const spans = exporter.getFinishedSpans().map(span => ({ name: span.name, kind: span.kind,
    trace: span.spanContext().traceId, id: span.spanContext().spanId, parent: span.parentSpanContext?.spanId,
    attributes: span.attributes, events: span.events, status: span.status, resource: span.resource.attributes }));
  for (const span of exporter.getFinishedSpans()) {
    if (!span.duration || !span.ended) throw new Error('Incomplete ReadableSpan');
  }
  // Use the same serializer as the pinned HTTP/JSON exporter, without sending
  // any network request. This catches missing SDK prototype getters as well.
  const { JsonTraceSerializer } = require('@opentelemetry/otlp-transformer');
  const wire = JSON.parse(Buffer.from(JsonTraceSerializer.serializeRequest(exporter.getFinishedSpans())).toString());
  const noise = exporter.getFinishedSpans().length - before;
  await app.close();
  await new Promise(resolve => upstream.close(resolve));
  await require('../../dist/src/core/tracing/tracing').boundedTraceShutdown(() => sdk.shutdown());
  s3.destroy(); ses.destroy();
  console.log(JSON.stringify({ status, errorStatus, noise, spans, wire, diagnosticEvents }));
})().catch(() => { console.error('Local tracing fixture failed'); process.exitCode = 1; });
