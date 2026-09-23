This guide provides instructions to create new AWS CloudHSM Classic devices and configure them to work with CredHub. If you choose to use a Luna SafeNet HSM that is not provided by AWS, you may skip over the device allocation portion to [initialize and configured your HSMs.](#initialize-and-configure-new-hsms)

It is recommended that you configure at least two HSMs if the data stored in CredHub is critical. Appropriately configured HSMs allow key replication which provides redundancy of the key material in the event of an HSM device failure. If you choose to run a single HSM, your CredHub data will not be accessible in the event of a device failure. 

## Create New AWS CloudHSMs

#### AWS Environment Prerequisites
1. VPC
1. There should be one private subnet for each planned HSM instance, and each subnet should be in its own Availability Zone. There need to be at least two HSMs for HA. The AWS documentation says that there should also be a subnet for a publicly available Control Instance, but that is not necessary in this case because CredHub plays the role of Control Instance
1. IAM Role for the HSM with a policy equivalent to `AWSCloudHSMRole` policy
1. The Security Group must allow traffic from the CredHub security group on ports 22 (SSH) and 1792 (HSM)

#### Create New Devices
1. [Install `cloudhsm` CLI](http://docs.aws.amazon.com/cloudhsm/classic/userguide/install_cli.html)

1. Create SSH keypairs for all planned HSMs
  
    ```sh
    ssh-keygen -b 4096 -t rsa -N <password> -f path/to/ssh-key.pem
    ```
  
1. Create `cloudhsm.conf` file  
  
    ```
    [cloudhsmcli]
    aws_access_key_id=<value>
    aws_secret_access_key=<value>
    aws_region=<value>
    ```
  
    More about the configuration file for `cloudhsm` CLI can be found [here](http://docs.aws.amazon.com/cloudhsm/classic/userguide/cli-getting-started.html#config_files).

1. Run the following command to create each HSM and place it in the appropriate subnet

    ```sh
    cloudhsm create-hsm \
      --conf_file path/to/cloudhsm.conf \
      --subnet-id <subnet-id> \
      --ssh-public-key-file path/to/ssh-key.pem.pub \
      --iam-role-arn <iam_hsm_role_arn>
    ```
1. Assign the security group to each HSM. First, get the Elastic Network Interface ID `EniID` of the HSM

    ```sh
    cloudhsm describe-hsm -H <hsm_arn> -r <aws_region>
    ```
  
    Then modify the network interface to assign the security group:
  
    ```sh
    aws ec2 modify-network-interface-attribute \
      --network-interface-id <eni_id> \
      --groups <security_group_id>
    ```

## Initialize and Configure New HSMs

Complete the following steps for each HSM.

#### SSH onto the HSM

1. Get the HSM IP

    ```sh
    cloudhsm describe-hsm -H <hsm_arn> -r <aws_region>
    ```

1. SSH onto the HSM

    ```sh
    ssh -i path/to/ssh-key.pem manager@<hsm_ip>
    ```

#### Initialize and Set Policies

1. Initialize the HSM and create an Administrator password. All HSMs must be initialized into the same cloning domain in order to be configured for HA

    ```sh
    lunash:> hsm init -label <label>
    ```

1. Log into the HSM by using the password from the previous step

    ```sh
    lunash:> hsm login
    ```

1. Ensure that only FIPS algorithms are enabled

    ```sh
    lunash:> hsm changePolicy -policy 12 -value 0
    ```

1. Ensure that `Allow cloning` and `Allow network replication` policy values are set to **On** on the HSM by running `hsm showPolicies`. If not, change them by running the following command:

    ```sh
    lunash:> hsm changePolicy -policy <policy_code> -value 1
    ```

1. Validate that the `SO can reset partition PIN` is set appropriately for your organization. If this is set to **Off**, consecutive deployments that use an invalid partition password will permanently erase the partition once the failure count hit the configured threshold. If this is set to **On**, the partition will be locked once the threshold is hit. An HSM Admin is required to unlock the partition, but no data will be lost. The following command demonstrates turning this policy on:

    ```sh
    lunash:> hsm changePolicy -policy 15 -value 1
    ```

#### Retrieve HSM Certificate

1. Fetch the certificate from the HSM. This is used to validate the identity of the HSM when connecting to it.

    ```sh
    scp -i path/to/ssh-key.pem \
      manager@<hsm_ip>:server.pem \
      <hsm_ip>.pem
    ```

#### Create HSM Partition

1. Create a partition to hold the encryption keys. The partition password must be the same for all partitions in the HA partition group. The cloning domain must be the same as in step 1

    ```sh
    lunash:> partition create -partition <partition_name> -domain <cloning_domain>
    ```

1. Record the partition serial number (labeled `Partition SN`)

    ```sh
    lunash:> partition show -partition <partition_name>
    ```

## Create and Register HSM Clients 

Clients that communicate with the HSM must provide a client certificate to establish a client-authenticated session. You must setup each client's certificate on the HSM and assign access rights for each partition they access.

#### Establish a Network Trust Link between the Client and the HSMs
1. Create a certificate for the client

    ```sh
    openssl req \
      -x509   \
      -newkey rsa:4096 \
      -days   <num_of_days> \
      -sha256 \
      -nodes  \
      -subj   "/CN=<client_hostname_or_ip>" \
      -keyout <client_hostname_or_ip>Key.pem \
      -out    <client_hostname_or_ip>.pem
    ```

1. Copy the client certificate to each HSM

    ```sh
    scp -i path/to/ssh-key.pem \
      <client_hostname_or_ip>.pem \
      manager@<hsm_ip>:<client_hostname_or_ip>.pem
    ```

#### Register HSM Client Host and Partitions

1. Create a client. The client hostname is the hostname of the planned CredHub instance(s)

    ```sh
    lunash:> client register -client <client_name> -hostname <client_hostname>
    ```
  
    If only one CredHub instance is planned, it's possible to register a client with the planned CredHub IP
  
    ```sh
    lunash:> client register -client <client_name> -ip <client_ip>
    ```

1. Assign the partition created in the previous section to the client

    ```sh
    lunash:> client assignPartition -client <client_name> -partition <partition_name>
    ```

## Encryption Keys on the HSM

You must define the encryption key name in the deploy manifest to set which key will be used for encryption operations. If this key exists on the HSM, it will be used. If it does not exist, it will be automatically created by CredHub in the referenced partition. 

When generating a new key, it is recommended that you review the list of keys on each HSM to validate that key replication is functioning appropriately. 

1. To review stored keys on a partition

    ```sh
    lunash:> partition showContents -partition <partition_name>
    ```

## Install the Luna HSM Client

`credhub-release` does not ship a Luna HSM client. You must install one yourself, under your own Thales entitlement, before deploying CredHub with an `hsm` encryption provider. CredHub will refuse to start without it.

#### Where CredHub looks for it

CredHub loads the client from a fixed path:

```
/var/vcap/packages/luna-hsm-client
```

This is not configurable. The client must be delivered as a BOSH package named `luna-hsm-client`, because the BOSH agent owns `/var/vcap/packages` — a symlink or a hand-copied directory there will not survive. A client installed by other means (a vendor RPM under `/usr/safenet/lunaclient`, or a stemcell-baked tree) cannot be used directly.

#### Layout contract

CredHub expects the vendor client tree to be laid out under that path as follows. These five paths are the interface between the client package and CredHub; pre-start checks each one and fails with a message naming the missing path.

| Path under `/var/vcap/packages/luna-hsm-client` | Used for |
|---|---|
| `libs/64/libCryptoki2.so` | the PKCS#11 library (`Chrystoki2.LibUNIX64`) |
| `bin/64/` (must contain an executable `lunacm`) | HA partition group bootstrap (`Misc.ToolsDir`) |
| `openssl.cnf` | NTLS client TLS config (`LunaSA Client.SSLConfigFile`) |
| `jsp/LunaProvider.jar` | the JCE provider, added to CredHub's classpath |
| `jsp/64/libLunaAPI.so` | the provider's native library (`-Djava.library.path`) |

The 10.9.3 Minimal Client tarball satisfies all five paths as shipped, so a package built by untarring it with `--strip-components=1` needs no further normalization. The 10.9.3 Universal Client also keeps `openssl.cnf` at the client root.

`openssl.cnf` is the one file whose location has varied between client flavours — the 7.4 Minimal Client kept it in `bin/64/`, and Thales' DPoD `cvclient-min` uses `etc/`. If the client you package puts it anywhere other than the client root, move it to the package root when building the package.

#### Delivering the client

Build your own BOSH release that carries the vendor client as a package named `luna-hsm-client`, then get that package onto the CredHub VM. The release needs nothing but the package and a job that depends on it; its `packaging` script untars the vendor tarball into `${BOSH_INSTALL_TARGET}`.

How you attach it depends on how CredHub is deployed:

**CredHub as its own BOSH deployment** — `bosh upload-release` your client release, then register a runtime config that adds its job to the `credhub` job:

```yaml
releases:
- name: luna-hsm-client
  version: <your-version>

addons:
- name: luna-hsm-client
  jobs:
  - name: luna-hsm-client
    release: luna-hsm-client
  include:
    jobs:
    - name: credhub
      release: credhub
```

**CredHub colocated on a BOSH Director VM** — a runtime config cannot reach it, because the Director VM is created by `bosh create-env` rather than by a director. Colocate the `luna-hsm-client` job onto the Director's instance group in the `create-env` manifest instead, alongside the `credhub` job.

Either way, the package lands at `/var/vcap/packages/luna-hsm-client`, because that is where BOSH links a job's declared package. Confirm it is populated on the VM before deploying CredHub.

Note that `luna-hsm-client` is **not** listed in the `credhub` job's own `packages:`, since it comes from a different release. BOSH therefore cannot verify the dependency and will not fail the deploy when the client is absent — the pre-start checks described above are the only guard, and they run on every VM start.

#### CredHub owns `/etc/Chrystoki.conf` on the VM

CredHub generates its own `Chrystoki.conf` from the manifest properties below and **overwrites the `/etc/Chrystoki.conf` symlink on every VM start**, pointing it at `/var/vcap/jobs/credhub/config/encryption.conf`.

If your client install wrote its own `Chrystoki.conf` — vendor installers usually write one at the client root and often at `/etc/Chrystoki.conf` too — it is not what CredHub uses, and any `lunacm` or `vtl` command you run by hand on that VM will read CredHub's generated file rather than yours. Do not configure the client by editing `Chrystoki.conf`; configure it through the manifest.

This matters most on the BOSH Director, where CredHub, bbr-credhub, the Director itself and the Luna client job all share one instance group, so `/etc/Chrystoki.conf` is shared between jobs rather than a private file on a dedicated VM.

## Ready for Deployment 

After completing the above steps, you should have the following information for the CredHub deployment manifest:

1. [Encryption Key Name](#encryption-keys-on-the-hsm)
1. [HSM Certificate](#retrieve-hsm-certificate)
1. [Partition name and password](#create-hsm-partition)
1. [Client certificate and private key](#establish-a-network-trust-link-between-the-client-and-the-hsms)
1. [Partition serial numbers](#create-hsm-partition)
1. A [Luna HSM client installed](#install-the-luna-hsm-client) at `/var/vcap/packages/luna-hsm-client` on the CredHub VM

These should be entered in the manifest as shown below - 

```yaml
credhub: 
  properties: 
    encryption:
      keys:
        - provider_name: primary
          encryption_key_name: [encryption-key-name]
          active: true
      providers:
        - name: primary
          type: hsm
          partition: [partition-name]
          partition_password: [partition-password]
          client_certificate: [client-certificate]
          client_key: [client-private-key]
          servers: 
          - host: 10.0.0.1
            port: 1792
            certificate: [hsm-certificate]
            partition_serial_number: [partition-serial-number]
          - host: 10.0.0.10
            port: 1792
            certificate: [hsm-certificate]
            partition_serial_number: [partition-serial-number]
```

## Renew or Rotate a Client Certificate 

The generated client certificate has a fixed expiration date after which it will no longer be accepted by the HSM. You may rotate or renew this certificate at any time by following the steps detailed below.

1. Generate a new certificate for the client

    ```sh
    openssl req \
      -x509   \
      -newkey rsa:4096 \
      -days   <num_of_days> \
      -sha256 \
      -nodes  \
      -subj   "/CN=<client_hostname_or_ip>" \
      -keyout <client_hostname_or_ip>Key.pem \
      -out    <client_hostname_or_ip>.pem
    ```

1. Copy the client certificate to each HSM

    ```sh
    scp -i path/to/ssh-key.pem \
      <client_hostname_or_ip>.pem \
      manager@<hsm_ip>:<client_hostname_or_ip>.pem
    ```

1. (Optional) Review the client's partition assignments 

    ```sh
    lunash:> client show -client <client_name>
    ```
  
1. Remove the existing client. _Note: All partition assignments will be deleted_

    ```sh
    lunash:> client delete -client <client_name>
    ```
  
1. Re-register the client

    ```sh
    lunash:> client register -client <client_name> -ip <client_ip>
    ```
  
1. Re-assign partition assignments

    ```sh
    lunash:> client assignPartition -client <client_name> -partition <partition_name>
    ```
  
1. (Optional) Validate new certificate fingerprint

    ```sh
    lunash:> client fingerprint -client <client_name>
    ```

This fingerprint may be compared to your locally stored certificate with the command `openssl x509 -in clientcert.pem -outform DER | md5sum`.
