require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'config/bpm.yml template' do
    let(:template) { job.template('config/bpm.yml') }

    context 'when credhub.encryption.providers contains kms-plugin providers' do
      it 'mounts the socket directory as additional volumes' do
        encryption_providers = [
          {
            'name' => 'internal',
            'type' => 'internal-provider'
          },
          {
            'name' => 'kms-provider-1',
            'type' => 'kms-plugin',
            'connection_properties' => {
              'endpoint' => '/path/to/first/socket'
            }
          },
          {
            'name' => 'kms-provider-2',
            'type' => 'kms-plugin',
            'connection_properties' => {
              'endpoint' => '/path/to/second/socket'
            }
          }
        ]
        manifest = { 'credhub' => { 'encryption' => { 'providers' => encryption_providers } } }
        rendered_template = template.render(manifest)

        additional_volumes = YAML.safe_load(rendered_template)['processes'][0]['additional_volumes']
        expect(additional_volumes).to include(
          {
            'path' => '/path/to/first',
            'writable' => true,
            'allow_executions' => true
          },
          'path' => '/path/to/second',
          'writable' => true,
          'allow_executions' => true
        )
      end
    end

    context 'when credhub.enable_swappable_backend is true' do
      it 'mounts the socket directory as additional volumes' do
        manifest = {
          'credhub' => {
            'encryption' => {
              'providers' => [
                {
                  'name' => 'internal',
                  'type' => 'internal-provider'
                }
              ],
              'keys' => [
                {
                  'provider_name' => 'internal',
                  'key_properties' => 'some-properties',
                  'active' => true
                }
              ]
            },
            'backend' => {
              'enable_swappable_backend' => true,
              'socket_file' => '/test/socket/path/socket_file.sock'
            }
          }
        }
        rendered_template = template.render(manifest)

        additional_volumes = YAML.safe_load(rendered_template)['processes'][0]['additional_volumes']
        expect(additional_volumes).to include(
          'path' => '/test/socket/path',
          'writable' => true,
          'allow_executions' => true
        )
      end
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
        rendered_template = template.render(manifest)

        additional_volumes = YAML.safe_load(rendered_template)['processes'][0]['additional_volumes']
        expect(additional_volumes).to include(
          'path' => '/path/to/first',
          'writable' => true,
          'allow_executions' => true
        )
      end
    end

    context 'when an HSM provider is configured' do
      it 'mounts the operator-supplied luna-hsm-client package read-only with executions allowed' do
        manifest = {
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
        rendered_template = template.render(manifest)

        unrestricted_volumes = YAML.safe_load(rendered_template)['processes'][0]['unsafe']['unrestricted_volumes']
        expect(unrestricted_volumes).to eq(
          [
            {
              'path' => '/var/vcap/packages/luna-hsm-client',
              'writable' => false,
              'allow_executions' => true
            }
          ]
        )
      end
    end

    context 'when no HSM provider is configured' do
      it 'does not add any unsafe volumes' do
        manifest = {
          'credhub' => {
            'encryption' => {
              'providers' => [
                {
                  'name' => 'internal',
                  'type' => 'internal'
                }
              ]
            }
          }
        }
        rendered_template = template.render(manifest)

        expect(YAML.safe_load(rendered_template)['processes'][0]).to_not have_key('unsafe')
      end
    end
  end
end
