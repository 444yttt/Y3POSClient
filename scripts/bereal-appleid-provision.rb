#!/usr/bin/env ruby
# frozen_string_literal: true

# One-shot Apple ID provisioning worker. Credentials and Apple sessions never
# leave this process; only the fixed control events below go to the controller.
# Ruby 3.3 and fastlane 2.241.0 are pinned by the authorized macOS workflow.
require 'json'
require 'openssl'
require 'base64'
require 'digest'
require 'time'
require 'securerandom'
require 'logger'

module BeRealAppleID
  TARGETS = %w[
    com.ayato.bereal493
    com.ayato.bereal493.iMessageExtension
    com.ayato.bereal493.RealMojiNotificationContentExtension
    com.ayato.bereal493.NotificationServiceExtension
    com.ayato.bereal493.Widgets
  ].freeze
  FAILURE_REASONS = %w[
    invalid_private_input invalid_context invalid_credentials control_unavailable
    two_factor_attempt_limit two_factor_timeout two_factor_input_rejected
    agreement_status_unavailable team_mismatch certificate_mismatch
    device_count_mismatch ambiguous_bundle bundle_mismatch profile_verification_failed
    authentication_failed permission_denied apple_service_unavailable
    provisioning_failed unsupported_authentication interrupted worker_setup_failed
  ].freeze
  STAGES = %w[
    login awaiting_two_factor two_factor_verification session_trust
    session_validation portal_session agreement_read certificate_read device_read
    bundle_read profile_read bundle_create profile_create profile_validation unknown
  ].freeze
  ERROR_KINDS = %w[invalid_user_credentials unauthorized_access missing_user_credentials other].freeze
  AUTH_ERROR_CLASSES = {
    'Spaceship::InvalidUserCredentialsError' => 'invalid_user_credentials',
    'Spaceship::Client::InvalidUserCredentialsError' => 'invalid_user_credentials',
    'Spaceship::UnauthorizedAccessError' => 'unauthorized_access',
    'Spaceship::Client::UnauthorizedAccessError' => 'unauthorized_access',
    'Spaceship::NoUserCredentialsError' => 'missing_user_credentials',
    'Spaceship::Client::NoUserCredentialsError' => 'missing_user_credentials'
  }.freeze

  class Failure < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = FAILURE_REASONS.include?(reason) ? reason : 'provisioning_failed'
      super(@reason)
    end
  end

  class AgreementRequired < StandardError; end
  class ProfileRejected < StandardError; end

  class Channel
    def initialize(output, input: STDIN, timeout: 600)
      @output, @input, @timeout, @attempt = output, input, timeout, 0
      @stage, @state_lock = 'unknown', Mutex.new
    end

    def stage=(value)
      @state_lock.synchronize { @stage = STAGES.find { |approved| approved == value } || 'unknown' }
    end

    def stage
      @state_lock.synchronize { @stage }
    end

    def failure(error)
      emit('failure', reason: BeRealAppleID.failure_reason(error), stage: stage,
                      error_kind: BeRealAppleID.error_kind(error))
    end

    def emit(event, fields = {})
      @output.write(JSON.generate({ event: event }.merge(fields)) + "\n")
      @output.flush
    rescue IOError, SystemCallError
      raise Failure, 'control_unavailable'
    end

    # Fastlane calls this hook from its ordinary trusted-device/SMS 2FA flow.
    # Each request has a fresh nonce and remains subject to Apple's verification.
    def two_factor_code
      @attempt += 1
      raise Failure, 'two_factor_attempt_limit' if @attempt > 3
      nonce = SecureRandom.hex(32)
      self.stage = 'awaiting_two_factor'
      emit('two_factor_required', attempt: @attempt, challenge_nonce: nonce)
      raise Failure, 'two_factor_timeout' unless IO.select([@input], nil, nil, @timeout)
      line = @input.gets(1025)
      raise Failure, 'two_factor_input_rejected' unless line && line.bytesize <= 1024 && line.end_with?("\n")
      value = JSON.parse(line)
      unless value.is_a?(Hash) && value.keys.sort == %w[challenge_nonce code] &&
             value['challenge_nonce'] == nonce && value['code'].is_a?(String) &&
             /\A[0-9]{6}\z/.match?(value['code'])
        raise Failure, 'two_factor_input_rejected'
      end
      self.stage = 'two_factor_verification'
      value['code']
    rescue JSON::ParserError
      raise Failure, 'two_factor_input_rejected'
    ensure
      line&.clear
    end
  end

  def self.read_private_json(path, delete_after_read: false)
    text = nil
    begin
      stat = File.lstat(path)
      unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 16_384
        raise Failure, 'invalid_private_input'
      end
      File.open(path, File::RDONLY | File::NOFOLLOW) do |input|
        actual = input.stat
        raise Failure, 'invalid_private_input' unless actual.ino == stat.ino && actual.dev == stat.dev
        text = input.read(16_385)
      end
      raise Failure, 'invalid_private_input' if text.bytesize > 16_384
      # Delete the source immediately after loading, before parsing or login.
      File.unlink(path) if delete_after_read
      JSON.parse(text)
    rescue JSON::ParserError, SystemCallError, IOError, TypeError
      raise Failure, 'invalid_private_input'
    ensure
      text&.clear
      File.unlink(path) if delete_after_read && path && File.file?(path) && !File.symlink?(path)
    end
  end

  def self.validate_credentials(value)
    unless value.is_a?(Hash) && value.keys.sort == %w[apple_id password] &&
           value['apple_id'].is_a?(String) && value['password'].is_a?(String) &&
           value['apple_id'].bytesize.between?(3, 320) && value['password'].bytesize.between?(1, 4096) &&
           !/[\x00-\x1f\x7f]/.match?(value['apple_id']) && !value['password'].include?("\0")
      raise Failure, 'invalid_credentials'
    end
    value
  end

  def self.validate_context(value)
    expected = %w[certificate_sha256 expected_enabled_device_count target_bundle_identifiers team_id]
    allowed = expected + ['sms_phone_number']
    unless value.is_a?(Hash) && (value.keys - allowed).empty? && (expected - value.keys).empty? &&
           value['team_id'].is_a?(String) && /\A[A-Z0-9]{10}\z/.match?(value['team_id']) &&
           value['certificate_sha256'].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value['certificate_sha256']) &&
           value['expected_enabled_device_count'] == 1 && value['target_bundle_identifiers'].is_a?(Array) &&
           value['target_bundle_identifiers'].sort == TARGETS.sort &&
           (!value.key?('sms_phone_number') || valid_sms_phone?(value['sms_phone_number']))
      raise Failure, 'invalid_context'
    end
    value
  end

  def self.valid_sms_phone?(value)
    value.is_a?(String) && /\A\+[1-9][0-9]{7,14}\z/.match?(value)
  end

  def self.masked_sms_match?(target, displayed)
    return false unless valid_sms_phone?(target) && displayed.is_a?(String) && displayed.bytesize <= 128
    clean = displayed.gsub(/[ \u00a0\-()"]/, '')
    return clean == target if valid_sms_phone?(clean)
    # Apple's normal Fastlane matcher supports a country prefix, bullet mask,
    # and the last two visible digits; Apple sometimes reports two extra dots.
    match = /\A(\+[1-9][0-9]{0,2})(•{2,})([0-9]{2})\z/.match(clean)
    return false unless match && target.start_with?(match[1]) && target.end_with?(match[3])
    hidden_count = target.length - match[1].length - match[3].length
    hidden_count.between?(match[2].length - 2, match[2].length)
  end

  def self.select_sms_option(options, target)
    raise Failure, 'unsupported_authentication' unless options.is_a?(Array) && valid_sms_phone?(target)
    matches = options.select { |displayed| masked_sms_match?(target, displayed) }
    raise Failure, 'unsupported_authentication' unless matches.length == 1
    matches.first
  end

  def self.select_trusted_sms_entry(body, target)
    entries = body.is_a?(Hash) ? body['trustedPhoneNumbers'] : nil
    unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
      raise Failure, 'unsupported_authentication'
    end
    displayed = select_sms_option(entries.map { |entry| entry['numberWithDialCode'] }, target)
    entry = entries.find { |item| item['numberWithDialCode'] == displayed }
    # Only select an existing Apple-trusted, SMS-capable entry. No number is
    # registered, changed, or added and no alternative device is selected.
    unless entry && entry['id'] && entry['pushMode'] == 'sms'
      raise Failure, 'unsupported_authentication'
    end
    entry
  end

  # Disable persistent authentication and request logging before the first
  # Spaceship client exists. Explicit username/password avoid Keychain writes.
  def self.install_private_hooks(channel)
    hooks = Module.new do
      define_method(:logger) { @bereal_null_logger ||= Logger.new(File::NULL) }
      define_method(:load_session_from_file) { false }
      define_method(:load_session_from_env) { false }
      define_method(:store_cookie) { |**_options| nil }
      define_method(:cached_service_key) { nil }
      define_method(:cache_service_key) { |_key| nil }
      define_method(:ask_for_2fa_code) { |_prompt| channel.two_factor_code }
      # Use Fastlane's supported SMS-default environment option. Validate a
      # unique trusted match before its ordinary SMS request is allowed.
      define_method(:handle_two_factor) do |response, depth = 0|
        target = ENV['SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER']
        if target
          entry = BeRealAppleID.select_trusted_sms_entry(response.body, target)
          native_matches = response.body['trustedPhoneNumbers'].select do |candidate|
            match_phone_to_masked_phone(target, candidate['numberWithDialCode'])
          end
          unless native_matches.length == 1 && native_matches.first.equal?(entry)
            raise Failure, 'unsupported_authentication'
          end
        end
        super(response, depth)
      end
      # Legacy four-digit 2SV requires a separate explicit user flow.
      define_method(:handle_two_step) { |_response| raise Failure, 'unsupported_authentication' }
      define_method(:choose_phone_number) do |options|
        BeRealAppleID.select_sms_option(options, ENV['SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER'])
      end
    end
    Spaceship::Client.prepend(hooks)
    # These are existing methods in fastlane 2.241.0. Instrumentation only
    # records their fixed phase; arguments, return values, and exceptions pass
    # through unchanged to preserve the ordinary Apple authentication flow.
    auth_stages = {
      send_shared_login_request: 'login', store_session: 'session_trust',
      fetch_olympus_session_after_signin: 'session_validation',
      fetch_olympus_session: 'session_validation'
    }
    diagnostics = Module.new
    auth_stages.each do |method, stage|
      next unless Spaceship::Client.method_defined?(method) || Spaceship::Client.private_method_defined?(method)
      diagnostics.define_method(method) do |*args, **kwargs, &block|
        channel.stage = stage
        super(*args, **kwargs, &block)
      end
    end
    Spaceship::Client.prepend(diagnostics)
    if defined?(Spaceship::PortalClient)
      portal_diagnostics = Module.new
      %i[send_login_request teams].each do |method|
        next unless Spaceship::PortalClient.method_defined?(method) || Spaceship::PortalClient.private_method_defined?(method)
        portal_diagnostics.define_method(method) do |*args, **kwargs, &block|
          channel.stage = 'portal_session'
          super(*args, **kwargs, &block)
        end
      end
      Spaceship::PortalClient.prepend(portal_diagnostics)
    end
  end

  def self.decode_profile(content)
    require 'cfpropertylist'
    raise ProfileRejected unless content.is_a?(String) && content.bytesize.between?(1, 14_000_000)
    raw = Base64.strict_decode64(content.delete("\r\n"))
    cms = OpenSSL::PKCS7.new(raw)
    raise ProfileRejected unless cms.verify([], OpenSSL::X509::Store.new, nil, OpenSSL::PKCS7::NOVERIFY)
    plist = CFPropertyList::List.new(data: cms.data)
    value = CFPropertyList.native_types(plist.value)
    raise ProfileRejected unless value.is_a?(Hash)
    value
  rescue StandardError
    # Invalid local CMS/plist data is a rejected candidate, never raw logging.
    raise ProfileRejected
  end

  class Worker
    def initialize(context, channel, api: Spaceship::ConnectAPI, profile_decoder: BeRealAppleID.method(:decode_profile))
      @context = BeRealAppleID.validate_context(context)
      @channel, @api, @decode = channel, api, profile_decoder
      @team, @fingerprint = context.values_at('team_id', 'certificate_sha256')
    end

    def check_agreements(portal)
      @channel.stage = 'agreement_read'
      response = portal.list_pending_agreements(language: 'en')
      if response.is_a?(Array)
        raise AgreementRequired unless response.empty?
        return true
      end
      return false unless response.is_a?(Hash)
      keys = %w[pendingAgreements agreements].select { |key| response.key?(key) }
      return false if keys.empty?
      keys.each do |key|
        return false unless response[key].is_a?(Array)
        raise AgreementRequired unless response[key].empty?
      end
      if response.key?('resultCode') && response['resultCode'].to_s != '0'
        return false
      end
      true
    rescue AgreementRequired
      raise
    rescue StandardError => error
      raise if error.class.name.to_s.include?('ProgramLicenseAgreementUpdated')
      # An optional read/schema failure does not establish a legal blocker.
      # Apple's normal authenticated creation API still enforces agreements;
      # this worker never calls an agreement-acceptance endpoint.
      false
    end

    def certificate(client)
      @channel.stage = 'certificate_read'
      matches = @api::Certificate.all(client: client).filter_map do |resource|
        next unless %w[DISTRIBUTION IOS_DISTRIBUTION].include?(resource.certificate_type)
        next unless resource.certificate_content.is_a?(String)
        begin
          der = Base64.strict_decode64(resource.certificate_content.delete("\r\n"))
          next unless Digest::SHA256.hexdigest(der) == @fingerprint
          cert = OpenSSL::X509::Certificate.new(der)
          units = cert.subject.to_a.select { |name, _value, _type| name == 'OU' }.map { |_name, value, _type| value }
          names = cert.subject.to_a.select { |name, _value, _type| name == 'CN' }.map { |_name, value, _type| value }
          now = Time.now.utc
          next unless units == [@team] && names.length == 1 && /\A(?:Apple|iPhone) Distribution:/.match?(names.first)
          next unless cert.not_before <= now && cert.not_after > now && Time.parse(resource.expiration_date) > now
          [resource, der]
        rescue OpenSSL::OpenSSLError, ArgumentError, TypeError
          next
        end
      end
      raise Failure, 'certificate_mismatch' unless matches.length == 1
      matches.first
    end

    def device(client)
      @channel.stage = 'device_read'
      devices = @api::Device.all(client: client, filter: { platform: 'IOS', status: 'ENABLED' })
      enabled = devices.select { |item| item.platform == 'IOS' && item.status == 'ENABLED' }
      raise Failure, 'device_count_mismatch' unless enabled.length == 1
      selected = enabled.first
      unless %w[IPHONE IPAD IPOD].include?(selected.device_class) &&
             selected.udid.is_a?(String) && !selected.udid.empty?
        raise Failure, 'device_count_mismatch'
      end
      selected
    end

    def valid_profile?(profile, identifier, der, selected_device)
      @channel.stage = 'profile_validation'
      return false unless profile.profile_type == 'IOS_APP_ADHOC' && profile.profile_state == 'ACTIVE' &&
                          Time.parse(profile.expiration_date) > Time.now.utc
      decoded = @decode.call(profile.profile_content)
      entitlements = decoded['Entitlements']
      raise ProfileRejected unless entitlements.is_a?(Hash)
      app_id = entitlements['application-identifier']
      raise ProfileRejected unless app_id.is_a?(String)
      prefix, grant = app_id.split('.', 2)
      raise ProfileRejected unless grant == identifier && Array(decoded['ApplicationIdentifierPrefix']).include?(prefix)
      raise ProfileRejected unless Array(decoded['TeamIdentifier']).include?(@team) &&
                                   entitlements['com.apple.developer.team-identifier'] == @team &&
                                   entitlements['get-task-allow'] == false && decoded['ProvisionsAllDevices'] != true
      raise ProfileRejected unless decoded['ProvisionedDevices'] == [selected_device.udid] &&
                                   Array(decoded['DeveloperCertificates']).include?(der)
      expiry = decoded['ExpirationDate']
      expiry = Time.parse(expiry) if expiry.is_a?(String)
      raise ProfileRejected unless expiry.respond_to?(:to_time) && expiry.to_time > Time.now.utc
      uuid = decoded['UUID']
      raise ProfileRejected unless uuid.is_a?(String) && /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i.match?(uuid) &&
                                   profile.uuid.is_a?(String) && profile.uuid.casecmp?(uuid)
      true
    rescue ProfileRejected, ArgumentError, TypeError
      false
    end

    def full_profile(client, profile)
      return profile if profile.profile_content.is_a?(String) && !profile.profile_content.empty?
      @channel.stage = 'profile_read'
      unless profile.id.is_a?(String) && /\A[A-Za-z0-9-]{1,128}\z/.match?(profile.id)
        raise Failure, 'profile_verification_failed'
      end
      # This is Fastlane's normal, authenticated provisioning client, whose
      # session implementation adds the selected team and CSRF headers.
      client.provisioning_request_client.get("v1/profiles/#{profile.id}").to_models.first ||
        (raise Failure, 'profile_verification_failed')
    end

    def run(credentials)
      credentials = BeRealAppleID.validate_credentials(credentials)
      if @context.key?('sms_phone_number')
        ENV['SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER'] = @context['sms_phone_number']
      else
        ENV.delete('SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER')
      end
      @channel.stage = 'login'
      client = @api::Client.login(credentials['apple_id'], credentials['password'],
                                  use_portal: true, use_tunes: false, portal_team_id: @team)
      raise Failure, 'team_mismatch' unless client.portal_team_id == @team
      agreement_status_known = check_agreements(client.portal_client)
      resource, der = certificate(client)
      selected_device = device(client)
      # Finish every read-only preflight before creating any Apple resource.
      bundles = TARGETS.to_h do |identifier|
        @channel.stage = 'bundle_read'
        # The web-session API can return prefix/wide results for its filter;
        # Fastlane's own BundleId.find also performs an exact local comparison.
        # Check only this identifier, and do not create a duplicate when its
        # exact registration is present on an unexpected platform.
        matches = @api::BundleId.all(client: client, filter: { identifier: identifier, platform: 'IOS' })
                               .select { |bundle| bundle.identifier == identifier }
        raise Failure, 'bundle_mismatch' if matches.any? { |bundle| bundle.platform != 'IOS' }
        raise Failure, 'ambiguous_bundle' if matches.length > 1
        existing = matches.first
        [identifier, existing]
      end
      @channel.stage = 'profile_read'
      profiles = @api::Profile.all(client: client, filter: { profileType: 'IOS_APP_ADHOC' })
      profiles = profiles.map { |profile| full_profile(client, profile) }
      existing_profiles = TARGETS.to_h do |identifier|
        compatible = profiles.select { |profile| valid_profile?(profile, identifier, der, selected_device) }
        [identifier, compatible.first]
      end
      counts = { created_bundle_count: 0, reused_bundle_count: 0, created_profile_count: 0, reused_profile_count: 0,
                 registered_device_count: 1, provisioned_bundle_count: 5,
                 agreement_status_known: agreement_status_known }
      TARGETS.each do |identifier|
        bundle = bundles[identifier]
        if bundle
          counts[:reused_bundle_count] += 1
        else
          @channel.stage = 'bundle_create'
          bundle = @api::BundleId.create(client: client, name: "BeReal493 #{identifier.split('.').last}",
                                         platform: 'IOS', identifier: identifier)
          counts[:created_bundle_count] += 1
        end
        unless bundle && bundle.identifier == identifier && bundle.platform == 'IOS'
          raise Failure, 'bundle_mismatch'
        end
        if existing_profiles[identifier]
          counts[:reused_profile_count] += 1
        else
          @channel.stage = 'profile_create'
          created = @api::Profile.create(client: client, name: "BeReal493-AdHoc-#{identifier.split('.').last}",
                                         profile_type: 'IOS_APP_ADHOC', bundle_id_id: bundle.id,
                                         certificate_ids: [resource.id], device_ids: [selected_device.id])
          created = full_profile(client, created)
          unless valid_profile?(created, identifier, der, selected_device)
            raise Failure, 'profile_verification_failed'
          end
          counts[:created_profile_count] += 1
        end
      end
      @channel.emit('provisioning_complete', counts)
      counts
    ensure
      ENV.delete('SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER')
      credentials.each_value { |value| value.clear if value.is_a?(String) } if credentials.is_a?(Hash)
      client&.portal_client&.instance_variable_set(:@password, nil)
    end
  end

  def self.failure_reason(error)
    return error.reason if error.is_a?(Failure)
    name = error.class.name.to_s
    return 'authentication_failed' if /InvalidUserCredentials|UnauthorizedAccess|NoUserCredentials/.match?(name)
    return 'permission_denied' if /AccessForbidden|InsufficientPermissions|Forbidden/.match?(name)
    return 'apple_service_unavailable' if /Timeout|ConnectionFailed|TooManyRequests|Gateway|InternalServer/.match?(name)
    'provisioning_failed'
  end

  def self.error_kind(error)
    AUTH_ERROR_CLASSES.fetch(error.class.name.to_s, 'other')
  end

  def self.main(argv)
    channel = nil
    credentials = nil
    begin
      fd = Integer(ENV.fetch('BEREAL_CONTROL_FD', '3'))
      raise Failure, 'control_unavailable' unless fd.between?(3, 256)
      channel = Channel.new(IO.for_fd(fd, 'w', autoclose: false))
      STDOUT.reopen(File::NULL, 'w')
      STDERR.reopen(File::NULL, 'w')
      $stdout, $stderr = STDOUT, STDERR
      File.umask(0o077)
      raise Failure, 'worker_setup_failed' unless argv.length == 2 &&
        ENV['GITHUB_REPOSITORY'] == '444yttt/Y3POSClient' && ENV['GITHUB_REF'] == 'refs/heads/main'
      credentials = read_private_json(argv[0], delete_after_read: true)
      context = validate_context(read_private_json(argv[1]))
      validate_credentials(credentials)
      %w[FASTLANE_SESSION SPACESHIP_SESSION SPACESHIP_DEBUG SPACESHIP_PROXY
         SPACESHIP_PROXY_SSL_VERIFY_NONE SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER
         SPACESHIP_ONLY_ALLOW_INTERACTIVE_2FA VERBOSE DEBUG].each { |key| ENV.delete(key) }
      ENV['FASTLANE_OPT_OUT_USAGE'] = '1'
      ENV['FASTLANE_SKIP_UPDATE_CHECK'] = '1'
      gem 'fastlane', '= 2.241.0'
      require 'spaceship'
      install_private_hooks(channel)
      %w[TERM INT].each { |signal| Signal.trap(signal) { raise Failure, 'interrupted' } }
      Worker.new(context, channel).run(credentials)
      0
    rescue StandardError, LoadError => error
      if error.is_a?(AgreementRequired) || error.class.name.to_s.include?('ProgramLicenseAgreementUpdated')
        channel&.emit('agreement_review_required')
      else
        channel&.failure(error)
      end
      1
    ensure
      credentials.each_value { |value| value.clear if value.is_a?(String) } if credentials.is_a?(Hash)
    end
  end
end

exit(BeRealAppleID.main(ARGV)) if $PROGRAM_NAME == __FILE__
