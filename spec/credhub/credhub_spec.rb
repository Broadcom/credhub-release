require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/credhub template' do
    let(:template) { job.template('bin/credhub') }

    let(:base_manifest) do
      {
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
    end

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
                  'partition_password' => 'some-partition-password'
                }
              }
            ]
          }
        }
      }
    end

    it 'always launches via -cp and JarLauncher with --enable-native-access on the command line' do
      script = template.render(base_manifest)

      expect(script).to include('--enable-native-access=ALL-UNNAMED')
      expect(script).to include('-cp "credhub.jar"')
      expect(script).to include('org.springframework.boot.loader.launch.JarLauncher')
      expect(script).to_not include('-jar "credhub.jar"')
    end

    context 'when no HSM provider is configured' do
      it 'does not reference the Luna client or java.library.path' do
        script = template.render(base_manifest)

        expect(script).to_not include('luna-hsm-client')
        expect(script).to_not include('java.library.path')
      end
    end

    context 'when an HSM provider is configured' do
      it 'adds LunaProvider.jar to the classpath and points java.library.path at the native libs' do
        script = template.render(hsm_manifest)

        expect(script).to include('-cp "credhub.jar:/var/vcap/packages/luna-hsm-client/jsp/LunaProvider.jar"')
        expect(script).to include('-Djava.library.path=/var/vcap/packages/luna-hsm-client/jsp/64')
        expect(script).to include('--enable-native-access=ALL-UNNAMED')
      end

      it 'does not export ChrystokiConfigurationPath -- the /etc/Chrystoki.conf symlink is the contract' do
        expect(template.render(hsm_manifest)).to_not include('ChrystokiConfigurationPath')
      end
    end
  end
end
