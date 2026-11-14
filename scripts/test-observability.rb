#!/usr/bin/env ruby
# Offline regression checks. No Helm install, Kubernetes API or AWS calls.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'
require 'uri'
require 'pathname'

class ObservabilityTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CONFIG = "#{ROOT}/infra/modules/eks/observability"
  VALUES = YAML.load_file("#{CONFIG}/values.yaml")
  DASHBOARD = JSON.parse(File.read("#{CONFIG}/food-delivery-overview.json"))
  RENDERS = %w[dev prod].to_h do |env|
    out, err, status = Open3.capture3(ENV.fetch('KUSTOMIZE_BIN', 'kustomize'), 'build', "#{ROOT}/k8s/overlays/#{env}")
    raise err unless status.success?
    [env, YAML.load_stream(out).compact]
  end

  def test_no_managed_services_public_ingress_or_persistent_storage
    %w[prometheus grafana].each do |component|
      refute VALUES.dig(component, 'ingress', 'enabled')
      assert_equal 'ClusterIP', VALUES.dig(component, 'service', 'type')
    end
    refute VALUES.dig('grafana', 'persistence', 'enabled')
    assert_equal({'emptyDir' => {'sizeLimit' => '1Gi'}}, VALUES.dig('prometheus', 'prometheusSpec', 'storageSpec'))
    assert_equal [], VALUES.dig('prometheus', 'prometheusSpec', 'remoteWrite')
    %w[alertmanager thanosRuler windowsMonitoring].each { |key| refute VALUES.dig(key, 'enabled') }
    refute VALUES.dig('defaultRules', 'create')
    text = File.read("#{ROOT}/infra/modules/eks/observability.tf")
    refute_match(/resource\s+"aws_(?:grafana|prometheus|ebs)/, text)
  end

  def test_pinned_chart_and_dashboard_have_one_platform_owner
    lock = JSON.parse(File.read("#{CONFIG}/chart-lock.json"))
    assert_match(/\A\d+\.\d+\.\d+\z/, lock.fetch('version'))
    assert_match(/\A[0-9a-f]{64}\z/, lock.fetch('digest'))
    tf = File.read("#{ROOT}/infra/modules/eks/observability.tf")
    assert_includes tf, "version          = \"#{lock.fetch('version')}\""
    assert_includes tf, 'count = var.enable_oss_observability ? 1 : 0'
    assert_includes tf, 'food-delivery-overview.json'
    RENDERS.each_value do |resources|
      refute resources.any? { |r| %w[ServiceMonitor PodMonitor Prometheus].include?(r['kind']) }
    end
  end

  def test_scrape_retention_and_resource_bounds
    spec = VALUES.dig('prometheus', 'prometheusSpec')
    assert_equal '12h', spec['retention']
    assert_equal '512MB', spec['retentionSize']
    assert_equal '30s', spec['scrapeInterval']
    assert_equal '5s', spec['scrapeTimeout']
    [spec, VALUES['grafana'], VALUES['prometheusOperator'], VALUES['kube-state-metrics'], VALUES['prometheus-node-exporter'], VALUES.dig('prometheusOperator', 'prometheusConfigReloader')].each do |component|
      %w[requests limits].each do |kind|
        %w[cpu memory].each { |resource| refute_empty component.fetch('resources').fetch(kind).fetch(resource) }
      end
    end
  end

  def test_was_discovery_is_per_pod_and_matches_services_in_both_overlays
    monitor = VALUES.dig('prometheus', 'additionalServiceMonitors').fetch(0)
    assert_equal 5000, monitor['sampleLimit']
    refute monitor.fetch('endpoints').first.key?('sampleLimit')
    assert_equal '/metrics', monitor.dig('endpoints', 0, 'path')
    RENDERS.each_value do |resources|
      service = resources.find { |r| r['kind'] == 'Service' && r.dig('metadata', 'name') == 'nest' }
      monitor.dig('selector', 'matchLabels').each { |k, v| assert_equal v, service.dig('metadata', 'labels', k) }
      assert_includes monitor.dig('namespaceSelector', 'matchNames'), service.dig('metadata', 'namespace')
      assert service.dig('spec', 'ports').any? { |p| p['name'] == monitor.dig('endpoints', 0, 'port') && p['targetPort'] == 3000 }
    end
  end

  def test_application_boundary_combines_namespace_and_prometheus_identity
    RENDERS.each_value do |resources|
      policy = resources.find { |r| r['kind'] == 'NetworkPolicy' && r.dig('metadata', 'name') == 'prometheus-to-was' }
      assert_equal({'app' => 'was'}, policy.dig('spec', 'podSelector', 'matchLabels'))
      assert_equal ['Ingress'], policy.dig('spec', 'policyTypes')
      rule = policy.dig('spec', 'ingress').fetch(0)
      assert_equal 1, rule.fetch('from').size
      peer = rule.fetch('from').first
      assert_equal 'monitoring', peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name')
      assert_equal({'observability.food-delivery/component' => 'prometheus'}, peer.dig('podSelector', 'matchLabels'))
      peer.dig('podSelector', 'matchLabels').each { |key, value| assert_equal value, VALUES.dig('prometheus', 'prometheusSpec', 'podMetadata', 'labels', key) }
      assert_equal 'true', VALUES.dig('prometheus', 'prometheusSpec', 'podMetadata', 'labels', 'observability-grafana-client')
      assert_equal [{'protocol' => 'TCP', 'port' => 3000}], rule.fetch('ports')
    end
  end

  def test_no_long_lived_token_no_grafana_rbac_or_credentials_in_values
    refute VALUES.dig('prometheus', 'serviceAccount', 'createTokenSecret')
    job = VALUES.dig('prometheus', 'prometheusSpec', 'additionalScrapeConfigs').first
    assert_equal '/metrics/cadvisor', job.fetch('metrics_path')
    assert_equal '/var/run/secrets/kubernetes.io/serviceaccount/token', job.dig('authorization', 'credentials_file')
    refute VALUES.dig('grafana', 'automountServiceAccountToken')
    refute VALUES.dig('grafana', 'rbac', 'create')
    refute VALUES['grafana'].key?('adminPassword')
    %w[server dashboards datasources].each { |key| refute VALUES.dig('grafana', 'sidecar', key, 'enabled') }
    refute VALUES.dig('grafana', 'grafana.ini', 'auth.anonymous', 'enabled')
  end

  def test_node_exporter_and_kube_state_metrics_have_minimum_scope
    node = VALUES.fetch('prometheus-node-exporter')
    refute node.fetch('hostNetwork')
    refute node.fetch('hostPID')
    assert node.dig('hostRootFsMount', 'enabled')
    assert_includes node.fetch('extraArgs'), '--collector.filesystem'
    assert_includes node.fetch('extraArgs'), '--collector.cpu'
    assert_includes node.fetch('extraArgs'), '--collector.meminfo'
    assert_equal %w[nodes pods deployments replicasets horizontalpodautoscalers daemonsets statefulsets persistentvolumes persistentvolumeclaims], VALUES.dig('kube-state-metrics', 'collectors')
    assert_equal [], VALUES.dig('kube-state-metrics', 'metricLabelsAllowlist')
    assert VALUES.dig('prometheus', 'networkPolicy', 'enabled')
    assert VALUES.dig('grafana', 'networkPolicy', 'enabled')
    refute VALUES.dig('grafana', 'networkPolicy', 'allowExternal')
  end

  def test_dashboard_metrics_and_provisioning_are_consistent
    source = VALUES.dig('grafana', 'datasources', 'datasources.yaml', 'datasources').first
    assert_equal 'prometheus', source.fetch('uid')
    assert_equal 'http://observability-prometheus.monitoring.svc.cluster.local:9090', source.fetch('url')
    panels = DASHBOARD.fetch('panels')
    assert_equal panels.size, panels.map { |p| p.fetch('id') }.uniq.size
    %w[CPU Memory Running Pending Restart Request p95 5xx Node Replica].each do |term|
      assert panels.any? { |p| p.fetch('title').include?(term) }, "missing #{term}"
    end
    panels.each do |panel|
      assert_equal source.fetch('uid'), panel.dig('datasource', 'uid')
      panel.fetch('targets').each { |target| refute_empty target.fetch('expr') }
    end
    assert_equal %w[namespace pod], DASHBOARD.dig('templating', 'list').map { |v| v.fetch('name') }
    expressions = panels.flat_map { |p| p.fetch('targets').map { |t| t.fetch('expr') } }.join(' ')
    %w[container_cpu_usage_seconds_total container_memory_working_set_bytes kube_pod_status_phase kube_deployment_spec_replicas kube_deployment_status_replicas_available kube_pod_container_status_restarts_total kube_node_info food_delivery_http_requests_total food_delivery_http_request_duration_seconds_bucket histogram_quantile].each { |metric| assert_includes expressions, metric }
    refute_match(/userId|email|orderId|restaurantId|JWT|request_id|trace_id/, expressions)
  end

  def test_public_nginx_rejects_metrics_before_proxy_locations
    nginx = File.read("#{ROOT}/app/coupang_eats_frontend_v2/nginx/default.conf")
    pattern = nginx.match(/location ~\* (\S+) \{\s*access_log off;\s*return 404;/)[1]
    deny = Regexp.new(pattern, Regexp::IGNORECASE)
    %w[/metrics /metrics/ /METRICS /api/metrics /api/Metrics/ /%6Detrics /auth/../metrics /api//metrics].each do |path|
      normalized = Pathname.new(URI::DEFAULT_PARSER.unescape(path)).cleanpath.to_s
      assert deny.match?(normalized), path
    end
    %w[/health/live /auth/sign-in /restaurants /orders/123].each { |path| refute deny.match?(path), path }
    assert_operator nginx.index(pattern), :<, nginx.index('location /api/')
  end

  def test_actual_helm_render_has_no_unresolved_secrets_or_public_resources
    skip 'Set OBSERVABILITY_RENDER to a local Helm-rendered YAML file' unless ENV['OBSERVABILITY_RENDER']
    resources = YAML.load_stream(File.read(ENV.fetch('OBSERVABILITY_RENDER'))).compact
      .flat_map { |r| r['kind'] == 'List' ? r.fetch('items') : [r] }
    refute resources.any? { |r| %w[Ingress PersistentVolumeClaim Alertmanager ThanosRuler].include?(r['kind']) }
    resources.select { |r| r['kind'] == 'Service' }.each { |s| assert_equal 'ClusterIP', s.dig('spec', 'type') || 'ClusterIP' }
    resources.select { |r| r['kind'] == 'ClusterRoleBinding' }.each { |r| refute_equal 'cluster-admin', r.dig('roleRef', 'name') }
    # Admission webhooks are off: their TLS Secret must not be mounted by operator.
    secrets = resources.select { |r| r['kind'] == 'Secret' }.map { |r| r.dig('metadata', 'name') }
    resources.select { |r| %w[Deployment DaemonSet].include?(r['kind']) }.each do |d|
      pod = d.dig('spec', 'template', 'spec')
      pod.fetch('volumes', []).to_a.each do |v|
        assert_includes secrets, v.dig('secret', 'secretName') if v['secret'] && !v.dig('secret', 'optional')
      end
    end
    prometheus = resources.find { |r| r['kind'] == 'Prometheus' }
    assert_equal '12h', prometheus.dig('spec', 'retention')
    assert_equal({'sizeLimit' => '1Gi'}, prometheus.dig('spec', 'storage', 'emptyDir'))
    assert_equal 'prometheus', prometheus.dig('spec', 'podMetadata', 'labels', 'observability.food-delivery/component')
    assert_equal %w[adot karpenter observability-grafana observability-kube-state-metrics observability-prometheus-node-exporter observability-coredns observability-operator observability-prometheus was].sort, resources.select { |r| r['kind'] == 'ServiceMonitor' }.map { |r| r.dig('metadata', 'name') }.sort
    monitor = resources.find { |r| r['kind'] == 'ServiceMonitor' && r.dig('metadata', 'name') == 'was' }
    assert_equal 'observability', monitor.dig('metadata', 'labels', 'release')
    assert_equal 5000, monitor.dig('spec', 'sampleLimit')
    grafana = resources.find { |r| r['kind'] == 'Deployment' && r.dig('metadata', 'name') == 'observability-grafana' }
    refute grafana.dig('spec', 'template', 'spec', 'automountServiceAccountToken')
    dashboard_cm = resources.find { |r| r['kind'] == 'ConfigMap' && r.dig('metadata', 'name') == 'observability-grafana-dashboards-default' }
    assert_equal DASHBOARD, JSON.parse(dashboard_cm.dig('data', 'food-delivery-overview.json'))
  end
end
