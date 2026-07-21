# <div align="center"><img src="docs/images/logo.png" alt="CredHub"></div>

CredHub Release provides a BOSH Release for [CredHub](https://github.com/cloudfoundry-incubator/credhub).

* [Documentation](docs/)
* [CredHub Tracker](https://www.pivotaltracker.com/n/projects/1977341)

See additional repos for more info:

* [credhub](https://github.com/cloudfoundry-incubator/credhub) :     CredHub server code
* [credhub-cli](https://github.com/cloudfoundry-incubator/credhub-cli) :     command line interface for credhub
* [credhub-acceptance-tests](https://github.com/cloudfoundry-incubator/credhub-acceptance-tests) : integration tests written in Go.

## Deploying CredHub

This repository includes code to create a BOSH release of [CredHub.][1] Releases based on this repository are created and posted automatically to [bosh.io][2] for deployment.

Adding CredHub to an existing deployment manifest can be done by simply adding the release and its appropriate [job configurations.][3] Complete sample manifests can be [found here.](sample-manifests/)

```
releases:
- name: credhub
  url: https://bosh.io/d/github.com/pivotal-cf/credhub-release?v=1.5.0
  version: 1.5.0
  sha1: f965d47c261c9c554399ea02cf7ab343b7b7f843
```

[1]:https://github.com/cloudfoundry-incubator/credhub
[2]:https://bosh.io/releases/github.com/pivotal-cf/credhub-release?all=1
[3]:https://bosh.io/jobs/credhub?source=github.com/pivotal-cf/credhub-release

### TLS certificate storage

CredHub loads `credhub.tls.certificate` and `credhub.tls.private_key` directly
through Spring Boot's PEM TLS support. Supply the leaf certificate first,
followed by any intermediate certificates. Pre-start normalizes the private key
to unencrypted PKCS#8 and retains `config/cert.crt` and `config/priv.key` under the
CredHub job directory, owned by `vcap` with mode `0600`. These files must remain
available while CredHub runs.
The `tmp/var-store` password file is also owned by `vcap` with mode `0600`:
pre-start runs as root, but the BPM launcher must source it as `vcap` before
initializing logging or starting Java.

Loading PEM files directly avoids the OpenSSL PKCS#12 password-derivation path
that fails with the Noble FIPS provider. Existing mutual-TLS client authentication
and the mutual-TLS, database, and UAA truststores are unchanged. The runtime
cryptographic providers still require separate FIPS 140-3 validation.


## Reporting a Vulnerability

We strongly encourage people to report security vulnerabilities privately to our security team before disclosing them in a public forum.

Please note that the e-mail address below should only be used for reporting undisclosed security vulnerabilities in Pivotal products and managing the process of fixing such vulnerabilities. We cannot accept regular bug reports or other security-related queries at this address.

The e-mail address to use to contact the Pivotal Application Security Team is security@pivotal.io. Find our PGP fingerprint and more information about our security channels at [pivotal.io/security](https://pivotal.io/security/).
