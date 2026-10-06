require 'rspec'
require 'json'
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'bosh/template/test'

describe 'credhub job' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..', '..')) }
  let(:job) { release.job('credhub') }

  describe 'bin/configure_hsm.sh template' do
    let(:template) { job.template('bin/configure_hsm.sh') }

    def write_mock_lunacm(dir, mock_body)
      bin_dir = File.join(dir, 'bin')
      FileUtils.mkdir_p(bin_dir)
      mock_lunacm = File.join(bin_dir, 'lunacm')
      File.write(mock_lunacm, "#!/usr/bin/env bash\n#{mock_body}\n")
      FileUtils.chmod(0o755, mock_lunacm)
      bin_dir
    end

    def run_ha_setup(script, mock_body, env: {})
      Dir.mktmpdir do |dir|
        bin_dir = write_mock_lunacm(dir, mock_body)
        ha_start = script.index(/^PARTITION_PASSWORD=/)
        raise 'Could not find HA setup starting with PARTITION_PASSWORD=' unless ha_start

        test_script = "#!/usr/bin/env bash\nset -eu\nPATH=\"#{bin_dir}:$PATH\"\n#{script[ha_start..]}"
        Open3.capture3(env, 'bash', stdin_data: test_script)
      end
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

      it 'fails fast when the vcap user cannot read the client package' do
        script = template.render(hsm_manifest)
        jar_check = script.match(/^if ! chpst -u vcap:vcap test -r [^\n]*LunaProvider\.jar; then\n.*?\nfi$/m)
        lunacm_check = script.match(%r{^if ! chpst -u vcap:vcap test -x [^\n]*bin/64/lunacm; then\n.*?\nfi$}m)

        [jar_check, lunacm_check].each do |check|
          expect(check).to_not be_nil
          expect(check[0]).to include('not accessible to the vcap user')
          expect(check[0]).to include('chmod 755 \\"\\${BOSH_INSTALL_TARGET}\\"')
          expect(check[0]).to include('>&2')
          expect(check[0]).to include('exit 1')
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

        expect(script).to include('PARTITION_PASSWORD=some-partition-password')
        expect(script).to include('lunacm -q haGroup listGroups -group "some-partition" -password ""')
        expect(script).to include('haGroup createGroup -label "some-partition" -serialNumber 111111 -password "$PARTITION_PASSWORD"')
        expect(script).to include('haGroup addMember -group "$GROUPID" -serialNumber 222222 -password "$PARTITION_PASSWORD"')
        expect(script).to include('haGroup synchronize -group "$GROUPID" -password "$PARTITION_PASSWORD"')
      end

      it 'no longer references the bundled luna-hsm-client-7.4 package' do
        expect(template.render(hsm_manifest)).to_not include('luna-hsm-client-7.4')
      end
    end

    context 'when partition_password contains shell metacharacters' do
      let(:special_password) { %q{p@ss$o38D "quote" 'single' \slash `id` $(whoami) ; & | < >} }
      let(:special_hsm_manifest) do
        manifest = hsm_manifest.dup
        manifest['credhub']['encryption']['providers'][0]['connection_properties']['partition_password'] = special_password
        manifest['credhub']['encryption']['providers'][0]['connection_properties']['partition'] = 'special-partition'
        manifest
      end

      it 'escapes the partition password into a shell variable' do
        script = template.render(special_hsm_manifest)

        expect(script).to include('PARTITION_PASSWORD=')
        expect(script).to include('lunacm -q haGroup listGroups -group "special-partition" -password ""')
        expect(script).to include('-password "$PARTITION_PASSWORD"')
      end

      it 'emits a shell script with valid bash syntax' do
        script = template.render(special_hsm_manifest)
        _stdout, stderr, status = Open3.capture3('bash', '-n', stdin_data: script)

        expect(status.exitstatus).to eq(0), "bash -n failed: #{stderr}"
      end

      it 'delivers the exact password to lunacm without bash variable expansion or unbound variable errors' do
        script = template.render(special_hsm_manifest)

        Dir.mktmpdir do |dir|
          log_file = File.join(dir, 'captured_passwords.log')
          mock_body = <<~BASH
            cmd="$*"
            if [[ "$cmd" == *"listGroups"* ]]; then
              exit 1 # simulate uninitialized HA group
            fi
            while [ $# -gt 0 ]; do
              if [ "$1" = "-password" ]; then
                echo "$2" >> "$LOG_FILE"
                shift 2
              else
                shift
              fi
            done
            if [[ "$cmd" == *"createGroup"* ]]; then
              echo "HA Group Number: 998877"
            fi
            exit 0
          BASH

          stdout, stderr, status = run_ha_setup(script, mock_body, env: { 'LOG_FILE' => log_file })
          expect(status.exitstatus).to eq(0), "Script failed under set -eu: stderr=#{stderr}, stdout=#{stdout}"
          expect(stderr).to_not include('unbound variable')

          captured = File.read(log_file).split("\n")
          expect(captured.size).to eq(3)
          captured.each do |delivered_pw|
            expect(delivered_pw).to eq(special_password)
          end
        end
      end
    end

    context 'when an invalid or mismatched partition password causes lunacm to fail' do
      it 'fails with a clear error referencing the partition when createGroup fails' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "Error: CKR_PIN_INCORRECT: The specified PIN is incorrect." >&2
            exit 1
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to create HSM HA group for partition 'some-partition'")
        expect(stderr).to include('Please verify the partition password and partition configuration')
        expect(stderr).to include('CKR_PIN_INCORRECT')
      end

      it 'fails with a clear error when createGroup outputs an error with exit 0' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "HA Group Number: 12345"
            echo "Error: CKR_PIN_INCORRECT: The specified PIN is incorrect."
            exit 0
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to create HSM HA group for partition 'some-partition'")
        expect(stderr).not_to include('could not determine HA Group Number')
        expect(stderr).to include('CKR_PIN_INCORRECT')
      end

      it 'fails with a clear error when HA Group Number cannot be determined' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "Unexpected output without group number"
            exit 0
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to create HSM HA group for partition 'some-partition': could not determine HA Group Number")
      end

      it 'fails with a clear error referencing the partition serial number when addMember fails' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "HA Group Number: 12345"
            exit 0
          fi
          if [[ "$*" == *"addMember"* ]]; then
            echo "Error: Partition password mismatch for secondary member." >&2
            exit 1
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to add partition serial number 222222 to HSM HA group 'some-partition'")
        expect(stderr).to include('Please verify that the partition password matches across all HSM servers')
      end

      it 'fails with a clear error when addMember outputs an error with exit 0' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "HA Group Number: 12345"
            exit 0
          fi
          if [[ "$*" == *"addMember"* ]]; then
            echo "Error: Partition password mismatch for secondary member."
            exit 0
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to add partition serial number 222222 to HSM HA group 'some-partition'")
        expect(stderr).to include('Please verify that the partition password matches across all HSM servers')
      end

      it 'fails with a clear error referencing the partition when synchronize fails' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "HA Group Number: 12345"
            exit 0
          fi
          if [[ "$*" == *"addMember"* ]]; then exit 0; fi
          if [[ "$*" == *"synchronize"* ]]; then
            echo "Error: HA Synchronization failed." >&2
            exit 1
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to synchronize HSM HA group 'some-partition'")
        expect(stderr).to include('Please verify that the partition password matches across all HSM servers')
      end

      it 'fails with a clear error when synchronize outputs an error with exit 0' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "HA Group Number: 12345"
            exit 0
          fi
          if [[ "$*" == *"addMember"* ]]; then exit 0; fi
          if [[ "$*" == *"synchronize"* ]]; then
            echo "Error: HA Synchronization failed."
            exit 0
          fi
          exit 0
        BASH

        _stdout, stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("Failed to synchronize HSM HA group 'some-partition'")
        expect(stderr).to include('Please verify that the partition password matches across all HSM servers')
      end

      it 'logs successful lunacm output to stdout for troubleshooting' do
        script = template.render(hsm_manifest)
        mock_body = <<~BASH
          if [[ "$*" == *"listGroups"* ]]; then exit 1; fi
          if [[ "$*" == *"createGroup"* ]]; then
            echo "New group with label some-partition created with group number 12345."
            echo "HA Group Number: 12345"
            exit 0
          fi
          if [[ "$*" == *"addMember"* ]]; then
            echo "Member 222222 successfully added to group 12345."
            exit 0
          fi
          if [[ "$*" == *"synchronize"* ]]; then
            echo "Synchronization completed."
            exit 0
          fi
          exit 0
        BASH

        stdout, _stderr, status = run_ha_setup(script, mock_body)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to include('New group with label some-partition created with group number 12345.')
        expect(stdout).to include('Member 222222 successfully added to group 12345.')
        expect(stdout).to include('Synchronization completed.')
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
