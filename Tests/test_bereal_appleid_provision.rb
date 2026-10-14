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
            bundles: [], bundle_read_filters: [], profiles: [], grants: {}, der: der, context: context }
  api = Module.new
  api.const_set(:Client, Class.new do
    define_singleton_method(:login) do |user, password, **options|
      state[:calls] << [:login, options]
      state[:sms_at_login] = ENV['SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER']
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
      state[:bundle_read_filters] << options[:filter].dup
      next state[:bundles].dup if state[:bundle_filter_ignored]
      state[:bundles].select { |bundle| bundle.identifier == options[:filter][:identifier] }
    end
    define_singleton_method(:create) do |**options|
      state[:calls] << [:bundle_create, options.reject { |key, _value| key == :client }]
      bundle = RESOURCE.new(id: "BUNDLE#{state[:bundles].length}",
                            identifier: state[:created_bundle_identifier] || options[:identifier],
                            platform: state[:created_bundle_platform] || options[:platform])
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
tests['optional SMS context accepts only E164 without changing signing scope'] = lambda do
  _worker, state, _output = fixture
  valid = state[:context].merge('sms_phone_number' => '+819011112233')
  assert(BeRealAppleID.validate_context(valid) == valid)
  [nil, '+0819011112233', '09011112233', '+81 9011112233', '+1234567', '+1234567890123456', 819011112233].each do |value|
    fails('invalid_context') { BeRealAppleID.validate_context(state[:context].merge('sms_phone_number' => value)) }
  end
end
tests['trusted SMS selection requires unique country prefix and visible suffix'] = lambda do
  target = '+819011112233'
  displayed = '+81 •••• ••••33'
  assert(BeRealAppleID.select_sms_option([displayed, '+1 (•••) •••-••44'], target) == displayed)
  assert(BeRealAppleID.select_sms_option(['+81 90-1111-2233'], target) == '+81 90-1111-2233')
  fails('unsupported_authentication') { BeRealAppleID.select_sms_option([displayed, '+81••••••••33'], target) }
  fails('unsupported_authentication') { BeRealAppleID.select_sms_option(['+1 (•••) •••-••33'], target) }
  fails('unsupported_authentication') { BeRealAppleID.select_sms_option(['+81 •••• ••••44'], target) }
  fails('unsupported_authentication') { BeRealAppleID.select_sms_option(['••••••••33'], target) }
end
tests['SMS never adds numbers or chooses a non SMS trusted entry'] = lambda do
  target = '+819011112233'
  trusted = { 'id' => 1, 'numberWithDialCode' => '+81 •••• ••••33', 'pushMode' => 'sms' }
  body = { 'trustedPhoneNumbers' => [trusted] }
  snapshot = Marshal.dump(body)
  assert(BeRealAppleID.select_trusted_sms_entry(body, target).equal?(trusted))
  assert(Marshal.dump(body) == snapshot)
  fails('unsupported_authentication') do
    BeRealAppleID.select_trusted_sms_entry({ 'trustedPhoneNumbers' => [trusted.merge('pushMode' => 'voice')] }, target)
  end
  fails('unsupported_authentication') { BeRealAppleID.select_trusted_sms_entry({ 'trustedPhoneNumbers' => [] }, target) }
end
tests['SMS target exists only in worker environment while normal login runs'] = lambda do
  worker, state, output = fixture
  state[:context]['sms_phone_number'] = '+819011112233'
  worker.run(creds)
  assert(state[:sms_at_login] == '+819011112233')
  assert(!ENV.key?('SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER') && !output.string.include?('+819011112233'))
  worker, state, _output = fixture
  state[:context]['sms_phone_number'] = '+819011112233'
  state[:certs].clear
  fails('certificate_mismatch') { worker.run(creds) }
  assert(!ENV.key?('SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER'))
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
tests['exact UNIVERSAL registrations reuse IOS Ad Hoc profiles with identifier-only reads'] = lambda do
  worker, state, _output = fixture
  state[:bundle_filter_ignored] = true
  state[:bundles] << RESOURCE.new(id: 'UNRELATED', identifier: 'com.other.app', platform: 'MAC_OS')
  BeRealAppleID::TARGETS.each_with_index do |identifier, index|
    state[:bundles] << RESOURCE.new(id: "UNIVERSAL#{index}", identifier: identifier, platform: 'UNIVERSAL')
    new_profile(state, identifier)
  end
  counts = worker.run(creds)
  assert(counts[:reused_bundle_count] == 5 && counts[:reused_profile_count] == 5)
  assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
  assert(state[:bundle_read_filters] == BeRealAppleID::TARGETS.map { |identifier| { identifier: identifier } })
end
tests['IOS create requests accept Apple normalized UNIVERSAL registration responses'] = lambda do
  worker, state, _output = fixture
  state[:created_bundle_platform] = 'UNIVERSAL'
  counts = worker.run(creds)
  assert(counts[:created_bundle_count] == 5 && counts[:created_profile_count] == 5)
  assert(state[:bundles].all? { |bundle| bundle.platform == 'UNIVERSAL' })
  created = state[:calls].select { |kind, _details| kind == :bundle_create }.map(&:last)
  assert(created.all? { |details| details[:platform] == 'IOS' })
  profile_calls = state[:calls].select { |kind, _details| kind == :profile_create }.map(&:last)
  assert(profile_calls.all? { |details| details[:profile_type] == 'IOS_APP_ADHOC' && details[:certificate_ids] == ['CERT1'] && details[:device_ids] == ['DEV1'] })
end
tests['normalized UNIVERSAL registration cannot weaken one-device profile validation'] = lambda do
  worker, state, output = fixture
  state[:created_bundle_platform], state[:invalid_created] = 'UNIVERSAL', true
  fails('profile_verification_failed') { worker.run(creds) }
  assert(output.string.empty?)
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
tests['ignored API filter with only unrelated and prefix candidates creates exactly approved scope'] = lambda do
  worker, state, _output = fixture
  state[:bundle_filter_ignored] = true
  unrelated = [
    RESOURCE.new(id: 'UNRELATED0', identifier: 'com.ayato.y3posclient', platform: 'IOS'),
    RESOURCE.new(id: 'UNRELATED1', identifier: 'com.ayato.bereal493.extra', platform: 'IOS'),
    RESOURCE.new(id: 'UNRELATED2', identifier: 'com.ayato.bereal493.Widgets.preview', platform: 'MAC_OS')
  ]
  state[:bundles].concat(unrelated)
  snapshot = unrelated.map { |item| item.to_h.dup }
  counts = worker.run(creds)
  assert(counts[:created_bundle_count] == 5 && counts[:created_profile_count] == 5)
  assert(unrelated.map(&:to_h) == snapshot)
  created = state[:calls].select { |kind, _details| kind == :bundle_create }.map(&:last)
  assert(created.map { |details| details[:identifier] }.sort == BeRealAppleID::TARGETS.sort)
  assert(created.all? { |details| details[:platform] == 'IOS' })
end
tests['ignored API filter reuses exact scoped registrations and profiles without any writes'] = lambda do
  worker, state, _output = fixture
  state[:bundle_filter_ignored] = true
  state[:bundles] << RESOURCE.new(id: 'UNRELATED', identifier: 'com.ayato.bereal493.extra', platform: 'IOS')
  BeRealAppleID::TARGETS.each_with_index do |identifier, index|
    state[:bundles] << RESOURCE.new(id: "SCOPED#{index}", identifier: identifier, platform: 'IOS')
    new_profile(state, identifier)
  end
  counts = worker.run(creds)
  assert(counts[:reused_bundle_count] == 5 && counts[:reused_profile_count] == 5)
  assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
end
tests['ignored API filter still rejects duplicate exact IOS registrations before any writes'] = lambda do
  worker, state, _output = fixture
  state[:bundle_filter_ignored] = true
  state[:bundles] << RESOURCE.new(id: 'UNRELATED', identifier: 'com.other.app', platform: 'IOS')
  2.times do |index|
    state[:bundles] << RESOURCE.new(id: "EXACT#{index}", identifier: BeRealAppleID::TARGETS.last, platform: 'IOS')
  end
  fails('ambiguous_bundle') { worker.run(creds) }
  assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
end
tests['exact wrong platform registration is rejected before writes even with wide results'] = lambda do
  [false, true].each do |also_ios|
    worker, state, _output = fixture
    state[:bundle_filter_ignored] = true
    state[:bundles] << RESOURCE.new(id: 'UNRELATED', identifier: 'com.ayato.bereal493.extra', platform: 'IOS')
    state[:bundles] << RESOURCE.new(id: 'WRONG', identifier: BeRealAppleID::TARGETS.last, platform: 'MAC_OS')
    if also_ios
      state[:bundles] << RESOURCE.new(id: 'EXACT', identifier: BeRealAppleID::TARGETS.last, platform: 'IOS')
    end
    fails('bundle_mismatch') { worker.run(creds) }
    assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
  end
end
tests['duplicate exact IOS and UNIVERSAL registrations halt before any writes'] = lambda do
  worker, state, _output = fixture
  state[:bundle_filter_ignored] = true
  %w[IOS UNIVERSAL].each_with_index do |platform, index|
    state[:bundles] << RESOURCE.new(id: "DUP#{index}", identifier: BeRealAppleID::TARGETS.last, platform: platform)
  end
  fails('ambiguous_bundle') { worker.run(creds) }
  assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
end
tests['unknown exact registration platforms halt before any writes'] = lambda do
  [nil, '', 'VISION_OS', 'ios'].each do |platform|
    worker, state, _output = fixture
    state[:bundles] << RESOURCE.new(id: 'WRONG', identifier: BeRealAppleID::TARGETS.last, platform: platform)
    fails('bundle_mismatch') { worker.run(creds) }
    assert(state[:calls].none? { |kind, _details| %i[bundle_create profile_create].include?(kind) })
  end
end
tests['created registration must retain exact identity and an IOS-capable platform before profile writes'] = lambda do
  [{ created_bundle_platform: 'MAC_OS' }, { created_bundle_platform: 'UNKNOWN' },
   { created_bundle_platform: 'UNIVERSAL', created_bundle_identifier: 'com.other.app' }].each do |change|
    worker, state, output = fixture
    state.merge!(change)
    fails('bundle_mismatch') { worker.run(creds) }
    assert(state[:calls].count { |kind, _details| kind == :bundle_create } == 1)
    assert(state[:calls].none? { |kind, _details| kind == :profile_create })
    assert(output.string.empty?)
  end
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
    assert(channel.stage == 'two_factor_verification')
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
  assert(channel.stage == 'awaiting_two_factor')
ensure
  [input_read, input_write].compact.each(&:close)
end
tests['authentication diagnostics expose only fixed stage and error kind'] = lambda do
  Object.const_set(:Spaceship, Module.new) unless Object.const_defined?(:Spaceship)
  {
    InvalidUserCredentialsError: 'invalid_user_credentials',
    UnauthorizedAccessError: 'unauthorized_access',
    NoUserCredentialsError: 'missing_user_credentials'
  }.each do |name, expected_kind|
    Spaceship.const_set(name, Class.new(StandardError)) unless Spaceship.const_defined?(name, false)
    error = Spaceship.const_get(name).new('private-account@example.invalid password=synthetic-secret otp=654321')
    output = StringIO.new
    channel = BeRealAppleID::Channel.new(output)
    channel.stage = 'session_validation'
    channel.failure(error)
    event = JSON.parse(output.string)
    assert(event.keys.sort == %w[error_kind event reason stage])
    assert(event == { 'event' => 'failure', 'reason' => 'authentication_failed',
                     'stage' => 'session_validation', 'error_kind' => expected_kind })
    assert(!output.string.include?('private-account') && !output.string.include?('synthetic-secret') &&
           !output.string.include?('654321') && !output.string.include?('Spaceship::'))
  end
end
tests['unapproved diagnostic stage and exception names are suppressed'] = lambda do
  output = StringIO.new
  channel = BeRealAppleID::Channel.new(output)
  supplied = 'login'.dup
  channel.stage = supplied
  supplied.replace('private-password')
  assert(channel.stage == 'login')
  channel.stage = 'private-account@example.invalid'
  assert(channel.stage == 'unknown')
  unknown_error = Class.new(StandardError).new('secret response body')
  channel.failure(unknown_error)
  event = JSON.parse(output.string)
  assert(event['stage'] == 'unknown' && event['error_kind'] == 'other')
  assert(!output.string.include?('secret') && !output.string.include?('private-account'))
end
tests['diagnostic stage allowlist stays within the worker protocol'] = lambda do
  expected = %w[login awaiting_two_factor two_factor_verification session_trust session_validation portal_session
                agreement_read certificate_read device_read bundle_read profile_read bundle_create profile_create
                profile_validation unknown]
  assert(BeRealAppleID::STAGES == expected)
  assert(BeRealAppleID::ERROR_KINDS == %w[invalid_user_credentials unauthorized_access missing_user_credentials other])
  channel = BeRealAppleID::Channel.new(StringIO.new)
  expected.each do |stage|
    channel.stage = stage
    assert(channel.stage == stage)
  end
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
    def send_shared_login_request(_user, _password) = :normal_login_return
    def store_session = :normal_trust_return
    def fetch_olympus_session_after_signin = fetch_olympus_session
    def fetch_olympus_session = :normal_session_return
    def handle_two_factor(_response, _depth = 0)
      @normal_factor_calls = (@normal_factor_calls || 0) + 1
      :normal_two_factor_return
    end
    def match_phone_to_masked_phone(_target, displayed) = displayed == '+81 •••• ••••33'
  end)
  Spaceship.const_set(:PortalClient, Class.new(Spaceship::Client) do
    def send_login_request(_user, _password) = :normal_portal_return
    def teams = []
  end)
  fake_channel = BeRealAppleID::Channel.new(StringIO.new)
  fake_channel.define_singleton_method(:two_factor_code) { '123456' }
  BeRealAppleID.install_private_hooks(fake_channel)
  client = Spaceship::Client.new
  assert(client.store_cookie.nil? && client.load_session_from_file == false && client.load_session_from_env == false)
  assert(client.cached_service_key.nil? && client.cache_service_key('synthetic-widget-key').nil?)
  assert(client.ask_for_2fa_code('private prompt') == '123456')
  assert(client.logger.is_a?(Logger))
  fails('unsupported_authentication') { client.handle_two_step(nil) }
  fails('unsupported_authentication') { client.choose_phone_number(['private number']) }
  assert(client.send_shared_login_request('private user', 'private password') == :normal_login_return)
  assert(fake_channel.stage == 'login')
  assert(client.store_session == :normal_trust_return && fake_channel.stage == 'session_trust')
  assert(client.fetch_olympus_session_after_signin == :normal_session_return && fake_channel.stage == 'session_validation')
  portal = Spaceship::PortalClient.new
  assert(portal.send_login_request('private user', 'private password') == :normal_portal_return)
  assert(fake_channel.stage == 'portal_session')
  assert(portal.teams == [] && fake_channel.stage == 'portal_session')
  ENV['SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER'] = '+819011112233'
  response = Struct.new(:body).new({ 'trustedPhoneNumbers' => [
    { 'id' => 1, 'numberWithDialCode' => '+81 •••• ••••33', 'pushMode' => 'sms' }
  ] })
  assert(client.handle_two_factor(response) == :normal_two_factor_return)
  assert(client.choose_phone_number(['+81 •••• ••••33']) == '+81 •••• ••••33')
  invalid = Struct.new(:body).new({ 'trustedPhoneNumbers' => [
    { 'id' => 2, 'numberWithDialCode' => '+81 •••• ••••44', 'pushMode' => 'sms' }
  ] })
  fails('unsupported_authentication') { client.handle_two_factor(invalid) }
  assert(client.instance_variable_get(:@normal_factor_calls) == 1)
ensure
  ENV.delete('SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER')
end

tests.each do |name, test|
  test.call
  puts "PASS #{name}"
end
puts "#{tests.length} offline tests passed; no Apple login or resource changes"
