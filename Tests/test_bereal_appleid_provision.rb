# frozen_string_literal: true
# Offline worker tests: the injected API below cannot contact Apple.
require_relative '../scripts/bereal-appleid-provision'
require 'tmpdir'
require 'stringio'

RESOURCE = Struct.new(:id, :certificate_type, :certificate_content, :expiration_date,
                      :platform, :status, :device_class, :udid, :identifier,
                      :profile_type, :profile_state, :profile_content, :uuid,
                      keyword_init: true)

def assert(value, message = 'assertion failed')
  raise message unless value
end

def fails(reason)
  begin
    yield
    raise "expected #{reason}"
  rescue BeRealAppleID::Failure => error
    assert(error.reason == reason, "expected #{reason}, got #{error.reason}")
  end
end

def fixture
  team = 'ABCD123456'
  key = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version, cert.serial = 2, 1
  cert.subject = OpenSSL::X509::Name.parse("/CN=Apple Distribution: Offline Test/OU=#{team}")
  cert.issuer = cert.subject
  cert.public_key = key.public_key
  cert.not_before, cert.not_after = Time.now - 60, Time.now + 3600
  cert.sign(key, OpenSSL::Digest::SHA256.new)
  der = cert.to_der
  context = { 'team_id' => team, 'certificate_sha256' => Digest::SHA256.hexdigest(der),
              'target_bundle_identifiers' => BeRealAppleID::TARGETS.dup, 'expected_enabled_device_count' => 1 }
  state = { agreements: { 'resultCode' => 0, 'pendingAgreements' => [] }, calls: [],
            certs: [RESOURCE.new(id: 'CERT1', certificate_type: 'DISTRIBUTION',
              certificate_content: Base64.strict_encode64(der), expiration_date: (Time.now + 3600).iso8601)],
            devices: [RESOURCE.new(id: 'DEV1', platform: 'IOS', status: 'ENABLED', device_class: 'IPHONE', udid: 'test-device')],
            bundles: [], profiles: [], grants: {}, der: der, context: context }
  api = Module.new
  api.const_set(:Client, Class.new do
    define_singleton_method(:login) do |user, password, **options|
      state[:calls] << [:login, options]
      raise 'credentials not forwarded' unless user == 'offline@example.invalid' && password == 'synthetic-password'
      portal = Object.new
      portal.define_singleton_method(:list_pending_agreements) { |**_options| state[:agreements] }
      client = Object.new
      client.define_singleton_method(:portal_team_id) { state[:wrong_team] || context['team_id'] }
      client.define_singleton_method(:portal_client) { portal }
      client.define_singleton_method(:provisioning_request_client) { raise 'unexpected API content fetch' }
      client
    end
  end)
  api.const_set(:Certificate, Class.new do
    define_singleton_method(:all) { |**_options| state[:certs] }
  end)
  api.const_set(:Device, Class.new do
    define_singleton_method(:all) { |**_options| state[:devices] }
  end)
  api.const_set(:BundleId, Class.new do
    define_singleton_method(:all) do |**options|
      state[:bundles].select { |bundle| bundle.identifier == options[:filter][:identifier] }
    end
    define_singleton_method(:create) do |**options|
      state[:calls] << [:bundle_create, options.reject { |key, _value| key == :client }]
      bundle = RESOURCE.new(id: "BUNDLE#{state[:bundles].length}", identifier: options[:identifier], platform: options[:platform])
      state[:bundles] << bundle
      bundle
    end
  end)
  api.const_set(:Profile, Class.new do
    define_singleton_method(:all) { |**_options| state[:profiles] }
    define_singleton_method(:create) do |**options|
      state[:calls] << [:profile_create, options.reject { |key, _value| key == :client }]
      bundle = state[:bundles].find { |item| item.id == options[:bundle_id_id] }
      new_profile(state, bundle.identifier, invalid: state[:invalid_created])
    end
  end)
  output = StringIO.new
  channel = BeRealAppleID::Channel.new(output)
  worker = BeRealAppleID::Worker.new(context, channel, api: api,
                                    profile_decoder: ->(token) { state[:grants].fetch(token) })
  [worker, state, output]
end

def new_profile(state, identifier, invalid: false)
  uuid = format('00000000-0000-0000-0000-%012d', state[:profiles].length + 1)
  token = "private-profile-#{uuid}"
  grant = { 'UUID' => uuid, 'TeamIdentifier' => [state[:context]['team_id']],
            'ApplicationIdentifierPrefix' => [state[:context]['team_id']],
            'ExpirationDate' => Time.now + 3600, 'DeveloperCertificates' => [state[:der]],
            'ProvisionedDevices' => invalid ? %w[test-device additional-device] : ['test-device'],
            'Entitlements' => { 'application-identifier' => "#{state[:context]['team_id']}.#{identifier}",
              'com.apple.developer.team-identifier' => state[:context]['team_id'], 'get-task-allow' => false } }
  state[:grants][token] = grant
  profile = RESOURCE.new(id: uuid, uuid: uuid, profile_content: token,
                         profile_type: 'IOS_APP_ADHOC', profile_state: 'ACTIVE',
                         expiration_date: (Time.now + 3600).iso8601)
  state[:profiles] << profile
  profile
end

def creds
  { 'apple_id' => 'offline@example.invalid'.dup, 'password' => 'synthetic-password'.dup }
end

tests = {}
tests['scope validation rejects unrelated targets'] = lambda do
  _worker, state, _output = fixture
  context = state[:context].merge('target_bundle_identifiers' => BeRealAppleID::TARGETS + ['com.unrelated.app'])
  fails('invalid_context') { BeRealAppleID.validate_context(context) }
end
tests['private credential source removed even when JSON malformed'] = lambda do
  Dir.mktmpdir do |directory|
    path = File.join(directory, 'credentials.json')
    File.write(path, '{malformed', mode: 'w', perm: 0o600)
    fails('invalid_private_input') { BeRealAppleID.read_private_json(path, delete_after_read: true) }
    assert(!File.exist?(path))
  end
end
tests['private credential source read and removed'] = lambda do
  Dir.mktmpdir do |directory|
    path = File.join(directory, 'credentials.json')
    File.write(path, JSON.generate(creds), mode: 'w', perm: 0o600)
    loaded = BeRealAppleID.read_private_json(path, delete_after_read: true)
    assert(loaded == creds && !File.exist?(path))
  end
end
tests['credential symlinks are rejected without touching target'] = lambda do
  Dir.mktmpdir do |directory|
    path, link = File.join(directory, 'secret'), File.join(directory, 'link')
    File.write(path, JSON.generate(creds), mode: 'w', perm: 0o600)
    File.symlink(path, link)
    fails('invalid_private_input') { BeRealAppleID.read_private_json(link, delete_after_read: true) }
    assert(File.exist?(path))
  end
end
tests['creates only approved bundles and profiles with one existing cert and device'] = lambda do
  worker, state, output = fixture
  credentials = creds
  counts = worker.run(credentials)
  assert(counts[:created_bundle_count] == 5 && counts[:created_profile_count] == 5)
  calls = state[:calls].select { |kind, _details| kind == :profile_create }
  assert(calls.all? { |_kind, details| details[:certificate_ids] == ['CERT1'] && details[:device_ids] == ['DEV1'] && details[:profile_type] == 'IOS_APP_ADHOC' })
  login = state[:calls].first.last
  assert(login == { use_portal: true, use_tunes: false, portal_team_id: 'ABCD123456' })
  assert(credentials.values.all?(&:empty?))
  event = JSON.parse(output.string)
  assert(event['event'] == 'provisioning_complete' && event['provisioned_bundle_count'] == 5)
  assert(!output.string.include?('test-device') && !output.string.include?('CERT1') && !output.string.include?('example.invalid'))
end
tests['compatible profiles reused with no writes'] = lambda do
  worker, state, _output = fixture
  BeRealAppleID::TARGETS.each_with_index do |identifier, index|
    state[:bundles] << RESOURCE.new(id: "BUNDLE#{index}", identifier: identifier, platform: 'IOS')
    new_profile(state, identifier)
  end
  counts = worker.run(creds)
  assert(counts[:reused_bundle_count] == 5 && counts[:reused_profile_count] == 5)
  assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
end
tests['unrelated profile not reused or modified'] = lambda do
  worker, state, _output = fixture
  unrelated = new_profile(state, 'com.existing.y3app')
  snapshot = unrelated.to_h.dup
  counts = worker.run(creds)
  assert(counts[:created_profile_count] == 5 && unrelated.to_h == snapshot)
end
tests['pending agreements halt before resource creation'] = lambda do
  worker, state, _output = fixture
  state[:agreements] = { 'pendingAgreements' => [{ 'agreementName' => 'private legal text' }] }
  begin
    worker.run(creds)
    raise 'expected agreement halt'
  rescue BeRealAppleID::AgreementRequired
    assert(state[:calls].length == 1)
  end
end
tests['unknown optional agreement response lets normal API enforce access'] = lambda do
  worker, state, _output = fixture
  state[:agreements] = { 'resultCode' => 0 }
  counts = worker.run(creds)
  assert(counts[:created_profile_count] == 5 && counts[:agreement_status_known] == false)
end
tests['wrong team halts before writes'] = lambda do
  worker, state, _output = fixture
  state[:wrong_team] = 'ZZZZ123456'
  fails('team_mismatch') { worker.run(creds) }
  assert(state[:calls].length == 1)
end
tests['wrong certificate fingerprint halts before writes'] = lambda do
  worker, state, _output = fixture
  state[:certs].clear
  fails('certificate_mismatch') { worker.run(creds) }
  assert(state[:calls].length == 1)
end
tests['more than one enabled IOS device halts before writes'] = lambda do
  worker, state, _output = fixture
  state[:devices] << state[:devices].first.dup
  fails('device_count_mismatch') { worker.run(creds) }
  assert(state[:calls].length == 1)
end
tests['ambiguous scoped registration halts before any writes'] = lambda do
  worker, state, _output = fixture
  2.times { state[:bundles] << RESOURCE.new(id: 'DUP', identifier: BeRealAppleID::TARGETS.last, platform: 'IOS') }
  fails('ambiguous_bundle') { worker.run(creds) }
  assert(state[:calls].length == 1)
end
tests['created profile covering another device cannot complete'] = lambda do
  worker, state, output = fixture
  state[:invalid_created] = true
  fails('profile_verification_failed') { worker.run(creds) }
  assert(output.string.empty?)
end
tests['CMS signature verified before embedded profile is decoded'] = lambda do
  key = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version, cert.serial = 2, 1
  cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=Offline CMS Fixture')
  cert.public_key = key.public_key
  cert.not_before, cert.not_after = Time.now - 60, Time.now + 3600
  cert.sign(key, OpenSSL::Digest::SHA256.new)
  plist = '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>UUID</key><string>test-uuid</string><key>ProvisionedDevices</key><array><string>private-device</string></array></dict></plist>'
  cms = OpenSSL::PKCS7.sign(cert, key, plist, [], OpenSSL::PKCS7::BINARY)
  decoded = BeRealAppleID.decode_profile(Base64.strict_encode64(cms.to_der))
  assert(decoded['UUID'] == 'test-uuid' && decoded['ProvisionedDevices'] == ['private-device'])
  raw = cms.to_der
  raw.setbyte(raw.bytesize - 1, raw.getbyte(raw.bytesize - 1) ^ 1)
  begin
    BeRealAppleID.decode_profile(Base64.strict_encode64(raw))
    raise 'corrupt CMS accepted'
  rescue BeRealAppleID::ProfileRejected
    # The synthetic signature is checked; Apple's trust chain is verified by
    # the existing independent signer/delivery checks rather than this fixture.
  end
end
tests['two factor has unique request nonce and bounded attempts'] = lambda do
  events_read, events_write = IO.pipe
  input_read, input_write = IO.pipe
  channel = BeRealAppleID::Channel.new(events_write, input: input_read, timeout: 1)
  nonces = []
  3.times do |index|
    responder = Thread.new do
      event = JSON.parse(events_read.gets)
      assert(event['event'] == 'two_factor_required' && event['attempt'] == index + 1)
      nonces << event['challenge_nonce']
      input_write.puts(JSON.generate(code: '123456', challenge_nonce: event['challenge_nonce']))
    end
    assert(channel.two_factor_code == '123456')
    responder.value
  end
  assert(nonces.uniq.length == 3 && nonces.all? { |value| /\A[0-9a-f]{64}\z/.match?(value) })
  fails('two_factor_attempt_limit') { channel.two_factor_code }
ensure
  [events_read, events_write, input_read, input_write].compact.each(&:close)
end
tests['two factor replay nonce rejected'] = lambda do
  events_read, events_write = IO.pipe
  input_read, input_write = IO.pipe
  channel = BeRealAppleID::Channel.new(events_write, input: input_read, timeout: 1)
  input_write.puts(JSON.generate(code: '123456', challenge_nonce: '0' * 64))
  fails('two_factor_input_rejected') { channel.two_factor_code }
ensure
  [events_read, events_write, input_read, input_write].compact.each(&:close)
end
tests['two factor does not substitute timeout with approval'] = lambda do
  output = StringIO.new
  input_read, input_write = IO.pipe
  channel = BeRealAppleID::Channel.new(output, input: input_read, timeout: 0.001)
  fails('two_factor_timeout') { channel.two_factor_code }
ensure
  [input_read, input_write].compact.each(&:close)
end
tests['private hooks suppress all persistent credentials and request logging'] = lambda do
  Object.const_set(:Spaceship, Module.new) unless Object.const_defined?(:Spaceship)
  Spaceship.const_set(:Client, Class.new do
    def store_cookie(**_options) = raise('persistent cookie write attempted')
    def load_session_from_file = raise('persistent session read attempted')
    def load_session_from_env = raise('environment session reuse attempted')
    def cached_service_key = raise('persistent service key read attempted')
    def cache_service_key(_key) = raise('persistent service key write attempted')
    def ask_for_2fa_code(_prompt) = raise('raw prompt attempted')
  end)
  fake_channel = Object.new
  fake_channel.define_singleton_method(:two_factor_code) { '123456' }
  BeRealAppleID.install_private_hooks(fake_channel)
  client = Spaceship::Client.new
  assert(client.store_cookie.nil? && client.load_session_from_file == false && client.load_session_from_env == false)
  assert(client.cached_service_key.nil? && client.cache_service_key('synthetic-widget-key').nil?)
  assert(client.ask_for_2fa_code('private prompt') == '123456')
  assert(client.logger.is_a?(Logger))
  fails('unsupported_authentication') { client.handle_two_step(nil) }
  fails('unsupported_authentication') { client.choose_phone_number(['private number']) }
end

tests.each do |name, test|
  test.call
  puts "PASS #{name}"
end
puts "#{tests.length} offline tests passed; no Apple login or resource changes"
