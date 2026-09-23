require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/configure_hsm.sh template' do
    let(:template) { job.template('bin/configure_hsm.sh') }

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
                      'port' => 1792,
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

    context 'when providers is a nested array' do
      it 'flattens providers arrays into one providers array' do
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
                [
                  {
                    'name' => 'kms-provider-1',
                    'type' => 'kms-plugin',
                    'connection_properties' => {
                      'endpoint' => '/path/to/first/socket'
                    }
                  }
                ]
              ]
            }
          }
        }
        expect { template.render(manifest) }.to_not raise_error
      end
    end

    context 'when an HSM provider is configured' do
      it 'fails fast when the operator-installed client package is missing' do
        script = template.render(hsm_manifest)
        message = script.lines.find { |line| line.include?('no Luna HSM client is installed') }

        expect(script).to include('if [ ! -d /var/vcap/packages/luna-hsm-client ]; then')
        expect(message).to_not be_nil
        expect(message).to include('CredHub is configured to use an HSM encryption provider, but no Luna HSM client is installed at /var/vcap/packages/luna-hsm-client.')
      end

      it 'fails fast on every path in the client layout contract' do
        script = template.render(hsm_manifest)

        expect(script).to include('if [ ! -f /var/vcap/packages/luna-hsm-client/libs/64/libCryptoki2.so ]; then')
        expect(script).to include('if [ ! -x /var/vcap/packages/luna-hsm-client/bin/64/lunacm ]; then')
        expect(script).to include('if [ ! -f /var/vcap/packages/luna-hsm-client/jsp/LunaProvider.jar ]; then')
        expect(script).to include('if [ ! -f /var/vcap/packages/luna-hsm-client/jsp/64/libLunaAPI.so ]; then')
        expect(script).to include('if [ ! -f /var/vcap/packages/luna-hsm-client/openssl.cnf ]; then')
      end

      it 'fails fast when openssl.cnf is missing' do
        script = template.render(hsm_manifest)
        openssl_message = script.lines.find { |line| line.include?('openssl.cnf was not found') }

        expect(openssl_message).to_not be_nil
        expect(openssl_message).to include('CredHub is configured to use an HSM encryption provider, but openssl.cnf was not found at /var/vcap/packages/luna-hsm-client/openssl.cnf.')
      end

      it 'exits non-zero from every fail-fast check' do
        script = template.render(hsm_manifest)
        checks = script.scan(%r{^if \[ ! -[dfx] /var/vcap/packages/luna-hsm-client.*?\nfi$}m)

        expect(checks.length).to eq(6)
        checks.each do |check|
          expect(check).to include('>&2')
          expect(check).to include('exit 1')
        end
      end

      it 'still writes the client and HSM PEMs' do
        script = template.render(hsm_manifest)

        expect(script).to include('cat > /var/vcap/jobs/credhub/config/client_cert.pem')
        expect(script).to include('CLIENT-CERT')
        expect(script).to include('cat > /var/vcap/jobs/credhub/config/client_key.pem')
        expect(script).to include('CLIENT-KEY')
        expect(script).to include('cat > /var/vcap/jobs/credhub/config/hsm_cert.pem')
        expect(script).to include('HSM-CERT-1')
        expect(script).to include('HSM-CERT-2')
      end

      it 'still symlinks the generated encryption.conf to /etc/Chrystoki.conf' do
        expect(template.render(hsm_manifest))
          .to include('ln -f -s /var/vcap/jobs/credhub/config/encryption.conf /etc/Chrystoki.conf')
      end

      it 'no longer copies the Luna provider into $JAVA_HOME/lib/ext' do
        script = template.render(hsm_manifest)

        expect(script).to_not include('lib/ext')
        expect(script).to_not include('JAVA_HOME')
      end

      it 'puts the operator-installed client tools on PATH' do
        expect(template.render(hsm_manifest))
          .to include('PATH=$PATH:/var/vcap/packages/luna-hsm-client/bin/64')
      end

      it 'still bootstraps the HA group with lunacm' do
        script = template.render(hsm_manifest)

        expect(script).to include('lunacm -q haGroup listGroups -group "some-partition" -password ""')
        expect(script).to include('haGroup createGroup -label "some-partition" -serialNumber 111111 -password some-partition-password')
        expect(script).to include('haGroup addMember -group $GROUPID -serialNumber 222222 -password some-partition-password')
        expect(script).to include('haGroup synchronize -group $GROUPID -password some-partition-password')
      end

      it 'no longer references the bundled luna-hsm-client-7.4 package' do
        expect(template.render(hsm_manifest)).to_not include('luna-hsm-client-7.4')
      end
    end

    context 'when no HSM provider is configured' do
      it 'emits no HSM footprint at all' do
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
        script = template.render(manifest)

        expect(script).to_not include('luna-hsm-client')
        expect(script).to_not include('lunacm')
        expect(script).to_not include('Chrystoki')
        expect(script).to_not include('.pem')
      end
    end
  end
end
