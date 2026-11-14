#!/usr/bin/env ruby
# Offline config/render/privacy/identity regression. No AWS, kubectl or Docker.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

class DistributedTracingTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KUSTOMIZE = ENV.fetch('KUSTOMIZE_BIN', 'kustomize')
  RENDERS = %w[dev prod].to_h do |environment|
    out, err, status = Open3.capture3(KUSTOMIZE, 'build', "#{ROOT}/k8s/overlays/#{environment}")
    raise err unless status.success?
    [environment, YAML.load_stream(out).compact]
  end

  def test_collector_pipeline_is_trace_only_and_bounded
    RENDERS.each_value do |docs|
      config = docs.find { |r| r['kind'] == 'ConfigMap' && r.dig('metadata', 'name') == 'adot-collector-config' }
      parsed = YAML.load(config.dig('data', 'collector.yaml'))
      assert_equal ['otlp'], parsed.fetch('receivers').keys
      assert_equal({'http' => {'endpoint' => '0.0.0.0:4318'}}, parsed.dig('receivers', 'otlp', 'protocols'))
      assert_equal ['traces'], parsed.dig('service', 'pipelines').keys
      assert_equal ['memory_limiter', 'batch'], parsed.dig('service', 'pipelines', 'traces', 'processors')
      assert_equal ['awsxray'], parsed.fetch('exporters').keys
      assert_equal 'ap-northeast-2', parsed.dig('exporters', 'awsxray', 'region')
      assert_equal true, parsed.dig('exporters', 'awsxray', 'local_mode')
      assert_equal false, parsed.dig('exporters', 'awsxray', 'telemetry', 'enabled')
      assert_equal false, parsed.dig('exporters', 'awsxray', 'index_all_attributes')
      assert_equal 160, parsed.dig('processors', 'memory_limiter', 'limit_mib')
      assert_equal 128, parsed.dig('processors', 'batch', 'send_batch_max_size')
      refute parsed.key?('extensions')
    end
  end

  def test_collector_is_private_restricted_and_has_a_distinct_identity
    RENDERS.each do |environment, docs|
      namespace = environment == 'dev' ? 'app' : 'app-prod'
      service = docs.find { |r| r['kind'] == 'Service' && r.dig('metadata', 'name') == 'adot-collector' }
      assert_equal namespace, service.dig('metadata', 'namespace')
      assert_equal 'ClusterIP', service.dig('spec', 'type')
      assert_equal [4318, 8888], service.dig('spec', 'ports').map { |p| p['port'] }
      sa = docs.find { |r| r['kind'] == 'ServiceAccount' && r.dig('metadata', 'name') == 'adot-collector' }
      assert_equal namespace, sa.dig('metadata', 'namespace')
      assert_equal 'true', sa.dig('metadata', 'annotations', 'eks.amazonaws.com/sts-regional-endpoints')
      refute sa['automountServiceAccountToken']
      deployment = docs.find { |r| r['kind'] == 'Deployment' && r.dig('metadata', 'name') == 'adot-collector' }
      assert_equal 1, deployment.dig('spec', 'replicas')
      pod = deployment.dig('spec', 'template', 'spec')
      assert_equal 'adot-collector', pod['serviceAccountName']
      assert_equal 15, pod['terminationGracePeriodSeconds']
      refute pod['hostNetwork']
      refute pod['hostPID']
      assert_equal true, pod.dig('securityContext', 'runAsNonRoot')
      container = pod['containers'].first
      assert_equal 'public.ecr.aws/aws-observability/aws-otel-collector:v0.50.0', container['image']
      assert_equal ['ALL'], container.dig('securityContext', 'capabilities', 'drop')
      refute container.dig('securityContext', 'allowPrivilegeEscalation')
      assert_equal true, container.dig('securityContext', 'readOnlyRootFilesystem')
      assert_equal({'cpu' => '50m', 'memory' => '96Mi'}, container.dig('resources', 'requests'))
      assert_equal({'cpu' => '250m', 'memory' => '256Mi'}, container.dig('resources', 'limits'))
      assert_equal 'true', container['env'].find { |e| e['name'] == 'AWS_EC2_METADATA_DISABLED' }['value']
      refute docs.any? { |r| r['kind'] == 'Ingress' && r.to_s.include?('adot-collector') }
    end
  end

  def test_was_config_preserves_metrics_and_uses_internal_otlp
    RENDERS.each_value do |docs|
      config = docs.find { |r| r['kind'] == 'ConfigMap' && r.dig('metadata', 'name') == 'was-config' }['data']
      assert_equal 'otlp', config['OTEL_TRACES_EXPORTER']
      assert_equal 'none', config['OTEL_METRICS_EXPORTER']
      assert_equal 'none', config['OTEL_LOGS_EXPORTER']
      assert_equal '0.1', config['OTEL_TRACES_SAMPLER_ARG']
      assert_equal 'http://adot-collector:4318/v1/traces', config['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT']
    end
    assert File.read("#{ROOT}/app/coupang_eats_backend_v2/src/main.ts").start_with?("import './instrumentation';")
    %w[food_delivery_http_requests_total food_delivery_http_request_duration_seconds].each do |metric|
      assert_includes File.read("#{ROOT}/app/coupang_eats_backend_v2/src/core/metrics/metrics.service.ts"), metric
    end
  end

  def test_sdk_packages_are_pinned_and_legacy_components_are_absent
    pkg = JSON.parse(File.read("#{ROOT}/app/coupang_eats_backend_v2/package.json"))
    otel = pkg['dependencies'].select { |name, _| name.start_with?('@opentelemetry/') }
    assert_operator otel.length, :>=, 10
    otel.each_value { |version| assert_match(/\A\d+\.\d+\.\d+\z/, version) }
    refute pkg['dependencies'].keys.any? { |name| name.start_with?('aws-xray-sdk') }
    text = Dir["#{ROOT}/k8s/base/tracing/*.yaml"].map { |p| File.read(p) }.join
    refute_match(/xray-daemon|awsxrayreceiver|port:\s*2000|containerPort:\s*2000/, text)
    # Collector policy is the only new X-Ray identity; WAS/Node role sources stay separate.
    %w[iam.tf workload-irsa.tf karpenter.tf].each do |file|
      refute_includes File.read("#{ROOT}/infra/modules/eks/#{file}"), 'xray:'
    end
  end

  def test_terraform_output_renders_both_environment_annotations_without_copying_arns
    Dir.mktmpdir('tracing-render') do |dir|
      FileUtils.cp_r("#{ROOT}/k8s", dir)
      %w[dev prod].each do |environment|
        fixture = { environment: environment, namespace: environment == 'dev' ? 'app' : 'app-prod',
          account_id: '123456789012', region: 'ap-northeast-2', service_account: 'adot-collector',
          role_arn: "arn:aws:iam::123456789012:role/test-#{environment}-adot" }
        patch = "#{dir}/k8s/overlays/#{environment}/tracing-irsa-patch.yaml"
        _, err, status = Open3.capture3('python3', "#{ROOT}/scripts/render-tracing-irsa.py", '--environment', environment, '--output', patch, stdin_data: JSON.generate(fixture))
        assert status.success?, err
        out, err, status = Open3.capture3(KUSTOMIZE, 'build', File.dirname(patch))
        assert status.success?, err
        sa = YAML.load_stream(out).compact.find { |r| r['kind'] == 'ServiceAccount' && r.dig('metadata', 'name') == 'adot-collector' }
        assert_equal fixture[:namespace], sa.dig('metadata', 'namespace')
        assert_equal fixture[:role_arn], sa.dig('metadata', 'annotations', 'eks.amazonaws.com/role-arn')
        before = File.read(patch)
        %w[account_id namespace environment service_account region role_arn].each do |key|
          bad = fixture.merge(key.to_sym => 'wrong')
          _, _, status = Open3.capture3('python3', "#{ROOT}/scripts/render-tracing-irsa.py", '--environment', environment, '--output', patch, stdin_data: JSON.generate(bad))
          refute status.success?
          assert_equal before, File.read(patch)
        end
      end
    end
  end
end
