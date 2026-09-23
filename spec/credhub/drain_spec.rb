require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'
require 'tmpdir'
require 'open3'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/drain template' do
    let(:template) { job.template('bin/drain') }

    context 'when keys and providers are nested arrays' do
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

    context 'when the active provider is an HSM' do
      let(:hsm_manifest) do
        {
          'credhub' => {
            'encryption' => {
              'providers' => [
                {
                  'name' => 'primary',
                  'type' => 'hsm',
                  'connection_properties' => {
                    'partition' => 'some-partition'
                  }
                }
              ],
              'keys' => [
                {
                  'provider_name' => 'primary',
                  'encryption_key_name' => 'some-key',
                  'active' => true
                }
              ]
            }
          }
        }
      end

      it 'deletes the HA group using the operator-installed client tools' do
        script = template.render(hsm_manifest)

        expect(script).to include('PATH=$PATH:/var/vcap/packages/luna-hsm-client/bin/64')
        expect(script).to include('lunacm -q haGroup deleteGroup -label some-partition')
      end

      it 'no longer references the bundled luna-hsm-client-7.4 package' do
        expect(template.render(hsm_manifest)).to_not include('luna-hsm-client-7.4')
      end

      # The client is no longer in credhub's `packages:` list, so BOSH does not guarantee it is
      # linked. An unguarded `lunacm` would abort drain with 127 under `set -eu` and wedge the
      # very deploy that would fix the configuration.
      it 'drains cleanly when the operator-installed client is absent' do
        skip 'a real Luna client is installed here' if File.exist?('/var/vcap/packages/luna-hsm-client')

        Dir.mktmpdir do |dir|
          script = File.join(dir, 'drain')
          File.write(script, template.render(hsm_manifest))
          File.chmod(0o755, script)

          stdout, stderr, status = Open3.capture3(
            { 'PATH' => '/usr/bin:/bin' }, 'bash', script
          )

          expect(status.exitstatus).to eq(0), "drain failed: #{stderr}"
          # BOSH reads the drain result off stdout, so it must stay a bare number.
          expect(stdout.strip).to eq('0')
          expect(stderr).to include('skipping HA group teardown')
        end
      end
    end
  end
end
