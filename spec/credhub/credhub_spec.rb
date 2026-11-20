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

    context 'when credhub.additional_java_opts is configured' do
      def manifest_with_java_opts(java_opts)
        base_manifest.merge(
          'credhub' => base_manifest['credhub'].merge('additional_java_opts' => java_opts)
        )
      end

      def java_tool_options_line(java_opts)
        "JAVA_TOOL_OPTIONS=\"${JAVA_TOOL_OPTIONS}\"' #{java_opts}'"
      end

      it 'appends the options to JAVA_TOOL_OPTIONS' do
        script = template.render(
          manifest_with_java_opts('-XX:-UseBASE64Intrinsics -Dsome.flag=true')
        )

        expect(script).to include(
          java_tool_options_line('-XX:-UseBASE64Intrinsics -Dsome.flag=true')
        )
      end

      it 'preserves quoted values containing spaces' do
        script = template.render(
          manifest_with_java_opts('-Dsome.prop="value with spaces"')
        )

        expect(script).to include(java_tool_options_line('-Dsome.prop="value with spaces"'))
      end

      it 'quotes the value so the shell does not evaluate it' do
        script = template.render(manifest_with_java_opts('-Duntrusted=$(id)'))

        expect(script).to include(java_tool_options_line('-Duntrusted=$(id)'))
      end

      it 'escapes embedded single quotes' do
        script = template.render(manifest_with_java_opts(%(-Dsome.prop="it's")))

        expect(script).to include(
          "JAVA_TOOL_OPTIONS=\"${JAVA_TOOL_OPTIONS}\"' -Dsome.prop=\"it'\\''s\"'"
        )
      end

      it 'is appended after the release-managed options' do
        manifest = manifest_with_java_opts('-Dsome.flag=true')
        manifest['credhub']['encryption']['providers'] = hsm_manifest['credhub']['encryption']['providers']

        script = template.render(manifest)

        expect(script.index('-Djava.library.path')).to be < script.index('-Dsome.flag=true')
      end
    end

    context 'when credhub.additional_java_opts is not configured' do
      it 'does not append extra options' do
        expect(template.render(base_manifest)).to_not include('JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS}"')
      end
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
