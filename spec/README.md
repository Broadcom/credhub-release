# CredHub BOSH release tests

This directory contains tests for the BOSH release jobs in the
`../jobs` directory (notice the symmetric directory structure).

To run the tests:
```
rspec .
```

You can also run the tests from the root of the repository by running
```
rspec spec
```

The key-store initialization specs execute Bash, OpenSSL, and `keytool`; put a
JDK or JRE's `bin` directory on `PATH`. They use temporary directories and do not
write to the host's `/var/vcap` paths.

Run `credhub/init_key_stores_spec.rb` as root in an isolated Linux test environment
to cover the pre-start-to-runtime ownership transition as well. The tests map
`vcap` to the existing unprivileged `nobody` account and verify that it can source
the password file and read the private key. Without root, that privileged example
is skipped; the other initialization specs still run. CI runs both variants.
