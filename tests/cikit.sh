#!/usr/bin/env bash

export ANSIBLE_ARGS="-vv"

PROJECT="cikit-test"

VERSION_PHP="$1"
VERSION_NODEJS="$2"
VERSION_SOLR="$3"
VERSION_RUBY="$4"

: ${VERSION_PHP:="7.0"}
: ${VERSION_NODEJS:="6"}
: ${VERSION_SOLR:="6.5.1"}
: ${VERSION_RUBY:="2.4.0"}

# Change directory to "tests".
cd -P -- $(dirname -- "$0")
# Go to root directory of CIKit.
cd ../

if [ -d "${PROJECT}" ]; then
  rm -rf "${PROJECT}"
fi

./cikit repository \
  --project="${PROJECT}" \
  --php-version="${VERSION_PHP}" \
  --nodejs-version="${VERSION_NODEJS}" \
  --solr-version="${VERSION_SOLR}" \
  --ruby-version"${VERSION_RUBY}"

cd "${PROJECT}"

if [ "running" == $(vagrant status "${PROJECT}.dev" | awk -v pattern="${PROJECT}" '$0~pattern {print $2}') ]; then
  vagrant destroy -f
fi

vagrant up
