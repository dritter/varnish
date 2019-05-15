#!/bin/bash
#
# Copyright (c) 2006-2017 Varnish Software AS
# All rights reserved.
#
# Author: Dridi Boukelmoune <dridi.boukelmoune@gmail.com>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

set -e
set -u

MAXIMUM=
WORK_DIR=
VCL_FILE=
WARMUP=
SCRIPT="$0"

usage() {
  test $# -eq 1 &&
  printf 'Error: %s.\n\n' "$1"

  cat <<-EOF
  Usage: $SCRIPT [-m <maximum>] [-n <workdir>] [-w <warmup>] [<file>]
         $SCRIPT -h

  Reload and use a VCL on a running Varnish instance.

  Available options:
  -h           : show this help and exit
  -m <maximum> : maximum number of available reloads to leave behind
  -n <workdir> : specify the name or directory for the varnishd instance
  -w <warmup>  : the number of seconds between load and use operations

  When <file> is empty or missing, the active VCL's file is used but
  will fail if the active VCL wasn't loaded from a file. The <file>,
  when specified, is passed as-is to the vcl.load command. Refer to
  the varnishd manual regarding the handling of absolute or relative
  paths.

  Upon success, the name of the loaded VCL is constructed from the
  current date and time, for example:

      $(vcl_reload_name)

  Afterwards available VCLs created by this script are discarded until
  <maximum> are left, unless it was empty or undefined.
EOF
  exit $#
}

varnishadm() {
  if ! OUTPUT=$(command varnishadm -n "$WORK_DIR" -- "$@" 2>&1)
  then
    echo "Command: varnishadm -n '$WORK_DIR' -- $*"
    echo
    echo "$OUTPUT"
    echo
    exit 1
  fi >&2
  echo "$OUTPUT"
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

vcl_file() {
  VCL_SHOW=$(varnishadm vcl.show -v "$1") ||
  fail "failed to get the VCL file name"

  echo "$VCL_SHOW" |
  awk '$1 == "//" && $2 == "VCL.SHOW" {print; exit}' | {
    read DELIM VCL_SHOW INDEX SIZE FILE
    echo "$FILE"
  }
}

vcl_active_name() {
  VCL_LIST=$(varnishadm vcl.list) ||
  fail "failed to get the active VCL name"

  echo "$VCL_LIST" |
  awk '$1 == "active" {print $NF}'
}

vcl_active_file() {
  set -e
  VCL_NAME=$(vcl_active_name)
  vcl_file "$VCL_NAME"
}

vcl_reload_match() {
  awk '$1 == "available" && $NF ~ /^(boot|reload_.+)$/'" {$1}"
}

vcl_reload_count() {
  VCL_LIST=$(varnishadm vcl.list) ||
  fail "failed to count available reload VCLs"

  echo "$VCL_LIST" |
  vcl_reload_match print |
  sed '=;d' |
  tail -1
}

vcl_reload_oldest() {
  VCL_LIST=$(varnishadm vcl.list) ||
  fail "failed to get the oldest reload VCL"

  echo "$VCL_LIST" |
  vcl_reload_match 'print $NF; exit'
}

vcl_reload_name() {
  printf "reload_%s" "$(date +%Y%m%d_%H%M%S)"
}

while getopts hm:n:w: OPT
do
  case $OPT in
  h) usage ;;
  m) MAXIMUM=$OPTARG ;;
  n) WORK_DIR=$OPTARG ;;
  w) WARMUP=$OPTARG ;;
  *) usage "wrong usage" >&2 ;;
  esac
done

shift $((OPTIND - 1))

test $# -gt 1 && usage "too many arguments" >&2
test $# -eq 1 && VCL_FILE="$1"

if [ -z "$VCL_FILE" ]
then
  VCL_FILE=$(vcl_active_file)

  case $VCL_FILE in
  /*) ;;
  *) fail "active VCL file not found (got $VCL_FILE)" ;;
  esac
fi

RELOAD_NAME=$(vcl_reload_name)

varnishadm vcl.load "$RELOAD_NAME" "$VCL_FILE"

test -n "$WARMUP" && sleep "$WARMUP"

varnishadm vcl.use  "$RELOAD_NAME"

safe_test() {
  test -z "$1" && return 1
  test "$@"
}

safe_test "$MAXIMUM" -ge 0 || exit 0

while true
do
  COUNT=$(vcl_reload_count)
  safe_test "$COUNT" -gt "$MAXIMUM" || exit 0
  OLDEST=$(vcl_reload_oldest)
  varnishadm vcl.discard "$OLDEST" >/dev/null
  echo "VCL '$OLDEST' was discarded"
done
