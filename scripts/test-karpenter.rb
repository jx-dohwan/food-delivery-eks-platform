#!/usr/bin/env ruby
# Read-only assertions against actual Helm renders and a Terraform MOCK plan.
# Supply Karpenter policy and graph fixtures to run these checks offline.
require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'

class KarpenterTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  RENDER = ENV.fetch('KARPENTER_RENDER_DIR')
  MOCK = ENV.fetch('KARPENTER_MOCK_DIR')
  DOCS = %w[karpenter karpenter_crd karpenter_capacity observability argocd external_secrets reloader metrics_server].to_h do |key|
    [key, YAML.load_stream(File.read("#{RENDER}/#{key}.yaml")).compact]
  end
  POLICY = JSON.parse(File.read("#{MOCK}/controller-policy.json"))
  PLAN = JSON.parse(File.read("#{MOCK}/plan.json"))

  def resource(kind, name)
    DOCS.fetch('karpenter_capacity').find { |r| r['kind'] == kind && r.dig('metadata', 'name') == name }.fetch('spec')
  end

  def planned(address)
    PLAN.fetch('resource_changes').find { |r| r['address'] == address }.fetch('change').fetch('after')
  end

  def test_v1_capacity_matches_released_crd_schemas
    node = ENV.fetch('NODE_BIN', 'node')
    script = <<~JS
      const Ajv = require(process.cwd() + '/app/coupang_eats_backend_v2/node_modules/ajv');
      let input = ''; process.stdin.on('data', x => input += x);
      process.stdin.on('end', () => {
        const {schema, resource} = JSON.parse(input);
        const ajv = new Ajv({allErrors: true, nullable: true, unknownFormats: 'ignore', logger: false});
        const validate = ajv.compile(schema);
        if (!validate(resource)) { process.stderr.write(JSON.stringify(validate.errors)); process.exit(1); }
      });
    JS
    DOCS.fetch('karpenter_capacity').each do |obj|
      assert_match(%r{/v1\z}, obj.fetch('apiVersion'))
      crd = DOCS.fetch('karpenter_crd').find { |r| r.dig('spec', 'names', 'kind') == obj['kind'] }
      version = crd.fetch('spec').fetch('versions').find { |v| v['name'] == 'v1' }
      assert version.fetch('served')
      assert version.fetch('storage')
      _, err, status = Open3.capture3(node, '-e', script, chdir: ROOT,
                                    stdin_data: JSON.generate(schema: version.dig('schema', 'openAPIV3Schema'), resource: obj))
      assert status.success?, err
    end
    # CEL expressions and live readiness are deliberately left to Full Deploy.
  end

  def test_private_al2023_node_class_and_exact_profile
    spec = resource('EC2NodeClass', 'food-delivery-app')
    assert_equal 'AL2023', spec['amiFamily']
    assert_match(/^ami-[0-9a-f]{17}$/, spec.fetch('amiSelectorTerms').first.fetch('id'))
    refute spec.key?('role')
    assert_equal planned('aws_iam_instance_profile.karpenter[0]').fetch('name'), spec['instanceProfile']
    refute spec['associatePublicIPAddress']
    cluster = planned('aws_eks_cluster.this').fetch('name')
    assert_equal [{ 'tags' => { 'karpenter.sh/discovery' => cluster, 'Type' => 'private' } }], spec['subnetSelectorTerms']
    assert_equal [{ 'tags' => { 'karpenter.sh/discovery' => cluster } }], spec['securityGroupSelectorTerms']
    assert_equal 1, spec.dig('metadataOptions', 'httpPutResponseHopLimit')
    assert_equal 'required', spec.dig('metadataOptions', 'httpTokens')
    disk = spec.fetch('blockDeviceMappings').first.fetch('ebs')
    assert_equal '20Gi', disk['volumeSize']
    assert disk['encrypted']
    assert disk['deleteOnTermination']
  end

  def test_bounded_pool_and_non_forced_disruption
    spec = resource('NodePool', 'food-delivery-app')
    template = spec.fetch('template').fetch('spec')
    assert_equal({ 'group' => 'karpenter.k8s.aws', 'kind' => 'EC2NodeClass', 'name' => 'food-delivery-app' }, template['nodeClassRef'])
    requirements = template.fetch('requirements').to_h { |r| [r['key'], r['values']] }
    assert_equal ['on-demand'], requirements['karpenter.sh/capacity-type']
    assert_equal %w[t3 t3a], requirements['karpenter.k8s.aws/instance-family']
    assert_equal %w[medium large], requirements['karpenter.k8s.aws/instance-size']
    assert_equal ['amd64'], requirements['kubernetes.io/arch']
    assert_equal({ 'cpu' => '4', 'memory' => '8Gi' }, spec['limits'])
    assert_equal '168h', template['expireAfter']
    assert_equal 'WhenEmptyOrUnderutilized', spec.dig('disruption', 'consolidationPolicy')
    assert_equal '10m', spec.dig('disruption', 'consolidateAfter')
    assert_equal [{ 'nodes' => '1' }], spec.dig('disruption', 'budgets')
    refute template.key?('terminationGracePeriod'), 'No forced PDB bypass deadline'
    refute template.key?('taints')
  end

  def test_release_irsa_and_system_placement
    controller = DOCS.fetch('karpenter').find { |r| r['kind'] == 'Deployment' }
    assert_equal 2, controller.dig('spec', 'replicas')
    image = controller.dig('spec', 'template', 'spec', 'containers', 0, 'image')
    assert_equal 'public.ecr.aws/karpenter/controller:1.14.1@sha256:445baefaaa689029cc12ac1f659b916b0b82fb14308ce536f8521fcf079116fa', image
    sa = DOCS.fetch('karpenter').find { |r| r['kind'] == 'ServiceAccount' }
    assert_match(/:role\//, sa.dig('metadata', 'annotations', 'eks.amazonaws.com/role-arn'))
    %w[karpenter argocd external_secrets reloader metrics_server].each do |key|
      workloads = DOCS.fetch(key).select { |r| %w[Deployment StatefulSet].include?(r['kind']) }
      refute_empty workloads
      workloads.each do |r|
        assert_equal 'nodegroup-1', r.dig('spec', 'template', 'spec', 'nodeSelector', 'eks.amazonaws.com/nodegroup'), "#{key}/#{r.dig('metadata', 'name')}"
      end
    end
    obs = DOCS.fetch('observability')
    assert_equal 'nodegroup-1', obs.find { |r| r['kind'] == 'Prometheus' }.dig('spec', 'nodeSelector', 'eks.amazonaws.com/nodegroup')
    obs.select { |r| r['kind'] == 'Deployment' }.each do |r|
      assert_equal 'nodegroup-1', r.dig('spec', 'template', 'spec', 'nodeSelector', 'eks.amazonaws.com/nodegroup')
    end
    exporter = obs.find { |r| r['kind'] == 'DaemonSet' }
    refute exporter.dig('spec', 'template', 'spec', 'nodeSelector').key?('eks.amazonaws.com/nodegroup')
  end

  def test_iam_does_not_grant_arbitrary_nodes_or_profiles
    statements = POLICY.fetch('Statement')
    actions = statements.flat_map { |s| Array(s['Action']) }
    refute_includes actions, 'ec2:*'
    refute_includes actions, 'iam:*'
    %w[iam:CreateInstanceProfile iam:DeleteInstanceProfile iam:AddRoleToInstanceProfile sqs:*].each { |a| refute_includes actions, a }
    pass = statements.find { |s| s['Action'] == 'iam:PassRole' }
    assert_equal 'ec2.amazonaws.com', pass.dig('Condition', 'StringEquals', 'iam:PassedToService')
    assert_equal planned('aws_iam_role.karpenter_node[0]').fetch('arn'), pass['Resource']
    deletion = statements.find { |s| Array(s['Action']).include?('ec2:TerminateInstances') }
    assert_equal 'food-delivery-app', deletion.dig('Condition', 'StringLike', 'aws:ResourceTag/karpenter.sh/nodepool')
    cluster = planned('aws_eks_cluster.this').fetch('name')
    assert_equal 'owned', deletion.dig('Condition', 'StringEquals', "aws:ResourceTag/kubernetes.io/cluster/#{cluster}")
    attachments = PLAN.fetch('resource_changes').select { |r| r['address'].start_with?('aws_iam_role_policy_attachment.karpenter_node[') }
    assert_equal %w[AmazonEC2ContainerRegistryPullOnly AmazonEKSWorkerNodePolicy], attachments.map { |r| r.dig('change', 'after', 'policy_arn').split('/').last }.sort
    assert_operator JSON.generate(POLICY).bytesize, :<, 10_240
    trust = PLAN.fetch('resource_changes').find { |r| r['address'] == 'aws_iam_role.karpenter_controller[0]' }.dig('change', 'after', 'assume_role_policy')
    conditions = JSON.parse(trust).fetch('Statement').first.fetch('Condition').fetch('StringEquals')
    assert_includes conditions.values, 'system:serviceaccount:kube-system:karpenter'
    assert_includes conditions.values, 'sts.amazonaws.com'
  end

  def test_synthetic_workload_is_off_and_not_part_of_application
    docs = YAML.load_stream(File.read("#{ROOT}/k8s/tests/karpenter-scale-test.yaml")).compact
    deployment = docs.find { |r| r['kind'] == 'Deployment' }
    assert_equal 0, deployment.dig('spec', 'replicas')
    assert_equal 'application', deployment.dig('spec', 'template', 'spec', 'nodeSelector', 'food-delivery/capacity')
    Dir.glob("#{ROOT}/k8s/{base,overlays/**/*}/kustomization.yaml").each do |file|
      refute_includes File.read(file), 'karpenter-scale-test'
    end
    # No second autoscaler, public subnet selection, Spot or mutable AMI alias.
    refute_match(/amiSelectorTerms:.*@latest/m, File.read("#{ROOT}/infra/modules/eks/karpenter-config/templates/capacity.yaml"))
    refute Dir.glob("#{ROOT}/infra/**/*.tf").any? { |f| File.read(f).match?(/resource "helm_release" "cluster_autoscaler"/) }
  end
end
