#!/usr/bin/env ruby
# Offline manifest assertions; no kubectl/AWS/container mutation.
require 'minitest/autorun'
require 'yaml'
require 'open3'

class WorkloadReliabilityTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KUSTOMIZE = ENV.fetch('KUSTOMIZE_BIN', 'kustomize')
  RENDERS = %w[dev prod].to_h do |overlay|
    out, err, status = Open3.capture3(KUSTOMIZE, 'build', "#{ROOT}/k8s/overlays/#{overlay}")
    raise err unless status.success?
    [overlay, YAML.load_stream(out).compact]
  end

  def deployments(resources)
    resources.select { |r| r['kind'] == 'Deployment' && %w[was-deployment web-deployment].include?(r.dig('metadata', 'name')) }
  end

  def test_probes_have_independent_purposes_and_explicit_bounds
    RENDERS.each_value do |resources|
      deployments(resources).each do |deployment|
        app = deployment.dig('spec', 'template', 'metadata', 'labels', 'app')
        container = deployment.dig('spec', 'template', 'spec', 'containers').first
        expected = app == 'was' ? ['/health/startup', '/health/ready', '/health/live', 3000] : ['/healthz', '/readyz', '/healthz', 80]
        %w[startupProbe readinessProbe livenessProbe].each_with_index do |name, index|
          probe = container.fetch(name)
          assert_equal expected[index], probe.dig('httpGet', 'path')
          assert_equal expected.last, probe.dig('httpGet', 'port')
          assert_equal 2, probe.fetch('timeoutSeconds')
          assert_operator probe.fetch('periodSeconds'), :>=, 5
          assert_operator probe.fetch('failureThreshold'), :>=, 1
          assert_equal 0, probe.fetch('initialDelaySeconds')
          assert_equal 1, probe.fetch('successThreshold') unless name == 'readinessProbe'
        end
        startup = container.fetch('startupProbe')
        assert_equal app == 'was' ? 150 : 30, startup['periodSeconds'] * startup['failureThreshold']
        if app == 'was'
          assert_equal 3, container.dig('readinessProbe', 'failureThreshold')
          assert_equal 2, container.dig('readinessProbe', 'successThreshold')
        end
      end
    end
  end

  def test_pdb_matches_exactly_one_workload_and_not_migration
    RENDERS.each do |overlay, resources|
      pdbs = resources.select { |r| r['kind'] == 'PodDisruptionBudget' }
      assert_equal 2, pdbs.length
      pdbs.each do |pdb|
        spec = pdb.fetch('spec')
        assert_equal 'policy/v1', pdb['apiVersion']
        assert_equal overlay == 'dev' ? 'app' : 'app-prod', pdb.dig('metadata', 'namespace')
        assert spec.key?('maxUnavailable') ^ spec.key?('minAvailable')
        assert_equal 1, spec['maxUnavailable']
        assert_equal 'AlwaysAllow', spec['unhealthyPodEvictionPolicy']
        selector = spec.dig('selector', 'matchLabels')
        matches = deployments(resources).select { |d| selector.all? { |k, v| d.dig('spec', 'template', 'metadata', 'labels', k) == v } }
        assert_equal 1, matches.length
        assert_operator matches.first.dig('spec', 'replicas'), :>=, 2
        resources.select { |r| r['kind'] == 'Job' }.each do |job|
          refute selector.all? { |k, v| job.dig('spec', 'template', 'metadata', 'labels', k) == v }
        end
      end
    end
  end

  def test_hpa_and_deployment_rollout_budgets
    RENDERS.each_value do |resources|
      deployments(resources).each do |deployment|
        spec = deployment.fetch('spec')
        assert_equal 'RollingUpdate', spec.dig('strategy', 'type')
        assert_equal 0, spec.dig('strategy', 'rollingUpdate', 'maxUnavailable')
        assert_equal 1, spec.dig('strategy', 'rollingUpdate', 'maxSurge')
        assert_equal 10, spec['minReadySeconds']
        assert_equal 300, spec['progressDeadlineSeconds']
        assert_equal 3, spec['revisionHistoryLimit']
        spec.dig('template', 'spec', 'containers').each do |c|
          assert c.dig('resources', 'requests', 'cpu')
          assert c.dig('resources', 'requests', 'memory')
        end
      end
      resources.select { |r| r['kind'] == 'HorizontalPodAutoscaler' }.each { |hpa| assert_operator hpa.dig('spec', 'minReplicas'), :>=, 2 }
    end
  end

  def test_prestop_and_shutdown_budgets
    RENDERS.each_value do |resources|
      deployments(resources).each do |deployment|
        pod = deployment.dig('spec', 'template', 'spec')
        app = deployment.dig('spec', 'template', 'metadata', 'labels', 'app')
        hook = pod['containers'].first.dig('lifecycle', 'preStop', 'exec', 'command')
        if app == 'was'
          assert_equal 60, pod['terminationGracePeriodSeconds']
          assert_equal ['node', '-e'], hook.first(2)
          assert_includes hook.last, "host: '127.0.0.1'"
          assert_includes hook.last, "path: '/health/drain'"
          assert_includes hook.last, 'timeout: 2000'
          assert_includes hook.last, '5000'
          assert_operator pod['terminationGracePeriodSeconds'], :>, 7 + 30 + 2
        else
          assert_equal 45, pod['terminationGracePeriodSeconds']
          assert_equal ['sh', '-c', 'touch /tmp/nginx-draining; sleep 5'], hook
          assert_operator pod['terminationGracePeriodSeconds'], :>, 5 + 30
        end
      end
    end
  end

  def test_alb_checks_web_readiness_and_keeps_ip_target_and_ports
    RENDERS.each_value do |resources|
      ingress = resources.find { |r| r['kind'] == 'Ingress' }
      a = ingress.dig('metadata', 'annotations')
      prefix = 'alb.ingress.kubernetes.io/'
      assert_equal 'ip', a[prefix + 'target-type']
      assert_equal '/readyz', a[prefix + 'healthcheck-path']
      assert_equal 'traffic-port', a[prefix + 'healthcheck-port']
      assert_equal '200', a[prefix + 'success-codes']
      assert_equal '15', a[prefix + 'healthcheck-interval-seconds']
      assert_equal '5', a[prefix + 'healthcheck-timeout-seconds']
      assert_equal '2', a[prefix + 'healthy-threshold-count']
      assert_equal '2', a[prefix + 'unhealthy-threshold-count']
      assert_equal 'deregistration_delay.timeout_seconds=30', a[prefix + 'target-group-attributes']
      assert_equal '443', a[prefix + 'ssl-redirect']
    end
  end

  def test_migration_order_and_job_semantics_are_preserved
    RENDERS.each_value do |resources|
      job = resources.find { |r| r['kind'] == 'Job' }
      assert_equal 'Sync', job.dig('metadata', 'annotations', 'argocd.argoproj.io/hook')
      assert_equal '-1', job.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave')
      assert_equal 900, job.dig('spec', 'activeDeadlineSeconds')
      job.dig('spec', 'template', 'spec', 'containers').each do |container|
        %w[startupProbe readinessProbe livenessProbe].each { |key| refute container.key?(key) }
      end
      external = resources.find { |r| r['kind'] == 'ExternalSecret' }
      assert_equal '-2', external.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave')
    end
  end

  def test_alb_readiness_gate_injection_has_prerequisites_before_web_creation
    RENDERS.each_value do |resources|
      namespace = resources.find { |r| r['kind'] == 'Namespace' }
      assert_equal 'enabled', namespace.dig('metadata', 'labels', 'elbv2.k8s.aws/pod-readiness-gate-inject')
      ingress = resources.find { |r| r['kind'] == 'Ingress' }
      service = resources.find { |r| r['kind'] == 'Service' && r.dig('metadata', 'name') == 'nginx-service' }
      web = deployments(resources).find { |r| r.dig('metadata', 'name') == 'web-deployment' }
      assert_equal '-1', ingress.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave')
      assert_equal '-1', service.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave')
      assert_equal '0', web.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave')
      # The target-health gate is injected by LBC at Pod creation, not a
      # fabricated TargetGroupBinding hash hardcoded into a Deployment.
      refute web.dig('spec', 'template', 'spec').key?('readinessGates')
    end
  end

  def test_nginx_has_real_health_routes_and_bounded_graceful_quit
    config = File.read("#{ROOT}/app/coupang_eats_frontend_v2/nginx/default.conf")
    dockerfile = File.read("#{ROOT}/app/coupang_eats_frontend_v2/Dockerfile")
    assert_match(/location = \/healthz \{[^}]*return 200/m, config)
    assert_match(/location = \/readyz \{[^}]*nginx-draining/m, config)
    assert_includes config, 'if (!-f $document_root/index.html) { return 503; }'
    assert_includes dockerfile, 'STOPSIGNAL SIGQUIT'
    assert_includes dockerfile, 'worker_shutdown_timeout 30s;'
    assert_includes dockerfile, '/etc/nginx/nginx.conf'
    refute_includes config, 'worker_shutdown_timeout' # main-context directive
  end
end
