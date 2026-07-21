require 'rspec'
require 'json'
require 'open3'
require 'yaml'
require 'bosh/template/test'

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


      context 'when trusted CAs are provided' do
        it 'should import all provided CAs to the trust store' do
          concatenated_cas = '-----BEGIN CERTIFICATE-----
someCertBody1
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
someCertBody2
-----END CERTIFICATE-----
'
          another_ca = '-----BEGIN CERTIFICATE-----
someCertBody3
-----END CERTIFICATE-----
'
          manifest['credhub']['authentication']['mutual_tls']['trusted_cas'] = [concatenated_cas, another_ca]

          script = template.render(manifest)

          expect(script).to include('cat > ${MTLS_CA_CERT_FILE} <<EOL
-----BEGIN CERTIFICATE-----
someCertBody1
-----END CERTIFICATE-----
EOL')

          expect(script).to include('cat > ${MTLS_CA_CERT_FILE} <<EOL
-----BEGIN CERTIFICATE-----
someCertBody2
-----END CERTIFICATE-----
EOL')

          expect(script).to include('cat > ${MTLS_CA_CERT_FILE} <<EOL
-----BEGIN CERTIFICATE-----
someCertBody3
-----END CERTIFICATE-----
EOL')

          expect(script).to include('${JAVA_HOME}/bin/keytool -import -noprompt -trustcacerts   -keystore ${MTLS_TRUST_STORE_PATH}   -storepass ${MTLS_TRUST_STORE_PASSWORD}   -alias ${MTLS_CA_ALIAS}-0-0   -file ${MTLS_CA_CERT_FILE}')
          expect(script).to include('${JAVA_HOME}/bin/keytool -import -noprompt -trustcacerts   -keystore ${MTLS_TRUST_STORE_PATH}   -storepass ${MTLS_TRUST_STORE_PASSWORD}   -alias ${MTLS_CA_ALIAS}-0-1   -file ${MTLS_CA_CERT_FILE}')
          expect(script).to include('${JAVA_HOME}/bin/keytool -import -noprompt -trustcacerts   -keystore ${MTLS_TRUST_STORE_PATH}   -storepass ${MTLS_TRUST_STORE_PASSWORD}   -alias ${MTLS_CA_ALIAS}-1-0   -file ${MTLS_CA_CERT_FILE}')
        end
      end
    end
  end
end
