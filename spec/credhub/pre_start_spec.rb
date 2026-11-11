require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/pre-start template' do
    let(:template) { job.template('bin/pre-start') }

    %w[hsm internal].each do |provider_type|
      it "restricts config ownership and permissions before initialization with an #{provider_type} provider" do
        manifest = {
          'credhub' => {
            'tls' => { 'certificate' => 'some-certificate', 'private_key' => 'some-key' },
            'encryption' => { 'providers' => [{ 'name' => 'primary', 'type' => provider_type }] }
          }
        }
        script = template.render(manifest)
        commands = [
          'chown -R vcap /var/vcap/jobs/credhub/config',
          'chmod -R g-rwx,o-rwx /var/vcap/jobs/credhub/config/*',
          '/var/vcap/jobs/credhub/bin/init_key_stores.sh'
        ]
        if provider_type == 'hsm'
          commands << '/var/vcap/jobs/credhub/bin/configure_hsm.sh'
        else
          expect(script).not_to include('/var/vcap/jobs/credhub/bin/configure_hsm.sh')
        end

        positions = commands.map do |command|
          expect(script.scan(command).length).to eq(1)
          script.index(command)
        end
        expect(positions).to eq(positions.sort)
      end
    end

    context 'when both keys and providers are nested arrays' do
      it 'flattens them into two arrays' do
        manifest = {
          'credhub' => {
            'tls' => {
              'certificate' => 'some-certificate',
              'private_key' => 'some-key'
            },
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
        expect { template.render(manifest) }.not_to raise_error
      end
    end
  end
end
