#!/bin/bash
#
# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.
export PATH="$PATH":"/usr/local/share/.pub-cache/bin"
mkdir /home/dart/.pub-cache
chmod 777 -R /home/dart/.pub-cache
export PATH="$PATH":"/home/dart/.pub-cache/bin"

# cd /app/example
# flutter pub get

# whoami
# cd /app
# dart pub install
# dart run tool/update_sdk.dart stable
# dart pub install
# dart pub global activate grinder

# cd /app/example
# dart pub get
# cd /app
# FLUTTER_CHANNEL="stable" grind deploy
FLUTTER_CHANNEL="stable" grind serve



DBG_OPTION=
# Only enable Dart debugger if DBG_ENABLE is set.
if [ -n "$DBG_ENABLE" ] && [ "$GAE_PARTITION" = "dev" ]; then
  echo "Enabling Dart debugger"
  DBG_OPTION="--debug:${DBG_PORT:-5858}/0.0.0.0"
  echo "Starting Dart with additional options $DBG_OPTION"
fi
if [ -n "$DART_VM_OPTIONS" ]; then
  echo "Starting Dart with additional options $DART_VM_OPTIONS"
fi
 exec dart \
     ${DBG_OPTION} \
     --enable-vm-service:8181/0.0.0.0 \
     ${DART_VM_OPTIONS} \
     bin/server.dart \
     $@
