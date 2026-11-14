#!/usr/bin/env ruby
# Local-only regression tests. Git remotes are temporary directories; AWS/Docker
# commands in publishing tests are stubs. No workflow, registry or cluster calls.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'yaml'
require 'json'

class ImageTraceabilityTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SHA = '0123456789abcdef0123456789abcdef01234567'.freeze
  REGISTRY = '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com'.freeze
  # Git records only the SHA; the account-specific registry is injected at deploy time.
  PLACEHOLDER = 'ecr-registry.invalid'.freeze
  DIGEST = "sha256:#{'a' * 64}".freeze

  def setup
    @tmp = Dir.mktmpdir('food-image-traceability-')
    @repo = File.join(@tmp, 'repo')
    FileUtils.mkdir_p(@repo)
    FileUtils.cp_r(File.join(ROOT, 'k8s'), @repo)
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.cp_r(File.join(ROOT, 'scripts/ci'), File.join(@repo, 'scripts'))
    @env = { 'SOURCE_SHA' => SHA, 'ECR_REGISTRY' => REGISTRY,
             'GITHUB_REF' => 'refs/heads/main', 'WAS_DIGEST' => DIGEST,
             'WEB_DIGEST' => DIGEST }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def command(*args, env: @env, directory: @repo)
    Open3.capture3(env, *args, chdir: directory)
  end

  def success(*args, **options)
    out, err, status = command(*args, **options)
    assert status.success?, "#{args.inspect}\n#{out}\n#{err}"
    out
  end

  def kustomize
    ENV.fetch('KUSTOMIZE_BIN', 'kustomize')
  end

  def images(overlay)
    yaml = success(kustomize, 'build', "k8s/overlays/#{overlay}")
    YAML.load_stream(yaml).select { |r| %w[Deployment Job].include?(r['kind']) && %w[was-deployment web-deployment was-db-migration].include?(r.dig('metadata', 'name')) }
        .flat_map { |r| r.dig('spec', 'template', 'spec', 'containers') }
        .map { |c| c.fetch('image') }.sort
  end

  %w[dev prod].each do |overlay|
    define_method("test_#{overlay}_sha_replacement_includes_migration") do
      success('bash', 'scripts/ci/update-images.sh', "k8s/overlays/#{overlay}")
      assert_equal ["#{PLACEHOLDER}/was:#{SHA}"] * 2 + ["#{PLACEHOLDER}/web:#{SHA}"], images(overlay)
    end
  end

  def test_committed_overlays_have_full_sha_and_matching_names
    %w[dev prod].each do |overlay|
      actual = images(overlay)
      assert_equal 3, actual.length
      # No account-specific registry is committed for any environment.
      actual.each { |image| assert_match(%r{\A#{Regexp.escape(PLACEHOLDER)}/(?:was|web):[0-9a-f]{40}\z}, image) }
      config = YAML.load_file(File.join(@repo, "k8s/overlays/#{overlay}/kustomization.yaml"))
      assert_equal %w[food-delivery-was food-delivery-web], config.fetch('images').map { |i| i['name'] }.sort
    end
  end

  def test_previous_workflow_names_do_not_replace_base_images
    before = images('dev')
    success(kustomize, 'edit', 'set', 'image', "was=#{REGISTRY}/was:#{SHA}",
            "web=#{REGISTRY}/web:#{SHA}", directory: File.join(@repo, 'k8s/overlays/dev'))
    assert_equal before, images('dev')
    refute images('dev').any? { |image| image.end_with?(SHA) }
  end

  def test_non_full_sha_rejected_without_mutation
    path = File.join(@repo, 'k8s/overlays/dev/kustomization.yaml')
    before = File.read(path)
    %w[latest dev abc123].each do |sha|
      _, _, status = command('bash', 'scripts/ci/update-images.sh', env: @env.merge('SOURCE_SHA' => sha))
      refute status.success?
      assert_equal before, File.read(path)
    end
  end

  def initialize_git
    success('git', 'init', '-b', 'main')
    success('git', 'config', 'user.name', 'Local Test')
    success('git', 'config', 'user.email', 'local-test@example.invalid')
    FileUtils.mkdir_p(File.join(@repo, 'app'))
    File.write(File.join(@repo, 'app/source.txt'), 'source A')
    commit_all('source A')
    @env['SOURCE_SHA'] = success('git', 'rev-parse', 'HEAD').strip
    @remote = File.join(@tmp, 'remote.git')
    success('git', 'init', '--bare', @remote)
    success('git', 'remote', 'add', 'origin', @remote)
    success('git', 'push', 'origin', 'main')
    @operator = File.join(@tmp, 'operator')
    success('git', 'clone', '-b', 'main', @remote, @operator)
    success('git', 'config', 'user.name', 'Operator Test', directory: @operator)
    success('git', 'config', 'user.email', 'operator@example.invalid', directory: @operator)
  end

  def commit_all(message, directory: @repo)
    success('git', 'add', '.', directory: directory)
    success('git', 'commit', '-m', message, directory: directory)
  end

  def test_gitops_push_records_source_and_digests_preserving_remote_changes
    initialize_git
    File.write(File.join(@operator, 'operator-note.txt'), 'preserve this')
    commit_all('operator documentation', directory: @operator)
    success('git', 'push', 'origin', 'main', directory: @operator)
    success('bash', 'scripts/ci/commit-dev-images.sh')
    assert_equal 'preserve this', File.read(File.join(@repo, 'operator-note.txt'))
    message = success('git', 'log', '-1', '--format=%B')
    assert_includes message, "Source-Commit: #{@env['SOURCE_SHA']}"
    assert_includes message, "WAS-Digest: #{DIGEST}"
    assert_includes message, "WEB-Digest: #{DIGEST}"
    assert_includes message, '[skip ci]'
    assert images('dev').all? { |image| image.end_with?(@env['SOURCE_SHA']) }
    assert_equal success('git', 'rev-parse', 'HEAD').strip,
                 success('git', '--git-dir', @remote, 'rev-parse', 'refs/heads/main').strip
  end

  def test_newer_application_commit_prevents_stale_deployment
    initialize_git
    File.write(File.join(@operator, 'app/source.txt'), 'source B')
    commit_all('source B', directory: @operator)
    success('git', 'push', 'origin', 'main', directory: @operator)
    before = File.read(File.join(@repo, 'k8s/overlays/dev/kustomization.yaml'))
    assert_includes success('bash', 'scripts/ci/commit-dev-images.sh'), 'skip outdated deployment'
    assert_equal before, File.read(File.join(@repo, 'k8s/overlays/dev/kustomization.yaml'))
  end

  def test_newer_revert_still_prevents_old_source_promotion
    initialize_git
    File.write(File.join(@operator, 'app/source.txt'), 'source B')
    commit_all('source B', directory: @operator)
    File.write(File.join(@operator, 'app/source.txt'), 'source A')
    commit_all('revert source B', directory: @operator)
    success('git', 'push', 'origin', 'main', directory: @operator)
    assert_includes success('bash', 'scripts/ci/commit-dev-images.sh'), 'skip outdated deployment'
    assert_equal @env['SOURCE_SHA'], success('git', 'rev-parse', 'HEAD').strip
  end

  def test_manifest_revert_restores_previous_sha
    initialize_git
    previous = images('dev')
    success('bash', 'scripts/ci/commit-dev-images.sh')
    refute_equal previous, images('dev')
    success('git', 'revert', '--no-edit', 'HEAD')
    assert_equal previous, images('dev')
  end

  def test_tag_build_does_not_promote_or_fetch
    before = File.read(File.join(@repo, 'k8s/overlays/dev/kustomization.yaml'))
    out = success('bash', 'scripts/ci/commit-dev-images.sh', env: @env.merge('GITHUB_REF' => 'refs/tags/v1.2.3'))
    assert_includes out, 'publish images only'
    assert_equal before, File.read(File.join(@repo, 'k8s/overlays/dev/kustomization.yaml'))
  end

  def publishing_stubs
    bin = File.join(@tmp, 'bin')
    FileUtils.mkdir_p(bin)
    aws = <<~'SH'
      #!/usr/bin/env bash
      set -eu
      test "$1 $2" = 'ecr batch-get-image'
      if [[ -f "${PUSH_LOG:-/nonexistent}" ]] && grep -q "/${4}:" "$PUSH_LOG"; then
        printf '{"images":[{"imageId":{"imageDigest":"%s"}}],"failures":[]}\n' "${REMOTE_DIGEST:-$WAS_DIGEST}"
      elif [[ "${TAG_EXISTS:-false}" == true ]]; then
        echo '{"images":[{"imageId":{"imageDigest":"existing"}}],"failures":[]}'
      elif [[ "${QUERY_FAILURE:-false}" == true ]]; then
        echo '{"images":[],"failures":[{"failureCode":"KmsError"}]}'
      else
        echo '{"images":[],"failures":[{"failureCode":"ImageNotFound"}]}'
      fi
    SH
    docker = <<~'SH'
      #!/usr/bin/env bash
      set -eu
      if [[ "$1" == push ]]; then
        echo "$2" >> "$PUSH_LOG"
        printf 'image: digest: %s size: 1234\n' "$WAS_DIGEST"
      elif [[ "$1 $2" == 'image inspect' && "$5" == *revision* ]]; then
        echo "${IMAGE_REVISION:-$SOURCE_SHA}"
      elif [[ "$1 $2" == 'image inspect' && "$5" == *RepoDigests* ]]; then
        repository="${3%:*}"
        printf '["%s@%s"]\n' "$repository" "$WAS_DIGEST"
      else
        echo 'Unexpected Docker command' >&2
        exit 1
      fi
    SH
    { 'aws' => aws, 'docker' => docker }.each do |name, text|
      path = File.join(bin, name)
      File.write(path, text)
      File.chmod(0755, path)
    end
    @env.merge!('PATH' => "#{bin}:#{ENV.fetch('PATH')}",
                'GITHUB_OUTPUT' => File.join(@tmp, 'outputs'),
                'GITHUB_STEP_SUMMARY' => File.join(@tmp, 'summary'),
                'PUSH_LOG' => File.join(@tmp, 'pushes'))
  end

  def test_publish_uses_scanned_local_sha_images_and_records_digests
    publishing_stubs
    success('bash', 'scripts/ci/publish-images.sh', 'check')
    refute File.exist?(@env['PUSH_LOG'])
    success('bash', 'scripts/ci/publish-images.sh', 'publish')
    assert_equal ["#{REGISTRY}/was:#{SHA}", "#{REGISTRY}/web:#{SHA}"], File.readlines(@env['PUSH_LOG'], chomp: true)
    assert_equal ["was_digest=#{DIGEST}", "web_digest=#{DIGEST}"], File.readlines(@env['GITHUB_OUTPUT'], chomp: true)
  end

  def test_existing_sha_and_query_failure_both_block_all_pushes
    publishing_stubs
    %w[TAG_EXISTS QUERY_FAILURE].each do |flag|
      _, _, status = command('bash', 'scripts/ci/publish-images.sh', env: @env.merge(flag => 'true'))
      refute status.success?
      refute File.exist?(@env['PUSH_LOG'])
    end
  end

  def test_wrong_image_revision_blocks_all_pushes
    publishing_stubs
    _, _, status = command('bash', 'scripts/ci/publish-images.sh', env: @env.merge('IMAGE_REVISION' => 'incorrect'))
    refute status.success?
    refute File.exist?(@env['PUSH_LOG'])
  end

  def test_registry_digest_mismatch_blocks_gitops_output
    publishing_stubs
    _, _, status = command('bash', 'scripts/ci/publish-images.sh',
                           env: @env.merge('REMOTE_DIGEST' => "sha256:#{'b' * 64}"))
    refute status.success?
    refute File.exist?(@env['GITHUB_OUTPUT'])
    assert_equal 1, File.readlines(@env['PUSH_LOG']).length
  end

  def test_workflow_and_argocd_contract
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/deploy.yml'))
    triggers = workflow['on'] || workflow[true] # Ruby/Psych YAML 1.1 treats on as true.
    assert_equal ['push'], triggers.keys
    assert_equal ['main'], triggers.dig('push', 'branches')
    assert_equal ['v*'], triggers.dig('push', 'tags')
    refute triggers.dig('push', 'paths').any? { |path| path.start_with?('k8s/', 'infra/') }
    assert_equal({ 'id-token' => 'write', 'contents' => 'write' }, workflow['permissions'])
    steps = workflow.dig('jobs', 'build-and-deploy', 'steps')
    builds = steps.select { |step| step['uses'].to_s.start_with?('docker/build-push-action@') }
    assert_equal 2, builds.length
    builds.each do |build|
      assert_equal true, build.dig('with', 'load')
      refute build.dig('with', 'push')
      assert_includes build.dig('with', 'tags'), '${{ env.SOURCE_SHA }}'
      refute_includes build.dig('with', 'tags'), 'latest'
    end
    publish = steps.index { |step| step['id'] == 'publish' }
    scans = steps.each_index.select { |i| steps[i]['uses'].to_s.start_with?('aquasecurity/trivy-action@') }
    assert_equal 2, scans.length
    scans.each do |i|
      assert_operator i, :<, publish
      assert_equal 'aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25', steps[i]['uses']
      assert_equal 'v0.70.0', steps[i].dig('with', 'version')
      assert_equal true, steps[i].dig('with', 'ignore-unfixed')
      assert_equal '1', steps[i].dig('with', 'exit-code')
      assert_equal 'CRITICAL,HIGH', steps[i].dig('with', 'severity')
    end
    assert_equal builds.map { |build| build.dig('with', 'tags') },
                 scans.map { |i| steps[i].dig('with', 'image-ref') }
    builds.each do |build|
      assert_includes build.dig('with', 'labels'), 'org.opencontainers.image.revision=${{ env.SOURCE_SHA }}'
    end
    refute File.read(File.join(ROOT, '.github/workflows/deploy.yml')).match?(/AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY/)
    promotion = steps.find { |step| step['run'].to_s.include?('commit-dev-images.sh') }
    assert_equal "github.ref == 'refs/heads/main'", promotion['if']
    argo = YAML.load_file(File.join(ROOT, 'argocd-app.yaml'))
    assert_equal 'git@github.com:jx-dohwan/food-delivery-eks-platform.git', argo.dig('spec', 'source', 'repoURL')
    assert_equal 'main', argo.dig('spec', 'source', 'targetRevision')
    assert_equal 'k8s/overlays/dev', argo.dig('spec', 'source', 'path')
    assert argo.dig('spec', 'syncPolicy', 'automated')
  end
end
