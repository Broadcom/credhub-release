require 'rspec'
require 'json'
require 'open3'
require 'yaml'
require 'bosh/template/test'
require 'tmpdir'
require 'fileutils'
require 'openssl'
require 'etc'
require 'shellwords'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/init_key_stores template' do
    let(:template) { job.template('bin/init_key_stores.sh') }

    context 'when a TLS certificate is provided' do
      let(:manifest) do
        {
          'credhub' => {
            'tls' => {
              'certificate' => 'my-tls-certificate',
              'private_key' => 'my-tls-private-key'
            },
            'authentication' => {
              'uaa' => {
                'ca_certs' => [
                  'my_first_uaa_cert'
                ]
              },
              'mutual_tls' => {
                'trusted_cas' => []
              }
            }
          }
        }
      end

      describe 'generate_password' do
        # Runs the rendered function for real: it must survive `set -euo pipefail`
        # under a UTF-8 locale, where `tr` would otherwise reject the invalid
        # multibyte sequences coming out of /dev/urandom.
        it 'prints a 32 character alphanumeric password without erroring' do
          script = template.render(manifest)
          function = script[/^function generate_password\(\) \{.*?^\}$/m]
          expect(function).not_to be_nil

          stdout, stderr, status = Open3.capture3(
            { 'LC_ALL' => 'C.UTF-8' },
            'bash', '-c', "set -euo pipefail\n#{function}\ngenerate_password"
          )

          expect(stderr).to be_empty
          expect(status.exitstatus).to eq(0)
          expect(stdout).to match(/\A[A-Za-z0-9]{32}\z/)
        end
      end
    end

    context 'when executing pre-start' do
      let(:key) { OpenSSL::PKey::RSA.new(2048) }
      let(:ca_key) { OpenSSL::PKey::RSA.new(2048) }
      let(:ca) { certificate(ca_key, 1) }
      let(:leaf) { certificate(key, 2, ca, ca_key) }
      let(:chain) { leaf.to_pem + ca.to_pem }
      let(:runtime_uid) { Process.uid.zero? ? Etc.getpwnam('nobody').uid : Process.uid }
      let(:manifest) do
        { 'credhub' => {
          'tls' => { 'certificate' => chain, 'private_key' => key.to_pem },
          'authentication' => { 'uaa' => { 'enabled' => false }, 'mutual_tls' => { 'trusted_cas' => [] } }
        } }
      end

      around do |example|
        Dir.mktmpdir('credhub-init-') do |directory|
          @directory = directory
          @config = File.join(directory, 'jobs/credhub/config')
          @tmp = File.join(directory, 'jobs/credhub/tmp')
          FileUtils.chmod(0755, directory)
          FileUtils.mkdir_p([@config, @tmp])
          File.write(File.join(@config, 'database_ca.pem'), '')
          example.run
        end
      end

      def certificate(public_key, serial, issuer = nil, signing_key = public_key)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = serial
        cert.subject = OpenSSL::X509::Name.parse("/CN=init-test-#{serial}")
        cert.issuer = issuer ? issuer.subject : cert.subject
        cert.public_key = public_key.public_key
        cert.not_before = Time.utc(2020)
        cert.not_after = Time.utc(2040)
        cert.sign(signing_key, OpenSSL::Digest::SHA256.new)
        cert
      end

      def execute(*command, **options)
        stdout, stderr, status = Open3.capture3(*command, **options)
        expect(status.exitstatus).to eq(0), "#{command.first} failed: #{stderr}"
        stdout
      end

      def initialization_script
        keytool = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
          .map { |directory| File.join(directory, 'keytool') }.find { |path| File.executable?(path) }
        raise 'A JDK/JRE with keytool on PATH is required' unless keytool

        java_home = File.dirname(File.dirname(File.realpath(keytool)))
        # Relocate BOSH paths and map vcap to a real local UID; execute all crypto
        # and filesystem operations. Under root the target UID is unprivileged,
        # so removing a chown is observable rather than masked by the test user.
        template.render(manifest)
          .gsub('/var/vcap/packages/openjdk_25.0/jre', java_home)
          .gsub('/var/vcap', @directory)
          .gsub('chown vcap ', "chown #{runtime_uid} ")
      end

      def initialize_key_stores
        execute('bash', '-c', initialization_script)
      end

      it 'rejects a private key that does not match the leaf before normalization' do
        manifest['credhub']['tls']['private_key'] = ca_key.to_pem

        _stdout, stderr, status = Open3.capture3('bash', '-c', initialization_script)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('must be the leaf certificate for credhub.tls.private_key')
        expect(File.read(File.join(@config, 'priv.key')).strip).to eq(ca_key.to_pem.strip)
        expect(File.exist?(File.join(@tmp, 'credhub-key.pk8.pem'))).to be(false)
      end

      it 'rejects a CA-first bundle even when it contains the matching leaf' do
        manifest['credhub']['tls']['certificate'] = ca.to_pem + leaf.to_pem

        _stdout, stderr, status = Open3.capture3('bash', '-c', initialization_script)

        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('must be the leaf certificate for credhub.tls.private_key')
        expect(File.exist?(File.join(@tmp, 'credhub-key.pk8.pem'))).to be(false)
      end

      it 'fails during pre-start when the certificate cannot be parsed' do
        manifest['credhub']['tls']['certificate'] = 'not a certificate'

        _stdout, _stderr, status = Open3.capture3('bash', '-c', initialization_script)

        expect(status.success?).to be(false)
        expect(File.exist?(File.join(@tmp, 'credhub-key.pk8.pem'))).to be(false)
      end

      def passwords
        File.read(File.join(@tmp, 'var-store')).scan(/^export (\w+)=(\w+)$/).to_h
      end

      def expect_private_file(path)
        expect(File.stat(path).mode & 0777).to eq(0600)
        expect(File.stat(path).uid).to eq(runtime_uid)
      end

      it 'normalizes the key and retains its certificate chain without any truststores' do
        File.write(File.join(@config, 'cacerts.jks'), 'old identity keystore')
        File.write(File.join(@tmp, 'var-store'), "export KEY_STORE_PASSWORD=old\n")
        File.chmod(0644, File.join(@tmp, 'var-store'))

        initialize_key_stores

        pem = File.read(File.join(@config, 'priv.key'))
        expect(pem).to start_with("-----BEGIN PRIVATE KEY-----\n")
        expect(OpenSSL::PKey.read(pem).public_to_der).to eq(key.public_to_der)
        expect(File.read(File.join(@config, 'cert.crt')).strip).to eq(chain.strip)
        expect(Dir.glob(File.join(@config, '*.jks'))).to be_empty
        expect(passwords.keys).to contain_exactly('MTLS_TRUST_STORE_PASSWORD', 'TRUST_STORE_PASSWORD')
        [File.join(@config, 'cert.crt'), File.join(@config, 'priv.key'), File.join(@tmp, 'var-store')].each do |path|
          expect_private_file(path)
        end
      end

      it 'imports every mTLS CA and protects populated truststores across repeated pre-starts' do
        another_ca = certificate(ca_key, 3)
        manifest['credhub']['authentication']['mutual_tls']['trusted_cas'] = [ca.to_pem + another_ca.to_pem, leaf.to_pem]
        manifest['credhub']['authentication']['uaa'] = { 'enabled' => true, 'ca_certs' => [ca.to_pem] }
        File.write(File.join(@config, 'database_ca.pem'), another_ca.to_pem)

        2.times do
          initialize_key_stores
          entries = [
            ['mtls_trust_store', 'MTLS_TRUST_STORE_PASSWORD', 'mtls_ca-0-0', ca],
            ['mtls_trust_store', 'MTLS_TRUST_STORE_PASSWORD', 'mtls_ca-0-1', another_ca],
            ['mtls_trust_store', 'MTLS_TRUST_STORE_PASSWORD', 'mtls_ca-1-0', leaf],
            ['trust_store', 'TRUST_STORE_PASSWORD', 'auth_server_ca0_0', ca],
            ['trust_store', 'TRUST_STORE_PASSWORD', 'database_verify_ca1', another_ca]
          ]
          entries.each do |store, password, alias_name, expected_cert|
            path = File.join(@config, "#{store}.jks")
            exported = execute('keytool', '-exportcert', '-rfc', '-keystore', path,
              '-storepass', passwords.fetch(password), '-alias', alias_name)
            expect(OpenSSL::X509::Certificate.new(exported).to_der).to eq(expected_cert.to_der)
            expect_private_file(path)
          end
        end
      end

      it 'lets the unprivileged launcher source passwords and read its private key', :privileged do
        skip 'Run as root to exercise the pre-start to runtime UID transition' unless Process.uid.zero?

        initialize_key_stores
        var_store = Shellwords.escape(File.join(@tmp, 'var-store'))
        private_key = Shellwords.escape(File.join(@config, 'priv.key'))
        output = execute('bash', '-c', "set -euo pipefail; source #{var_store}; " \
          "openssl pkey -in #{private_key} -pubout; printf '%s' \"$TRUST_STORE_PASSWORD\"", uid: runtime_uid)
        expect(output).to eq(key.public_to_pem + passwords.fetch('TRUST_STORE_PASSWORD'))
      end
    end
  end
end
