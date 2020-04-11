#!/bin/bash

set -eu

VERUS_DESKTOP_VERSION=0.6.4-beta-1
if [[ -z "${VRSC_DATA_DIR-}" ]]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    VRSC_DATA_DIR="$HOME/Library/Application Support/Komodo/VRSC"
  else
    VRSC_DATA_DIR="$HOME/.komodo/VRSC"
  fi
fi
if [[ "$OSTYPE" == "darwin"* ]]; then
  PARAMS_DIR="$HOME/Library/Application Support/ZcashParams"
  PACKAGE=Verus-Desktop-MacOS-v${VERUS_DESKTOP_VERSION}
else
  PARAMS_DIR="$HOME/.zcash-params"
  if [ "$(uname -m)" == "aarch64" ]; then
    PACKAGE="Verus-Desktop-Linux-v${VERUS_DESKTOP_VERSION}-arm64"
  else
    PACKAGE="Verus-Desktop-Linux-v${VERUS_DESKTOP_VERSION}-x86_64"
  fi
fi

SPROUT_PKEY_NAME='sprout-proving.key'
SPROUT_VKEY_NAME='sprout-verifying.key'
SAPLING_SPEND_NAME='sapling-spend.params'
SAPLING_OUTPUT_NAME='sapling-output.params'
SAPLING_SPROUT_GROTH16_NAME='sprout-groth16.params'
SPROUT_URL="https://download.z.cash/downloads"
SPROUT_IPFS="/ipfs/QmZKKx7Xup7LiAtFRhYsE1M7waXcv9ir9eCECyXAFGxhEo"

BOOTSTRAP_URL="https://bootstrap.veruscoin.io"
VERUS_DESKTOP_URL="https://github.com/VerusCoin/Verus-Desktop/releases/download/v${VERUS_DESKTOP_VERSION}"

SHA256CMD="$(command -v sha256sum || echo shasum)"
SHA256ARGS="$(command -v sha256sum >/dev/null || echo '-a 256')"

WGETCMD="$(command -v wget || echo '')"
IPFSCMD="$(command -v ipfs || echo '')"
CURLCMD="$(command -v curl || echo '')"
PIDOFCMD="$(command -v pidof || echo '')"
PGREPCMD="$(command -v curl || echo '')"
PROCESS_RUNNING=

# fetch methods can be disabled with ZC_DISABLE_SOMETHING=1
ZC_DISABLE_WGET="${ZC_DISABLE_WGET:-}"
ZC_DISABLE_IPFS="${ZC_DISABLE_IPFS:-}"
ZC_DISABLE_CURL="${ZC_DISABLE_CURL:-}"
ZC_DISABLE_BOOTSTRAP=

function check_pidof() {
  if [ -z "${PIDOFCMD}" ]; then
    return 1
  fi
  local processname="$1"
  cat <<EOF

Checking if $processname is running
EOF

  pidof "${processname}" >/dev/null
  # Check the exit code of the shasum command:
  PIDOF_RESULT=$?
  if [ $PIDOF_RESULT -eq 0 ]; then
    PROCESS_RUNNING=1
  else
    PROCESS_RUNNING=0
  fi
}

function check_pgrep() {
  if [ -z "${PGREPCMD}" ]; then
    return 1
  fi
  local processname="$1"
  cat <<EOF

Checking if $processname is running
EOF

  pgrep -x "${processname}" >/dev/null
  # Check the exit code of the shasum command:
  PGREP_RESULT=$?
  if [ $PGREP_RESULT -eq 0 ]; then
    PROCESS_RUNNING=1
  else
    PROCESS_RUNNING=0
  fi
}

function fetch_wget() {
  if [ -z "$WGETCMD" ] || [ -n "$ZC_DISABLE_WGET" ]; then
    return 1
  fi

  local filename="$1"
  local dlname="$2"
  local url="$3"

  cat <<EOF

Retrieving (wget): ${url}/${filename}
EOF

  wget \
    --progress=dot:giga \
    --output-document="${dlname}" \
    --continue \
    --retry-connrefused --waitretry=3 --timeout=30 \
    "${url}/${filename}"
}

function fetch_ipfs() {
  if [ -z "${IPFSCMD}" ] || [ -n "${ZC_DISABLE_IPFS}" ]; then
    return 1
  fi

  local filename="$1"
  local dlname="$2"
  local cid="$3"
  cat <<EOF

Retrieving (ipfs): ${cid}/$filename
EOF

  ipfs get --output "${dlname}" "${cid}/${filename}"
}

function fetch_curl() {
  if [ -z "${CURLCMD}" ] || [ -n "${ZC_DISABLE_CURL}" ]; then
    return 1
  fi

  local filename="$1"
  local dlname="$2"
  local url="$3"
  cat <<EOF

Retrieving (curl): ${url}/${filename}
EOF

  curl \
    --output "${dlname}" \
    -# -L -C - \
    "${url}/${filename}"

}

function fetch_failure() {
  cat >&2 <<EOF

Failed to fetch the Zcash zkSNARK parameters!
Try installing one of the following programs and make sure you're online:

 * ipfs
 * wget
 * curl

EOF
  exit 1
}

function verify_checksum() {
  local filename="$1"
  local dlname="$2"
  local expectedhash="$3"
  cat <<EOF

Verifying $filename checksum
EOF
  "$SHA256CMD" $SHA256ARGS -c <<EOF
$expectedhash $dlname
EOF
}

# Use flock to prevent parallel execution.
function lock() {
  local lockfile=/tmp/verus_desktop_bootstrap.lock
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if shlock -f ${lockfile} -p $$; then
      return 0
    else
      return 1
    fi
  else
    # create lock file
    eval "exec 200>$lockfile"
    # acquire the lock
    flock -n 200 &&
      return 0 ||
      return 1
  fi
}

function exit_locked_error() {
  echo "Only one instance of verus-desktop-bootstrap.sh can be run at a time." >&2
  exit 1
}

function fetch_params() {
  local filename="$1"
  local output="$2"
  local dlname="${output}.dl"
  local expectedhash="$3"

  if ! [ -f "${output}" ]; then
    for i in 1 2; do
      for method in wget curl ipfs failure; do
        if [ "$method" == "ipfs" ]; then
          file_source="${SPROUT_IPFS}"
        else
          file_source="${SPROUT_URL}"
        fi
        if "fetch_$method" "${filename}.part.${i}" "${dlname}.part.${i}" "${file_source}"; then
          echo "Download of part ${i} successful!"
          break
        fi
      done
    done
    for i in 1 2; do
      if ! [ -f "${dlname}.part.${i}" ]; then
        fetch_failure
      fi
    done

    cat "${dlname}.part.1" "${dlname}.part.2" >"${dlname}"
    rm "${dlname}.part.1" "${dlname}.part.2"
    if verify_checksum "${filename}.part.${i}" "$expectedhash" "$dlname"; then
      mv -v "$dlname" "$output"
    else
      echo "Failed to verify parameter checksums!" >&2
      exit 1
    fi
  fi
}

function fetch_bootstrap() {
  data_files=("fee_estimates.dat" "komodostate" "komodostate.ind" "peers.dat" "db.log" "debug.log" "signedmasks")
  data_dirs=("blocks" "chainstate" "database" "notarisations")
  vrsc_data=()
  if ! [ -d "${VRSC_DATA_DIR}" ]; then
    mkdir -p "${VRSC_DATA_DIR}"
  else
    for file in "${data_files[@]}"; do
      if [ -f "${VRSC_DATA_DIR}/${file}" ]; then
        vrsc_data+=("${VRSC_DATA_DIR}"/"${file}")
      fi
    done

    for dir in "${data_dirs[@]}"; do
      if [ -d "${VRSC_DATA_DIR}/${dir}" ]; then
        vrsc_data+=("${VRSC_DATA_DIR}"/"${dir}")
      fi
    done
  fi
  if [ ${#vrsc_data[*]} -lt 1 ]; then
    cd "${VRSC_DATA_DIR}"
    echo Fetching bootstrap
    for method in wget curl failure; do
      if "fetch_$method" "VRSC-bootstrap.tar.gz" "/tmp/VRSC-bootstrap.tar.gz" "${BOOTSTRAP_URL}"; then
        echo "Download successful!"
        break
      fi
    done
    for method in wget curl failure; do
      if "fetch_$method" "VRSC-bootstrap.tar.gz.verusid" "/tmp/VRSC-bootstrap.tar.gz.verusid" "${BOOTSTRAP_URL}"; then
        echo "Download successful!"
        break
      fi
    done

    expectedhash="$(awk -F'[, \t]*' '/hash/{print substr($3,2,length($3)-2)}' /tmp/VRSC-bootstrap.tar.gz.verusid)"
    if verify_checksum VRSC-bootstrap.tar.gz /tmp/VRSC-bootstrap.tar.gz "$expectedhash"; then
      echo Extracting bootstrap
      tar -xzf "/tmp/VRSC-bootstrap.tar.gz" --directory "${VRSC_DATA_DIR}"
      echo Bootstrap successfully installed
      rm /tmp/VRSC-bootstrap.tar.gz
      rm /tmp/VRSC-bootstrap.tar.gz.verusid
    else
      echo "Failed to verify Verus Desktop checksum!" >&2
      rm /tmp/VRSC-bootstrap.tar.gz
      rm /tmp/VRSC-bootstrap.tar.gz.verusid
    fi
  else
    echo "Found existing VRSC data:"
    echo "####################################################################################"
    for item in "${vrsc_data[@]}"; do
      echo "${item}"
    done
    echo "####################################################################################"
    echo
  fi

}

function install_mac() {
  if ! [ -d "/Applications/Verus-Desktop.app" ]; then
    echo fetching ${PACKAGE}.tgz
    for method in wget curl failure; do
      if "fetch_$method" "${PACKAGE}.tgz" "/tmp/${PACKAGE}.tgz" "${VERUS_DESKTOP_URL}"; then
        echo "Verus Desktop download successful!"
        break
      fi
    done
    tar -xzvf "/tmp/${PACKAGE}.tgz" --directory "/tmp"
    expectedhash="$(awk -F'[, \t]*' '/hash/{print substr($3,2,length($3)-2)}' /tmp/${PACKAGE}.dmg.signature.txt)"

    if verify_checksum "${PACKAGE}.dmg" "/tmp/${PACKAGE}.dmg" "$expectedhash"; then
      echo Installing Verus-Desktop
      #Mount dmg
      tempd=$(mktemp -d)
      listing=$(hdiutil attach "/tmp/${PACKAGE}.dmg" | grep Volumes)
      volume=$(echo "$listing" | cut -f 3)
      cp -rf "$volume"/*.app /Applications
      img="hdiutil detach $(echo "$listing" | cut -f 1)"
      eval "$(echo ${img})"
      rm -rf $tempd
      set +x
      echo "Installed Verus-Desktop in ${HOME}/Applications/"
    else
      echo "Failed to verify Verus Desktop checksum!" >&2
      rm /tmp/${PACKAGE}.dm*
      exit 1
    fi
    rm "/tmp/${PACKAGE}.tgz"
    rm "/tmp/${PACKAGE}.dmg"
    rm "/tmp/${PACKAGE}.dmg.signature.txt"

  else
    cat >&2 <<EOF
Verus-Desktop already installed. If your Verus Desktop version is older than v$VERUS_DESKTOP_VERSION and you want
to upgrade, remove Verus Desktop from the Applications folder and run verus-desktop-bootstrap.sh again
EOF
    echo
    echo
  fi
}

function install_linux() {
  if [ ! -f "${HOME}/Desktop/${PACKAGE}.AppImage" ]; then
    for method in wget curl failure; do
      if "fetch_$method" "${PACKAGE}.tgz" "/tmp/${PACKAGE}.tgz" "${VERUS_DESKTOP_URL}"; then
        echo "Verus Desktop download successful!"
        break
      fi
    done
    tar -xzvf "/tmp/${PACKAGE}.tgz" --directory /tmp
    expectedhash="$(awk -F'[, \t]*' '/hash/{print substr($3,2,length($3)-2)}' /tmp/${PACKAGE}.AppImage.signature.txt)"
    if verify_checksum "${PACKAGE}.AppImage" "/tmp/${PACKAGE}.AppImage" "$expectedhash"; then
      mv /tmp/${PACKAGE}.AppImage ${HOME}/Desktop/
      chmod +x "${HOME}/Desktop/${PACKAGE}.AppImage"
      echo "${PACKAGE}.AppImage ready to launch in ${HOME}/Desktop"
      rm "/tmp/${PACKAGE}.tgz"
    else
      echo failed!
      rm "/tmp/${PACKAGE}.AppImage"
    fi
  else
    echo "${PACKAGE}.AppImage is already in ${HOME}/Desktop"
  fi
}

function main() {
  lock verus-desktop-bootstrap.sh ||
    exit_locked_error
  cat <<EOF

This script will install Zcash zkSNARK parameters, VRSC data bootstrap, and Verus Desktop.

EOF

  # Now create PARAMS_DIR and insert a README if necessary:
  if ! [ -d "$PARAMS_DIR" ]; then
    mkdir -p "$PARAMS_DIR"
    README_PATH="$PARAMS_DIR/README"
    cat >>"$README_PATH" <<EOF
This directory stores common Zcash zkSNARK parameters. Note that it is
distinct from the daemon's -datadir argument because the parameters are
large and may be shared across multiple distinct -datadir's such as when
setting up test networks.
EOF

    # This may be the first time the user's run this script, so give
    # them some info, especially about bandwidth usage:
    cat <<EOF

Creating params directory. For details about this directory, see:
$README_PATH

EOF
  fi

  # Sprout parameters:
  fetch_params "$SPROUT_PKEY_NAME" "$PARAMS_DIR/$SPROUT_PKEY_NAME" "8bc20a7f013b2b58970cddd2e7ea028975c88ae7ceb9259a5344a16bc2c0eef7"
  fetch_params "$SPROUT_VKEY_NAME" "$PARAMS_DIR/$SPROUT_VKEY_NAME" "4bd498dae0aacfd8e98dc306338d017d9c08dd0918ead18172bd0aec2fc5df82"

  # Sapling parameters:
  fetch_params "$SAPLING_SPEND_NAME" "$PARAMS_DIR/$SAPLING_SPEND_NAME" "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13"
  fetch_params "$SAPLING_OUTPUT_NAME" "$PARAMS_DIR/$SAPLING_OUTPUT_NAME" "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4"
  fetch_params "$SAPLING_SPROUT_GROTH16_NAME" "$PARAMS_DIR/$SAPLING_SPROUT_GROTH16_NAME" "b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50"

  fetch_bootstrap

  if [[ "$OSTYPE" == "darwin"* ]]; then
    install_mac
  else
    install_linux
  fi
  echo Setup complete
}
main
rm -f /tmp/verus_desktop_bootstrap.lock
exit 0
