#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT=$(dirname ${BASH_SOURCE})/..

cd $SCRIPT_ROOT
mkdir -p $GOPATH/src/github.com/caicloud
rm -rf $GOPATH/src/k8s.io/sample-controller
cp -r $(pwd)/native-demo-operator $GOPATH/src/k8s.io/sample-controller
cd - > /dev/null
