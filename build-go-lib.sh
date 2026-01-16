#!/bin/bash
set -e

rn_app_path=$(pwd)
netbirdPath=$1
if [ -z "${1+x}" ]
then
    netbirdPath=${GOPATH}/src/github.com/netbirdio/netbird
fi

version=$2
if [ -z "${2+x}" ]
then
    version=development
fi

cd $netbirdPath

gomobile-netbird init
CGO_ENABLED=0 gomobile-netbird bind -target=ios,iossimulator,tvos,tvossimulator -bundleid=io.netbird.framework -ldflags="-X github.com/netbirdio/netbird/version.version=$version" -o $rn_app_path/NetBirdSDK.xcframework $netbirdPath/client/ios/NetBirdSDK

cd -
