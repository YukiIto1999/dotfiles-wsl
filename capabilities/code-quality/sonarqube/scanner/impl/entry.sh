set +x
exec @python@ @source@ --scanner @scanner@ --scanner-package-version @scannerPackageVersion@ --server-url @serverUrl@ "$@"
