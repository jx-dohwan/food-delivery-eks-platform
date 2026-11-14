#!/usr/bin/env ruby
# Offline only: render manifests and stub kubectl. No cluster or load calls.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

class HpaTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  RENDERS = %w[dev prod].to_h do |environment|
    out, err, status = Open3.capture3(ENV.fetch('KUSTOMIZE_BIN', 'kustomize'), 'build', "#{ROOT}/k8s/overlays/#{environment}")
    raise err unless status.success?
    [environment, YAML.load_stream(out).compact]
  end

  def deployment(resources, app)
    resources.find { |r| r['kind'] == 'Deployment' && r.dig('metadata', 'labels', 'app') == app }
  end

  def test_exactly_one_hpa_targets_the_existing_was_in_each_namespace
    RENDERS.each do |environment, resources|
      hpas = resources.select { |r| r['kind'] == 'HorizontalPodAutoscaler' }
      assert_equal 1, hpas.size
      hpa = hpas.first
      was = deployment(resources, 'was')
      assert_equal 'autoscaling/v2', hpa['apiVersion']
      assert_equal 'was-hpa', hpa.dig('metadata', 'name')
      assert_equal environment == 'dev' ? 'app' : 'app-prod', hpa.dig('metadata', 'namespace')
      assert_equal was.dig('metadata', 'namespace'), hpa.dig('metadata', 'namespace')
      assert_equal({'apiVersion' => 'apps/v1', 'kind' => 'Deployment', 'name' => was.dig('metadata', 'name')}, hpa.dig('spec', 'scaleTargetRef'))
      refute_equal deployment(resources, 'web').dig('metadata', 'name'), hpa.dig('spec', 'scaleTargetRef', 'name')
      resources.select { |r| r['kind'] == 'Job' }.each { |job| refute_equal job.dig('metadata', 'name'), hpa.dig('spec', 'scaleTargetRef', 'name') }
    end
  end

  def test_cpu_only_utilization_and_realistic_unchanged_requests
    RENDERS.each_value do |resources|
      hpa = resources.find { |r| r['kind'] == 'HorizontalPodAutoscaler' }
      assert_equal [{'type' => 'Resource', 'resource' => {'name' => 'cpu', 'target' => {'type' => 'Utilization', 'averageUtilization' => 65}}}], hpa.dig('spec', 'metrics')
      containers = deployment(resources, 'was').dig('spec', 'template', 'spec', 'containers')
      assert_equal 1, containers.size
      assert_equal({'requests' => {'cpu' => '250m', 'memory' => '512Mi'}, 'limits' => {'cpu' => '500m', 'memory' => '1Gi'}}, containers.first['resources'])
    end
  end

  def test_environment_budgets_and_initial_replica_counts_agree
    RENDERS.each do |environment, resources|
      spec = resources.find { |r| r['kind'] == 'HorizontalPodAutoscaler' }.fetch('spec')
      assert_equal environment == 'dev' ? 2 : 3, spec.fetch('minReplicas')
      assert_equal environment == 'dev' ? 5 : 6, spec.fetch('maxReplicas')
      assert_equal spec.fetch('minReplicas'), deployment(resources, 'was').dig('spec', 'replicas')
      assert_equal 2, deployment(resources, 'web').dig('spec', 'replicas')
      assert_operator spec.fetch('minReplicas'), :<, spec.fetch('maxReplicas')
    end
  end

  def test_scaling_is_enabled_bounded_and_downscale_is_more_conservative
    RENDERS.each_value do |resources|
      behavior = resources.find { |r| r['kind'] == 'HorizontalPodAutoscaler' }.dig('spec', 'behavior')
      %w[scaleUp scaleDown].each do |direction|
        assert_equal 'Max', behavior.dig(direction, 'selectPolicy')
        policies = behavior.fetch(direction).fetch('policies')
        assert_equal 1, policies.size
        assert_equal 'Pods', policies.first.fetch('type')
        assert_equal 1, policies.first.fetch('value')
        assert_equal direction == 'scaleUp' ? 30 : 60, policies.first.fetch('periodSeconds')
      end
      assert_equal 0, behavior.dig('scaleUp', 'stabilizationWindowSeconds')
      assert_equal 300, behavior.dig('scaleDown', 'stabilizationWindowSeconds')
    end
  end

  def test_argo_ignores_only_live_was_replica_differences_in_diff_and_sync
    {'dev' => 'argocd-app.yaml', 'prod' => 'argocd-app-prod.yaml'}.each do |environment, file|
      app = YAML.load_file("#{ROOT}/#{file}")
      namespace = environment == 'dev' ? 'app' : 'app-prod'
      assert_equal [{'group' => 'apps', 'kind' => 'Deployment', 'name' => 'was-deployment', 'namespace' => namespace, 'jsonPointers' => ['/spec/replicas']}], app.dig('spec', 'ignoreDifferences')
      assert_includes app.dig('spec', 'syncPolicy', 'syncOptions'), 'RespectIgnoreDifferences=true'
      assert_equal "k8s/overlays/#{environment}", app.dig('spec', 'source', 'path')
      assert_equal 'main', app.dig('spec', 'source', 'targetRevision')
    end
    assert_equal true, YAML.load_file("#{ROOT}/argocd-app.yaml").dig('spec', 'syncPolicy', 'automated', 'selfHeal')
    refute YAML.load_file("#{ROOT}/argocd-app-prod.yaml").dig('spec', 'syncPolicy').key?('automated')
  end

  def test_pdb_readiness_and_shutdown_remain_compatible
    RENDERS.each_value do |resources|
      was = deployment(resources, 'was')
      pod = was.dig('spec', 'template', 'spec')
      container = pod.fetch('containers').first
      pdb = resources.find { |r| r['kind'] == 'PodDisruptionBudget' && r.dig('metadata', 'name') == 'was-pdb' }
      pdb.dig('spec', 'selector', 'matchLabels').each { |k, v| assert_equal v, was.dig('spec', 'template', 'metadata', 'labels', k) }
      assert_equal 1, pdb.dig('spec', 'maxUnavailable')
      assert_equal 60, pod['terminationGracePeriodSeconds']
      assert_equal '/health/ready', container.dig('readinessProbe', 'httpGet', 'path')
      assert_equal 150, container.dig('startupProbe', 'periodSeconds') * container.dig('startupProbe', 'failureThreshold')
      assert_equal({'maxSurge' => 1, 'maxUnavailable' => 0}, was.dig('spec', 'strategy', 'rollingUpdate'))
      refute_equal 'was-migration', pdb.dig('spec', 'selector', 'matchLabels', 'app')
    end
  end

  def test_metrics_server_is_single_pinned_and_independent_of_prometheus
    text = Dir["#{ROOT}/infra/modules/eks/*.tf"].map { |p| File.read(p) }.join("\n")
    assert_equal 1, text.scan(/resource "helm_release" "metrics_server"/).size
    block = text.split('resource "helm_release" "metrics_server" {', 2).last.split('# ==============================================================================', 2).first
    assert_match(/version\s*=\s*"3\.14\.0"/, block)
    assert_includes block, '--kubelet-preferred-address-types=InternalIP'
    refute_match(/observability|prometheus|grafana|adapter|keda/i, block)
    values = YAML.load_file("#{ROOT}/infra/modules/eks/observability/values.yaml")
    assert_includes values.dig('kube-state-metrics', 'collectors'), 'horizontalpodautoscalers'
  end

  def test_dashboard_has_exact_stable_hpa_replica_metric_selectors
    dashboard = JSON.parse(File.read("#{ROOT}/infra/modules/eks/observability/food-delivery-overview.json"))
    panels = dashboard.fetch('panels')
    assert_equal 19, panels.size
    %w[current desired].each do |state|
      panel = panels.find { |p| p.fetch('title') == "HPA #{state.capitalize} Replicas" }
      refute_nil panel
      assert_equal 'prometheus', panel.dig('datasource', 'uid')
      assert_equal "kube_horizontalpodautoscaler_status_#{state}_replicas{namespace=~\"$namespace\",horizontalpodautoscaler=\"was-hpa\"}", panel.dig('targets', 0, 'expr')
    end
    ['WAS CPU', 'WAS Replicas', 'Pending Pods', 'Node Count', 'HTTP Request Rate', 'HTTP p95 Latency', 'HTTP 5xx Error Rate'].each { |title| assert panels.any? { |p| p['title'] == title } }
  end

  def with_kubectl_stub
    Dir.mktmpdir('food-hpa-offline-') do |dir|
      log = "#{dir}/calls.jsonl"
      File.write("#{dir}/kubectl", "#!/usr/bin/env ruby\nrequire 'json'\nFile.open(ENV.fetch('HPA_TEST_LOG'), 'a') { |f| f.puts JSON.generate(ARGV) }\nputs 'offline fixture'\n")
      FileUtils.chmod(0755, "#{dir}/kubectl")
      env = {'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'HPA_TEST_LOG' => log}
      yield env, log
    end
  end

  def test_evidence_helper_never_starts_load_or_mutates_cluster
    with_kubectl_stub do |env, log|
      out, err, status = Open3.capture3(env.merge('NS' => 'app'), 'bash', "#{ROOT}/scripts/verify-hpa.sh")
      assert status.success?, err
      assert_includes out, 'No load was started'
      calls = File.readlines(log).map { |l| JSON.parse(l) }
      assert_equal 7, calls.size
      assert calls.all? { |args| %w[get describe top].include?(args.first) }
      assert calls.any? { |args| args.first(3) == %w[get hpa was-hpa] }
      refute_includes File.read("#{ROOT}/scripts/verify-hpa.sh"), 'stress-signup.sh'
    end
  end

  def test_evidence_helper_rejects_unrelated_namespaces_before_api_calls
    with_kubectl_stub do |env, log|
      _out, err, status = Open3.capture3(env.merge('NS' => 'other-project'), 'bash', "#{ROOT}/scripts/verify-hpa.sh")
      assert_equal 2, status.exitstatus
      assert_includes err, 'Unsupported application namespace'
      refute File.exist?(log)
    end
  end
end
