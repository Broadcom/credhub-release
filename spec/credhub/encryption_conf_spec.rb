require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'config/encryption.conf template' do
    let(:template) { job.template('config/encryption.conf') }

    let(:hsm_manifest) do
      {
        'credhub' => {
          'encryption' => {
            'providers' => [
              {
                'name' => 'primary',
                'type' => 'hsm',
                'connection_properties' => {
                  'partition' => 'some-partition',
                  'partition_password' => 'some-partition-password',
                  'client_certificate' => 'CLIENT-CERT',
                  'client_key' => 'CLIENT-KEY',
                  'servers' => [
                    {
                      'host' => '10.0.0.1',
                      'port' => 1792,
                      'certificate' => 'HSM-CERT-1',
                      'partition_serial_number' => '111111'
                    },
                    {
                      'host' => '10.0.0.10',
                      'certificate' => 'HSM-CERT-2',
                      'partition_serial_number' => '222222'
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    end

    context 'when both keys and providers are nested arrays' do
      it 'flattens them into two arrays' do
        manifest = {
          'credhub' => {
            'encryption' => {
              'providers' => [
                [
                  {
                    'name' => 'some-internal-provider',
                    'type' => 'internal'
                  }
                ],
                []
              ],
              'keys' => [
                [
                  {
                    'provider_name' => 'some-internal-provider',
                    'key_properties' => 'some-properties',
                    'active' => true
                  }
                ],
                []
              ]
            }
          }
        }
        expect { template.render(manifest) }.to_not raise_error
      end
    end

    context 'when an HSM provider is configured' do
      it 'points every client path at the operator-installed luna-hsm-client package' do
        conf = template.render(hsm_manifest)

        expect(conf).to include('LibUNIX64 = /var/vcap/packages/luna-hsm-client/libs/64/libCryptoki2.so;')
        expect(conf).to include('ToolsDir = /var/vcap/packages/luna-hsm-client/bin/64;')
        expect(conf).to include('SSLConfigFile = /var/vcap/packages/luna-hsm-client/openssl.cnf;')
      end

      it 'no longer references the bundled luna-hsm-client-7.4 package' do
        expect(template.render(hsm_manifest)).to_not include('luna-hsm-client-7.4')
      end

      it 'omits the 32-bit LibUNIX entry, which no client ships' do
        expect(template.render(hsm_manifest)).to_not match(/^\s*LibUNIX\s*=/)
      end

      it 'still renders one ServerName0N/ServerPort0N pair per configured server' do
        conf = template.render(hsm_manifest)

        expect(conf).to include('ServerName00 = 10.0.0.1;')
        expect(conf).to include('ServerPort00 = 1792;')
        expect(conf).to include('ServerName01 = 10.0.0.10;')
        expect(conf).to include('ServerPort01 = 1792;')
      end

      it 'still renders the client PEM paths and the HAConfiguration block' do
        conf = template.render(hsm_manifest)

        expect(conf).to include('ClientPrivKeyFile = /var/vcap/jobs/credhub/config/client_key.pem;')
        expect(conf).to include('ClientCertFile = /var/vcap/jobs/credhub/config/client_cert.pem;')
        expect(conf).to include('ServerCAFile = /var/vcap/jobs/credhub/config/hsm_cert.pem;')
        expect(conf).to include('HAConfiguration = {')
        expect(conf).to include('HAOnly = 1;')
      end
    end

    context 'when no HSM provider is configured' do
      it 'renders nothing that mentions the client' do
        manifest = {
          'credhub' => {
            'encryption' => {
              'providers' => [
                {
                  'name' => 'some-internal-provider',
                  'type' => 'internal'
                }
              ]
            }
          }
        }

        expect(template.render(manifest)).to_not include('luna-hsm-client')
      end
    end
  end
end
