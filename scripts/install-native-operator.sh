#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT=$(dirname ${BASH_SOURCE})/..

cd $SCRIPT_ROOT
mkdir -p ${GOPATH}/src/k8s.io
if [ -d "${GOPATH}/src/k8s.io/sample-controller" ] 
then
    echo "${GOPATH}/src/k8s.io/sample-controller exists. Please delete the directory after backup."
    exit 1
else
    cp -r $(pwd)/native-demo-operator $GOPATH/src/k8s.io/sample-controller
    echo "The lab is installed in ${GOPATH}/src/k8s.io/sample-controller, good luck!"
fi
cd - > /dev/null
