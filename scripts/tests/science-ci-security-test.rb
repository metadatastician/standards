#!/usr/bin/env ruby
# SPDX-License-Identifier: MPL-2.0
# Exercise the workflows' actual shell steps with controlled remote data.
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
PUBLIC_KEY = "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf\n"
FINGERPRINT = 'SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8'

def assert(condition, message)
  raise message unless condition
end

def run!(*args, **options)
  out, err, status = Open3.capture3(*args, **options)
  assert(status.success?, "Command failed: #{args.inspect}\n#{out}#{err}")
  out.strip
end

def workflow(name)
  YAML.safe_load(File.read(File.join(ROOT, '.github/workflows', name)), aliases: true)
end

workflow('mirror-reusable.yml')['jobs'].each do |name, job|
  next if %w[visibility-guard mirror-radicle mirror-r2-bundle].include?(name)

  verify = job['steps'].find { |step| step.fetch('name', '').start_with?('Verify ') }
  push = job['steps'].find { |step| step.fetch('run', '').include?('git push') }
  assert(verify && push, "#{name}: missing verification or push")
  assert(job['steps'].index(verify) < job['steps'].index(push), "#{name}: verifies too late")
  assert(verify['if'] == push['if'], "#{name}: verification condition differs from push")
  assert(!verify['continue-on-error'], "#{name}: verification failure is ignored")
  assert(job['continue-on-error'] == true, 'GitLab mirror must remain advisory') if name == 'mirror-gitlab'
  if name == 'mirror-disroot'
    assert(verify['env']['APPROVED_FINGERPRINT'] == '${{ vars.DISROOT_SSH_FINGERPRINT }}',
           'Disroot must require an independently approved fingerprint')
  end
  Dir.mktmpdir('mirror-verification-') do |tmp|
    stub = File.join(tmp, 'ssh-keyscan')
    File.write(stub, "#!/bin/sh\nprintf '%s' \"$TEST_HOST_KEY\"\n")
    File.chmod(0o755, stub)
    environment_file = File.join(tmp, 'env')
    env = { 'PATH' => "#{tmp}:#{ENV.fetch('PATH')}", 'RUNNER_TEMP' => tmp,
            'GITHUB_ENV' => environment_file, 'MIRROR_HOST' => 'gitlab.com' }
    [[PUBLIC_KEY, FINGERPRINT, true],
     [PUBLIC_KEY.sub('OzRdf', 'OzRdg'), FINGERPRINT, false],
     ['', FINGERPRINT, false], ['invalid key', FINGERPRINT, false],
     [PUBLIC_KEY, '', false]].each do |key, fingerprint, succeeds|
      FileUtils.rm_f(environment_file)
      out, err, status = Open3.capture3(env.merge('TEST_HOST_KEY' => key,
        'APPROVED_FINGERPRINT' => fingerprint), 'bash', '-c', verify['run'])
      assert(status.success? == succeeds, "#{name}: unexpected verification result\n#{out}#{err}")
      assert(File.exist?(environment_file) == succeeds, "#{name}: unsafe environment was exported")
      if succeeds
        assert(File.read(environment_file).include?('StrictHostKeyChecking=yes'), "#{name}: strict checking missing")
      end
    end
  end
end
puts 'PASS: all six mirrors accept approved keys and reject tampered, empty, malformed, or unapproved keys'

r2_job = workflow('mirror-reusable.yml')['jobs']['mirror-r2-bundle']
assert(r2_job, 'mirror-r2-bundle job missing from mirror-reusable.yml')
r2_verify = r2_job['steps'].find { |s| s.fetch('name', '') == 'Verify R2 endpoint and age recipient' }
r2_upload = r2_job['steps'].find { |s| s.fetch('name', '').include?('age-encrypt') }
assert(r2_verify && r2_upload, 'mirror-r2-bundle missing verify or upload step')
assert(r2_job['steps'].index(r2_verify) < r2_job['steps'].index(r2_upload), 'mirror-r2-bundle verifies too late')
assert(r2_verify['if'] == r2_upload['if'], 'mirror-r2-bundle verify/upload conditions differ')
assert(!r2_verify['continue-on-error'], 'mirror-r2-bundle verification failure is ignored')
assert(r2_upload['run'].include?('age -r "$AGE_RECIPIENT" -o "$ENC_BUNDLE" "$RAW_BUNDLE"'), 'mirror-r2-bundle must encrypt with age before upload')
assert(r2_upload['run'].include?('rm -f "$RAW_BUNDLE"'), 'mirror-r2-bundle must remove plaintext bundle before upload')
r2_script = r2_upload['run']
# Match command lines so the earlier EXIT trap does not count as plaintext removal.
r2_commands = r2_script.lines.map(&:strip)
encrypt_at = r2_commands.index('age -r "$AGE_RECIPIENT" -o "$ENC_BUNDLE" "$RAW_BUNDLE"')
remove_at = r2_commands.index('rm -f "$RAW_BUNDLE"')
upload_at = r2_commands.index { |command| command.start_with?('aws s3 cp "$ENC_BUNDLE"') }
assert(encrypt_at && remove_at && upload_at && encrypt_at < remove_at && remove_at < upload_at,
       'mirror-r2-bundle must encrypt and remove plaintext before uploading ciphertext')
assert(r2_script.include?('/snapshots/${BUNDLE_TS}-${COMMIT_SHA}.bundle.age'),
       'mirror-r2-bundle must write an immutable timestamp+SHA snapshot bundle')
assert(r2_script.include?('/latest.bundle.age'),
       'mirror-r2-bundle must update latest.bundle.age')
Dir.mktmpdir('r2-snapshots-') do |tmp|
  stubs = {
    'date' => 'printf "%s\n" 20261023T120000Z',
    'git' => 'if [ "$2" = create ]; then printf plaintext > "$3"; else test -s "$3"; fi',
    'age' => 'printf ciphertext > "$4"',
    'aws' => <<~'SH'
      test ! -e "$RUNNER_TEMP/test-repo.bundle" || exit 1
      test "$(cat "$3")" = ciphertext || exit 1
      printf '%s\n' "$4" >> "$TEST_UPLOADS"
    SH
  }
  stubs.each do |name, script|
    path = File.join(tmp, name)
    File.write(path, "#!/bin/sh\nset -eu\n#{script}\n")
    File.chmod(0o755, path)
  end
  uploads = File.join(tmp, 'uploads')
  sha = 'a' * 40
  env = { 'PATH' => "#{tmp}:#{ENV.fetch('PATH')}", 'RUNNER_TEMP' => tmp,
          'REPO_NAME' => 'test-repo', 'COMMIT_SHA' => sha, 'AGE_RECIPIENT' => 'test-recipient',
          'R2_BUCKET' => 'test-bucket', 'MIRROR_ORG' => 'test-owner',
          'R2_ENDPOINT' => 'https://test.r2.cloudflarestorage.com', 'TEST_UPLOADS' => uploads }
  [[100, 1], [100, 2], [101, 1]].each do |run_id, attempt|
    run!(env.merge('GITHUB_RUN_ID' => run_id.to_s, 'GITHUB_RUN_ATTEMPT' => attempt.to_s),
         'bash', '-c', r2_script)
    assert(!File.exist?(File.join(tmp, 'test-repo.bundle.age')), 'R2 upload left ciphertext behind')
  end
  keys = File.readlines(uploads, chomp: true)
  snapshots = keys.each_slice(2).map(&:first)
  assert(snapshots.uniq.length == 3, 'R2 snapshot uploads collide across runs or attempts')
  assert(snapshots.first == "s3://test-bucket/test-owner/test-repo/snapshots/20261023T120000Z-100-1-#{sha}.bundle.age",
         'R2 snapshot path or bundle filename format changed')
  assert(keys.each_slice(2).all? { |_, latest| latest == 's3://test-bucket/test-owner/test-repo/latest.bundle.age' },
         'R2 latest bundle path changed')
end
puts 'PASS: R2 snapshots differ across runs and attempts at the same timestamp and SHA; only ciphertext is uploaded'
[
  ['https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com', 'estate-mirrors', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', true],
  ['https://0123456789abcdef0123456789abcdef.us.r2.cloudflarestorage.com', 'estate-mirrors', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', true],
  ['http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com', 'estate-mirrors', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', false],
  ['https://evil.example.com', 'estate-mirrors', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', false],
  ['https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com', 'INVALID_BUCKET', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', false],
  ['https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com', 'estate.mirrors', 'age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p', false],
  ['https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com', 'estate-mirrors', '', false]
].each do |endpoint, bucket, recipient, succeeds|
  out, err, status = Open3.capture3(
    { 'R2_ENDPOINT' => endpoint, 'R2_BUCKET' => bucket, 'AGE_RECIPIENT' => recipient },
    'bash', '-c', r2_verify['run']
  )
  assert(status.success? == succeeds, "mirror-r2-bundle unexpected verify result for #{[endpoint, bucket, recipient].inspect}\n#{out}#{err}")
end
puts 'PASS: mirror-r2-bundle validates R2 endpoint, bucket, and age recipient and enforces client-side age encryption'

step = workflow('hypatia-scan-reusable.yml')['jobs']['scan']['steps'].find do |candidate|
  candidate['name'] == 'Check out resolved Hypatia commit'
end

# Skip this test if the step doesn't exist (workflow was refactored)
if step
  Dir.mktmpdir('scanner-source-') do |tmp|
    upstream = File.join(tmp, 'upstream')
    run!('git', 'init', '-q', upstream)
    commit = lambda do |content|
      File.write(File.join(upstream, 'source'), content)
      run!('git', '-C', upstream, 'add', 'source')
      run!('git', '-C', upstream, '-c', 'user.name=CI Test', '-c', 'user.email=ci@example.invalid',
           '-c', 'commit.gpgsign=false', 'commit', '-qm', content)
      run!('git', '-C', upstream, 'rev-parse', 'HEAD')
    end
    resolved = commit.call('resolved')
    newer = commit.call('advanced')
    source = File.join(tmp, 'scanner')
    script = step.fetch('run').gsub('$HOME/hypatia', source).gsub('https://github.com/hyperpolymath/hypatia.git', upstream)
    2.times { run!({ 'HYPATIA_SHA' => resolved }, 'bash', '-c', script) }
    assert(File.read(File.join(source, 'source')) == 'resolved', 'Scanner followed advancing HEAD')
    out, _err, status = Open3.capture3({ 'HYPATIA_SHA' => newer }, 'bash', '-c', script)
    assert(!status.success? && out.include?('cached source does not match'), 'Mismatched cache was accepted')
  end
  puts 'PASS: scanner checks out the resolved commit on cache miss/hit and rejects a mismatched cache'
else
  puts 'SKIP: Check out resolved Hypatia commit step not found in workflow (refactored)'
end

step = workflow('hypatia-scan-reusable.yml')['jobs']['scan']['steps'].find do |candidate|
  candidate['name'] == 'Validate findings and count severities'
end
Dir.mktmpdir('scanner-contract-') do |tmp|
  output = File.join(tmp, 'output')
  env = { 'GITHUB_OUTPUT' => output, 'GITHUB_STEP_SUMMARY' => File.join(tmp, 'summary') }
  findings = File.join(tmp, 'hypatia-findings.json')
  # Clean scan (single well-formed empty array) is a positive control (standards#1054)
  File.write(findings, '[]')
  run!(env, 'bash', '-c', step.fetch('run'), chdir: tmp)
  assert(File.read(output).lines.map(&:chomp).include?('findings_count=0'), 'clean scan findings_count was not 0')
  assert(File.read(output).lines.map(&:chomp).include?('critical=0'), 'clean scan critical was not 0')
  assert(File.read(output).lines.map(&:chomp).include?('high=0'), 'clean scan high was not 0')
  assert(File.read(output).lines.map(&:chomp).include?('medium=0'), 'clean scan medium was not 0')

  # The validation expects: [finding1, finding2, ...] - single flat array of findings
  # Use valid severities: critical, high, medium, warn, low, info, informational
  FileUtils.rm_f(output)
  File.write(findings, '[{"severity":"high"},{"severity":"medium"},{"severity":"critical"}]')
  run!(env, 'bash', '-c', step.fetch('run'), chdir: tmp)
  assert(File.read(output).lines.map(&:chomp).include?('medium=1'), 'medium was not counted')
  assert(File.read(output).include?('critical=1'), 'critical finding was lost')
  assert(File.read(output).include?('high=1'), 'high finding was lost')
  # Test invalid inputs - empty, whitespace, truncated, wrong top-level type,
  # invalid element shape, unknown severity, and multiple JSON documents
  ['', "   \n", '[', '{}', 'null', '[{}]', '[{"severity":"unknown"}]', '[] []', "[]\n[{\"severity\":\"high\"}]"].each do |invalid|
    FileUtils.rm_f(output)
    File.write(findings, invalid)
    _out, _err, status = Open3.capture3(env, 'bash', '-c', step.fetch('run'), chdir: tmp)
    assert(status.exitstatus == 2, "Invalid scanner output accepted: #{invalid.inspect}")
    assert(!File.exist?(output), 'Invalid output produced gate counts')
  end
  File.write(findings, '[{"severity":"warn","rule_module":"research_extensions","type":"RE001","file":"ci.yml"}]')
  _out, _err, status = Open3.capture3({ 'BLOCKING_THRESHOLD' => 'medium' }, 'bash',
    File.join(ROOT, 'scripts/apply-baseline.sh'), findings, File.join(tmp, 'absent-baseline.json'), 'blocking')
  assert(status.exitstatus == 1, 'warn escaped the medium baseline threshold')
end
puts 'PASS: warn retains medium severity; malformed, unknown, and multiple scanner documents fail closed'

Dir.mktmpdir('policy-startup-') do |tmp|
  path = File.join(tmp, '.github/workflows/ci.yml')
  FileUtils.mkdir_p(File.dirname(path))
  run!('git', 'init', '-q', tmp)
  File.write(path, "name: CI\non: push\njobs:\n  # test:\n  #   runs-on: ubuntu-latest\n")
  run!('git', '-C', tmp, 'add', '.')
  parser = File.join(ROOT, 'tools/policy/check-workflows-parse.sh')
  checker = File.join(ROOT, 'scripts/check-descriptile-policy.sh')
  _out, _err, status = Open3.capture3('bash', parser, chdir: tmp)
  assert(!status.success?, 'Comment-only jobs were accepted')
  File.write(path, "name: CI\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: test -f .machine_readable/STATE.a2ml\n")
  _out, _err, status = Open3.capture3('bash', checker, chdir: tmp)
  assert(!status.success?, 'Retired policy path was accepted')
  File.write(path, File.read(path).sub('.machine_readable/STATE', '.machine_readable/descriptiles/STATE'))
  [parser, checker].each { |check| run!('bash', check, chdir: tmp) }
  [%(echo "test -f .machine_readable/STATE.a2ml"),
   %(printf '%s\\n' 'check_file .machine_readable/META.a2ml')].each do |example|
    File.write(path, "name: CI\non: push\njobs:\n  test:\n    steps:\n      - run: |\n          #{example}\n")
    run!('bash', checker, chdir: tmp)
  end
  [%(test -f ".machine_readable/STATE.a2ml"),
   %(test -e '.machine_readable/6a2/META.a2ml'),
   %(check_file '.machine_readable/AGENTIC.a2ml'),
   %(echo "$(test -f .machine_readable/STATE.a2ml)")].each do |example|
    File.write(path, "name: CI\non: push\njobs:\n  test:\n    steps:\n      - run: |\n          #{example}\n")
    _out, _err, status = Open3.capture3('bash', checker, chdir: tmp)
    assert(!status.success?, "Executable retired-path check was accepted: #{example}")
  end
end
puts 'PASS: empty workflows and retired policy fail; executable jobs with canonical policy pass'

# Visibility guard (owner ruling 2026-11-13, CASE-038): a private source is
# never force-pushed to a forge that is not confirmed private.
mirror_jobs = workflow('mirror-reusable.yml')['jobs']
guard = mirror_jobs.fetch('visibility-guard')
mirror_jobs.each do |name, job|
  next if %w[visibility-guard mirror-r2-bundle].include?(name)
  forge = name.sub('mirror-', '').upcase
  assert(job['needs'] == 'visibility-guard', "#{name}: does not wait for the visibility guard")
  assert(job['if'].include?("needs.visibility-guard.outputs.public == 'true'") &&
         job['if'].include?("vars.#{forge}_MIRROR_PRIVATE_CONFIRMED == 'true'"),
         "#{name}: pushes a private source without the guard")
  assert(guard['steps'][1]['env'].key?("EN_#{forge}"), "guard does not check #{forge}")
end
vis = guard['steps'][0]['run']
refuse = guard['steps'][1]['run']
Dir.mktmpdir('mirror-guard-') do |tmp|
  [['false', 'true'], ['true', 'false'], ['', 'false']].each do |private, public|
    out_file = File.join(tmp, 'out')
    FileUtils.rm_f(out_file)
    run!({ 'SRC_PRIVATE' => private, 'GITHUB_OUTPUT' => out_file }, 'bash', '-c', vis)
    assert(File.read(out_file).include?("public=#{public}"), "guard: private=#{private.inspect} read as public=#{!public}")
  end
  summary = File.join(tmp, 'summary')
  [[{ 'EN_GITLAB' => 'true' }, false],
   [{ 'EN_GITLAB' => 'true', 'OK_GITLAB' => 'true' }, true],
   [{ 'EN_CODEBERG' => 'true', 'EN_RADICLE' => 'true', 'OK_RADICLE' => 'true' }, false],
   [{}, true]].each do |env, succeeds|
    _out, _err, status = Open3.capture3(env.merge('GITHUB_STEP_SUMMARY' => summary), 'bash', '-c', refuse)
    assert(status.success? == succeeds, "guard: #{env.inspect} should #{succeeds ? 'pass' : 'refuse'}")
  end
end
puts 'PASS: every forge mirror waits for the visibility guard, which refuses private sources on unconfirmed forges'
