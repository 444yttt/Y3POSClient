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
    unless value.is_a?(Hash) && value.keys.sort == expected &&
           value['team_id'].is_a?(String) && /\A[A-Z0-9]{10}\z/.match?(value['team_id']) &&
           value['certificate_sha256'].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value['certificate_sha256']) &&
           value['expected_enabled_device_count'] == 1 && value['target_bundle_identifiers'].is_a?(Array) &&
           value['target_bundle_identifiers'].sort == TARGETS.sort
      raise Failure, 'invalid_context'
    end
    value
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
      # Legacy four-digit 2SV and selection prompts require a separate explicit
      # user flow; this worker never invents or chooses a trusted device.
      define_method(:handle_two_step) { |_response| raise Failure, 'unsupported_authentication' }
      define_method(:choose_phone_number) { |_options| raise Failure, 'unsupported_authentication' }
    end
    Spaceship::Client.prepend(hooks)
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
      client = @api::Client.login(credentials['apple_id'], credentials['password'],
                                  use_portal: true, use_tunes: false, portal_team_id: @team)
      raise Failure, 'team_mismatch' unless client.portal_team_id == @team
      agreement_status_known = check_agreements(client.portal_client)
      resource, der = certificate(client)
      selected_device = device(client)
      # Finish every read-only preflight before creating any Apple resource.
      bundles = TARGETS.to_h do |identifier|
        matches = @api::BundleId.all(client: client, filter: { identifier: identifier, platform: 'IOS' })
        raise Failure, 'ambiguous_bundle' if matches.length > 1
        existing = matches.first
        if existing && (existing.identifier != identifier || existing.platform != 'IOS')
          raise Failure, 'bundle_mismatch'
        end
        [identifier, existing]
      end
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
        channel&.emit('failure', reason: failure_reason(error))
      end
      1
    ensure
      credentials.each_value { |value| value.clear if value.is_a?(String) } if credentials.is_a?(Hash)
    end
  end
end

exit(BeRealAppleID.main(ARGV)) if $PROGRAM_NAME == __FILE__
