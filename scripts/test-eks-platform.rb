#!/usr/bin/env ruby
# Offline policy/manifest checks. This evaluates declarative NetworkPolicy
# semantics; it does not prove eBPF enforcement in a running cluster.
require 'minitest/autorun'
require 'yaml'
require 'open3'
require 'ipaddr'

class EksPlatformTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KUSTOMIZE = ENV.fetch('KUSTOMIZE_BIN', 'kustomize')
  RENDERS = %w[dev prod].to_h do |overlay|
    out, err, status = Open3.capture3(KUSTOMIZE, 'build', "#{ROOT}/k8s/overlays/#{overlay}")
    raise err unless status.success?
    [overlay, YAML.load_stream(out).compact]
  end

  def setup
    @resources = RENDERS.fetch('dev')
    @policies = @resources.select { |r| r['kind'] == 'NetworkPolicy' }
    @web = endpoint('web', '10.0.10.10')
    @was = endpoint('was', '10.0.11.10')
    @unknown = endpoint('untrusted', '10.0.12.10')
    @dns = { namespace: 'kube-system', labels: { 'k8s-app' => 'kube-dns' }, ip: '10.0.10.53' }
  end

  def endpoint(app, ip, namespace = 'app')
    { namespace: namespace, labels: { 'app' => app }, ip: ip }
  end

  def selector_matches?(selector, labels)
    return false unless labels
    selector.fetch('matchLabels', {}).all? { |key, val| labels[key] == val } &&
      selector.fetch('matchExpressions', []).all? do |expr|
        raise "unsupported expression #{expr}" unless expr['operator'] == 'In'
        expr.fetch('values').include?(labels[expr.fetch('key')])
      end
  end

  def peer_matches?(peer, remote, policy_namespace)
    if peer['ipBlock']
      block = peer['ipBlock']
      return IPAddr.new(block.fetch('cidr')).include?(remote.fetch(:ip)) &&
        block.fetch('except', []).none? { |cidr| IPAddr.new(cidr).include?(remote.fetch(:ip)) }
    end
    ns = peer['namespaceSelector']
    namespace_ok = ns ? selector_matches?(ns, { 'kubernetes.io/metadata.name' => remote[:namespace] }) :
      remote[:namespace] == policy_namespace
    namespace_ok && (!peer['podSelector'] || selector_matches?(peer['podSelector'], remote[:labels]))
  end

  def permits?(local, remote, direction, port, protocol = 'TCP')
    selected = @policies.select do |policy|
      policy.dig('metadata', 'namespace') == local[:namespace] &&
        selector_matches?(policy.dig('spec', 'podSelector'), local[:labels]) &&
        policy.dig('spec', 'policyTypes').include?(direction.capitalize)
    end
    return true if selected.empty?
    selected.any? do |policy|
      policy.fetch('spec').fetch(direction, []).any? do |rule|
        port_ok = rule.fetch('ports', []).empty? || rule['ports'].any? do |p|
          p.fetch('protocol', 'TCP') == protocol && p['port'] == port
        end
        key = direction == 'ingress' ? 'from' : 'to'
        port_ok && (!rule[key] || rule[key].any? { |peer| peer_matches?(peer, remote, policy.dig('metadata', 'namespace')) })
      end
    end
  end

  def connection?(source, destination, port, protocol = 'TCP')
    permits?(source, destination, 'egress', port, protocol) &&
      permits?(destination, source, 'ingress', port, protocol)
  end

  def test_web_to_was_only_at_3000
    assert connection?(@web, @was, 3000)
    [22, 80, 443, 3306, 6379].each { |port| refute connection?(@web, @was, port) }
  end

  def test_untrusted_and_cross_namespace_cannot_reach_was
    refute connection?(@unknown, @was, 3000)
    refute connection?(@was, @was, 3000)
    refute connection?(endpoint('web', '10.0.12.15', 'other'), @was, 3000)
    refute connection?(@was, @web, 80)
  end

  def test_default_deny_covers_unrecognized_application_pods
    refute permits?(@unknown, @dns, 'egress', 53, 'UDP')
    refute permits?(@unknown, endpoint('outside', '203.0.113.1', 'external'), 'egress', 443)
    assert_equal({}, @policies.find { |p| p.dig('metadata', 'name') == 'default-deny' }.dig('spec', 'podSelector'))
  end

  def test_only_prometheus_in_monitoring_can_scrape_was
    prometheus = endpoint('prometheus', '10.0.12.20', 'monitoring')
    prometheus[:labels]['observability.food-delivery/component'] = 'prometheus'
    assert connection?(prometheus, @was, 3000)
    [80, 443, 3306, 6379].each { |port| refute connection?(prometheus, @was, port) }
    refute connection?(prometheus.merge(namespace: 'other'), @was, 3000)
    refute connection?(endpoint('grafana', '10.0.12.21', 'monitoring'), @was, 3000)
    refute connection?(prometheus, @web, 3000)
  end

  def test_dns_udp_and_tcp_require_both_namespace_and_label
    [@web, @was, endpoint('was-migration', '10.0.10.22')].each do |pod|
      %w[TCP UDP].each { |protocol| assert connection?(pod, @dns, 53, protocol) }
      wrong_label = @dns.merge(labels: { 'k8s-app' => 'not-dns' })
      refute connection?(pod, wrong_label, 53, 'UDP')
      refute connection?(pod, @dns.merge(namespace: 'other'), 53, 'UDP')
    end
  end

  def test_was_dependency_ports_are_bounded_to_vpc
    [3306, 6379].each do |port|
      assert permits?(@was, endpoint('dependency', '10.0.20.10', 'external'), 'egress', port)
      refute permits?(@was, endpoint('outside', '203.0.113.10', 'external'), 'egress', port)
      refute permits?(@web, endpoint('dependency', '10.0.20.10', 'external'), 'egress', port)
    end
    assert permits?(@was, endpoint('aws', '203.0.113.10', 'external'), 'egress', 443)
    refute permits?(@was, endpoint('outside', '203.0.113.10', 'external'), 'egress', 22)
    text = File.read("#{ROOT}/infra/environments/dev/variables.tf")
    default_cidr = text.match(/variable "vpc_cidr"\s*\{.*?default\s*=\s*"([^"]+)"/m)[1]
    cidrs = @policies.flat_map { |p| p.dig('spec', 'egress') || [] }
                     .flat_map { |r| r.fetch('to', []) }.map { |p| p.dig('ipBlock', 'cidr') }.compact
    assert_includes cidrs, default_cidr
    assert_equal [default_cidr], cidrs.reject { |cidr| ['169.254.169.254/32', '0.0.0.0/0'].include?(cidr) }.uniq
    refute permits?(@was, endpoint('other', '10.0.12.30', 'other'), 'egress', 443)
    refute permits?(@was, endpoint('api-server', '172.20.0.1', 'external'), 'egress', 443)
  end

  def test_imds_and_generic_http_egress_are_denied
    metadata = endpoint('metadata', '169.254.169.254', 'external')
    refute permits?(@was, metadata, 'egress', 80)
    refute permits?(@web, metadata, 'egress', 80)
    refute permits?(@unknown, metadata, 'egress', 80)
    refute permits?(@was, endpoint('outside', '203.0.113.10', 'external'), 'egress', 80)
  end

  def test_alb_http_and_health_ingress_without_was_exposure
    alb = endpoint('alb', '10.0.0.10', 'external')
    assert permits?(@web, alb, 'ingress', 80)
    refute permits?(@web, alb, 'ingress', 3000)
    refute permits?(@was, alb, 'ingress', 3000)
    # Deliberately no ALB-IP allowlist: AWS SG is the authoritative ALB source boundary.
  end

  def test_migration_intent_does_not_require_app_to_migration_ingress
    migration = endpoint('was-migration', '10.0.10.22')
    assert permits?(migration, endpoint('proxy', '10.0.20.10', 'external'), 'egress', 3306)
    refute permits?(migration, endpoint('redis', '10.0.20.11', 'external'), 'egress', 6379)
    refute permits?(migration, @was, 'egress', 3000)
    refute permits?(migration, @web, 'ingress', 80)
  end

  def test_tracing_allows_only_same_namespace_was_to_collector_otlp
    collector = endpoint('adot-collector', '10.0.12.20')
    assert permits?(@was, collector, 'egress', 4318)
    assert permits?(collector, @was, 'ingress', 4318)
    refute permits?(@web, collector, 'egress', 4318)
    refute permits?(collector, @web, 'ingress', 4318)
    refute permits?(collector, @unknown, 'ingress', 4318)
    refute permits?(collector, endpoint('was', '10.0.13.10', 'monitoring'), 'ingress', 4318)
    refute permits?(@was, collector, 'egress', 4317)
    refute permits?(collector, @was, 'ingress', 4317)
  end

  def test_collector_egress_is_dns_and_public_https_only
    collector = endpoint('adot-collector', '10.0.12.20')
    assert permits?(collector, @dns, 'egress', 53, 'UDP')
    assert permits?(collector, @dns, 'egress', 53, 'TCP')
    assert permits?(collector, endpoint('aws', '54.240.1.1', 'external'), 'egress', 443)
    refute permits?(collector, endpoint('imds', '169.254.169.254', 'external'), 'egress', 80)
    refute permits?(collector, @was, 'egress', 3000)
    refute permits?(collector, endpoint('proxy', '10.0.20.10', 'external'), 'egress', 3306)
    refute permits?(collector, endpoint('external', '1.1.1.1', 'external'), 'egress', 80)
  end

  def test_both_overlays_contain_application_and_tracing_policies_before_migration
    RENDERS.each do |overlay, resources|
      policies = resources.select { |r| r['kind'] == 'NetworkPolicy' }
      assert_equal 9, policies.length
      assert_equal [overlay == 'dev' ? 'app' : 'app-prod'], policies.map { |p| p.dig('metadata', 'namespace') }.uniq
      policies.each { |p| assert_equal '-2', p.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave') }
    end
  end

  def test_existing_pss_and_security_contexts_are_preserved
    @resources.select { |r| r['kind'] == 'Deployment' }.each do |deployment|
      pod = deployment.dig('spec', 'template', 'spec')
      assert_equal true, pod.dig('securityContext', 'runAsNonRoot')
      assert_equal 'RuntimeDefault', pod.dig('securityContext', 'seccompProfile', 'type')
      assert_equal false, pod['automountServiceAccountToken']
      pod['containers'].each do |c|
        assert_equal false, c.dig('securityContext', 'allowPrivilegeEscalation')
        assert_equal ['ALL'], c.dig('securityContext', 'capabilities', 'drop')
      end
    end
    namespace = @resources.find { |r| r['kind'] == 'Namespace' }
    %w[enforce warn audit].each { |mode| assert_equal 'restricted', namespace.dig('metadata', 'labels', "pod-security.kubernetes.io/#{mode}") }
  end

  def test_api_versions_are_reviewed_stable_or_explicit_crds
    allowed = {
      'v1' => %w[Namespace Service ServiceAccount ConfigMap Secret],
      'apps/v1' => %w[Deployment], 'batch/v1' => %w[Job],
      'policy/v1' => %w[PodDisruptionBudget],
      'autoscaling/v2' => %w[HorizontalPodAutoscaler],
      'networking.k8s.io/v1' => %w[Ingress NetworkPolicy],
      'external-secrets.io/v1' => %w[ExternalSecret SecretStore]
    }
    RENDERS.each_value do |resources|
      resources.each do |r|
        assert_includes allowed.fetch(r.fetch('apiVersion')), r.fetch('kind')
        refute r.dig('spec', 'template', 'spec', 'volumes').to_a.any? { |v| v.key?('gitRepo') }
      end
    end
    assert_equal 'argoproj.io/v1alpha1', YAML.load_file("#{ROOT}/argocd-app.yaml")['apiVersion']
  end

  def test_canonical_ipv4_cidrs_and_no_removed_service_field
    RENDERS.each_value do |resources|
      resources.select { |r| r['kind'] == 'NetworkPolicy' }.each do |policy|
        %w[ingress egress].each do |direction|
          policy.fetch('spec').fetch(direction, []).each do |rule|
            %w[from to].each do |key|
              rule.fetch(key, []).each do |peer|
                next unless peer['ipBlock']
                cidr = peer.dig('ipBlock', 'cidr')
                network = IPAddr.new(cidr)
                assert network.ipv4?
                assert_equal network.to_range.first.to_s, cidr.split('/').first
              end
            end
          end
        end
      end
      resources.select { |r| r['kind'] == 'Service' }.each do |service|
        refute service.fetch('spec').key?('externalIPs')
      end
    end
  end

  def test_no_ebs_requirement_or_dual_addon_management
    refute @resources.any? { |r| %w[PersistentVolume PersistentVolumeClaim StorageClass DaemonSet].include?(r['kind']) }
    text = Dir["#{ROOT}/infra/modules/eks/*.tf"].map { |p| File.read(p) }.join("\n")
    logging = File.read("#{ROOT}/infra/modules/eks/logging.tf")
    assert_includes logging, 'count      = var.enable_central_logging ? 1 : 0'
    assert_includes logging, 'aws-ebs-csi-driver'
    assert_includes logging, 'helm_release.ebs_csi'
    refute_match(/ignore_changes\s*=\s*\[version\]/, text)
    assert_includes text, 'amazon-eks-node-al2023-x86_64-standard-${var.kubernetes_version}-v*'
    assert_equal 12, text.scan(/resource "helm_release"/).length
    text.scan(/resource "helm_release" "([^"]+)" \{(.*?)(?=^resource |^data |^output |^locals |\z)/m).each do |name, body|
      assert_match(/^  version\s*=\s*(?:"[0-9.]+"|local\.(?:lbc|karpenter)_version)\s*$/, body, name)
    end
    node_group = text.split('resource "aws_eks_node_group" "this" {', 2).last.split('# 5.', 2).first
    refute_match(/^  (?:version|ami_type|release_version|remote_access)\s*[={]/, node_group)
  end
end
