require 'rspec'
require 'json'
require 'yaml'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'config/application/server.yml template' do
    let(:template) { job.template('config/application/server.yml') }

    context 'default configuration' do
      it 'uses port 8844' do
        manifest = { 'credhub' => {} }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['server']['port']).to eq(8844)
      end

      it 'enables SSL with PEM certificate and private key' do
        manifest = { 'credhub' => {} }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['server']['ssl']['enabled']).to eq(true)
        expect(rendered_template['server']['ssl']['enabled_protocols']).to eq('TLSv1.2,TLSv1.3')
        expect(rendered_template['server']['ssl']['certificate']).to eq('/var/vcap/jobs/credhub/config/cert.crt')
        expect(rendered_template['server']['ssl']['certificate-private-key']).to eq('/var/vcap/jobs/credhub/config/priv.key')
        expect(rendered_template['server']['ssl']['key_store']).to be_nil
        expect(rendered_template['server']['ssl']['key_password']).to be_nil
        expect(rendered_template['server']['ssl']['key_store_password']).to be_nil
        expect(rendered_template['server']['ssl']['key_alias']).to be_nil
      end

      it 'uses default ciphers in the correct order' do
        manifest = { 'credhub' => {} }
        rendered_template = YAML.safe_load(template.render(manifest))

        ciphers = rendered_template['server']['ssl']['ciphers'].split(',')
        expect(ciphers).to eq(%w[
                                TLS_DHE_RSA_WITH_AES_128_GCM_SHA256
                                TLS_DHE_RSA_WITH_AES_256_GCM_SHA384
                                TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
                                TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
                                TLS_AES_128_GCM_SHA256
                                TLS_AES_256_GCM_SHA384
                              ])
      end

      it 'does not include client trust store properties' do
        manifest = { 'credhub' => {} }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['server']['ssl']['client_auth']).to be_nil
        expect(rendered_template['server']['ssl']['trust_store']).to be_nil
        expect(rendered_template['server']['ssl']['trust_store_password']).to be_nil
        expect(rendered_template['server']['ssl']['trust_store_type']).to be_nil
      end

      it 'sets the active profile to prod' do
        manifest = { 'credhub' => {} }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['spring']['profiles']['active']).to eq('prod')
      end
    end

    context 'when a port is provided' do
      it 'uses the port' do
        port = rand(1..65_525)
        manifest = {
          'credhub' => {
            'port' => port
          }
        }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['server']['port']).to eq(port)
      end
    end

    # CredHubDeprecatedStartingAfter(2.1.2)
    context 'when Java 7 chipers are enabled' do
      it 'appends Java 7 ciphers' do
        manifest = {
          'credhub' => {
            'java7_tls_ciphers_enabled' => true
          }
        }
        rendered_template = YAML.safe_load(template.render(manifest))

        ciphers = rendered_template['server']['ssl']['ciphers'].split(',')
        expect(ciphers).to eq(%w[
                                TLS_DHE_RSA_WITH_AES_128_GCM_SHA256
                                TLS_DHE_RSA_WITH_AES_256_GCM_SHA384
                                TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
                                TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
                                TLS_AES_128_GCM_SHA256
                                TLS_AES_256_GCM_SHA384
                                TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
                                TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
                              ])
      end
    end

    context 'when mutual TLS CAs are provided' do
      it 'includes client trust store properties' do
        manifest = {
          'credhub' => {
            'authentication' => {
              'mutual_tls' => {
                'trusted_cas' => ['some-trusted-ca']
              }
            }
          }
        }
        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['server']['ssl']['client_auth']).to eq('want')
        expect(rendered_template['server']['ssl']['trust_store']).to eq('/var/vcap/jobs/credhub/config/mtls_trust_store.jks')
        expect(rendered_template['server']['ssl']['trust_store_password']).to eq('${MTLS_TRUST_STORE_PASSWORD}')
        expect(rendered_template['server']['ssl']['trust_store_type']).to eq('JKS')
      end
    end

    context 'when concatenate_cas is true' do
      it 'sets server property to true' do
        manifest = {
          'credhub' => {
            'certificates' => {
              'concatenate_cas' => true
            }
          }
        }

        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['certificates']['concatenate_cas']).to eq(true)
      end
    end

    context 'when enable_default_ca_key_usages is true' do
      it 'sets server property to true' do
        manifest = {
          'credhub' => {
            'certificates' => {
              'enable_default_ca_key_usages' => true
            }
          }
        }

        rendered_template = YAML.safe_load(template.render(manifest))

        expect(rendered_template['certificates']['enable_default_ca_key_usages']).to eq(true)
      end
    end

    context 'when enable_swappable_backend is true' do
      it 'sets server property to true, sets socket file, and tls connection properties' do
        manifest = {
          'credhub' => {
            'backend' => {
              'enable_swappable_backend' => true,
              'socket_file' => '/tmp/socket/test.shoe',
              'host' => 'any_host',
              'ca_cert' => '----BEGIN etc whatever---'
            }
          }
        }

        rendered_template = YAML.safe_load(template.render(manifest))
        expect(rendered_template['spring']['profiles']['active']).to eq('prod, remote')
        expect(rendered_template['backend']['socket_file']).to eq('/tmp/socket/test.shoe')
        expect(rendered_template['backend']['host']).to eq('any_host')
        expect(rendered_template['backend']['ca_cert']).to eq('----BEGIN etc whatever---')
      end

      it 'errors if the socket file parameter is empty' do
        manifest = {
          'credhub' => {
            'backend' => {
              'enable_swappable_backend' => true
            }
          }
        }

        expect do
          template.render(manifest)
        end.to raise_error('socket_file must be set when enable_swappable_backend is true')
      end

      it 'errors if the ca_cert parameter is empty' do
        manifest = {
          'credhub' => {
            'backend' => {
              'enable_swappable_backend' => true,
              'socket_file' => '/tmp/socket/test.shoe',
              'host' => 'example.com'
            }
          }
        }

        expect { template.render(manifest) }.to raise_error('ca_cert must be set when enable_swappable_backend is true')
      end

      it 'errors if the host parameter is empty' do
        manifest = {
          'credhub' => {
            'backend' => {
              'enable_swappable_backend' => true,
              'socket_file' => '/tmp/socket/test.shoe',
              'ca_cert' => '----BEGIN etc whatever---'
            }
          }
        }

        expect { template.render(manifest) }.to raise_error('host must be set when enable_swappable_backend is true')
      end
    end
  end
end
