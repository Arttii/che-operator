#!/bin/bash
#
# Copyright (c) 2019 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation

set -e

REGEX="^([0-9]+)\\.([0-9]+)\\.([0-9]+)(\\-[0-9a-z-]+(\\.[0-9a-z-]+)*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"

CURRENT_DIR=$(pwd)
BASE_DIR=$(cd "$(dirname "$0")"; pwd)
ROOT_PROJECT_DIR=$(dirname "${BASE_DIR}")
source ${BASE_DIR}/check-yq.sh

if [[ "$1" =~ $REGEX ]]
then
  RELEASE="$1"
else
  echo "You should provide the new release as the first parameter"
  echo "and it should be semver-compatible with optional *lower-case* pre-release part"
  exit 1
fi

for platform in 'kubernetes' 'openshift'
do
  packageName="eclipse-che-preview-${platform}"
  echo "[INFO] Creating release '${RELEASE}' of the OperatorHub package '${packageName}' for platform '${platform}'"

  packageBaseFolderPath="${BASE_DIR}/${packageName}"
  cd "${packageBaseFolderPath}"

  LAST_NIGHTLY_CSV="${ROOT_PROJECT_DIR}/deploy/olm-catalog/eclipse-che-preview-${platform}/manifests/che-operator.clusterserviceversion.yaml"
  LAST_NIGHTLY_CRD="${ROOT_PROJECT_DIR}/deploy/olm-catalog/eclipse-che-preview-${platform}/manifests/org_v1_che_crd.yaml"

  packageFolderPath="${packageBaseFolderPath}/deploy/olm-catalog/${packageName}"
  packageFilePath="${packageFolderPath}/${packageName}.package.yaml"
  lastPackageNightlyVersion=$(yq -r ".spec.version" "${LAST_NIGHTLY_CSV}")
  lastPackagePreReleaseVersion=$(yq -r '.channels[] | select(.name == "stable") | .currentCSV' "${packageFilePath}" | sed -e "s/${packageName}.v//")
  echo "[INFO] Last package nightly version: ${lastPackageNightlyVersion}"
  echo "[INFO] Last package pre-release version: ${lastPackagePreReleaseVersion}"

  if [ "${lastPackagePreReleaseVersion}" == "${RELEASE}" ]
  then
    echo "[ERROR] Release ${RELEASE} already exists in the package !"
    echo "[ERROR] You should first remove it"
    exit 1
  fi

  echo "[INFO] Will create release '${RELEASE}' from nightly version ${lastPackageNightlyVersion} that will replace previous release '${lastPackagePreReleaseVersion}'"

  PRE_RELEASE_CSV="${packageFolderPath}/${lastPackagePreReleaseVersion}/${packageName}.v${lastPackagePreReleaseVersion}.clusterserviceversion.yaml"
  PRE_RELEASE_CRD="${packageFolderPath}/${lastPackagePreReleaseVersion}/${packageName}.crd.yaml"
  RELEASE_CSV="${packageFolderPath}/${RELEASE}/${packageName}.v${RELEASE}.clusterserviceversion.yaml"
  RELEASE_CRD="${packageFolderPath}/${RELEASE}/${packageName}.crd.yaml"

  mkdir -p "${packageFolderPath}/${RELEASE}"
  sed \
  -e 's/imagePullPolicy: *Always/imagePullPolicy: IfNotPresent/' \
  -e 's/"cheImageTag": *"nightly"/"cheImageTag": ""/' \
  -e 's|"identityProviderImage": *"quay.io/eclipse/che-keycloak:nightly"|"identityProviderImage": ""|' \
  -e 's|"devfileRegistryImage": *"quay.io/eclipse/che-devfile-registry:nightly"|"devfileRegistryImage": ""|' \
  -e 's|"pluginRegistryImage": *"quay.io/eclipse/che-plugin-registry:nightly"|"pluginRegistryImage": ""|' \
  -e "/^  replaces: ${packageName}.v.*/d" \
  -e "s/^  version: ${lastPackageNightlyVersion}/  version: ${RELEASE}/" \
  -e "/^  version: ${RELEASE}/i\ \ replaces: ${packageName}.v${lastPackagePreReleaseVersion}" \
  -e "s/: nightly/: ${RELEASE}/" \
  -e "s/:nightly/:${RELEASE}/" \
  -e "s/${lastPackageNightlyVersion}/${RELEASE}/" \
  -e "s/createdAt:.*$/createdAt: \"$(date -u +%FT%TZ)\"/" ${LAST_NIGHTLY_CSV} > ${RELEASE_CSV}

  cp ${LAST_NIGHTLY_CRD} ${RELEASE_CRD}
  if [[ $platform == "openshift" ]]; then
    yq -riSY  '.spec.preserveUnknownFields = false' ${RELEASE_CRD}
    yq -riSY  '.spec.validation.openAPIV3Schema.type = "object"' ${RELEASE_CRD}
    eval head -10 ${LAST_NIGHTLY_CRD} | cat - ${RELEASE_CRD} > tmp && mv tmp ${RELEASE_CRD}
  fi

  sed -e "s/${lastPackagePreReleaseVersion}/${RELEASE}/" "${packageFilePath}" > "${packageFilePath}.new"
  mv "${packageFilePath}.new" "${packageFilePath}"

  PLATFORM_DIR=$(pwd)

  cd $CURRENT_DIR
  source ${BASE_DIR}/addDigests.sh -w ${BASE_DIR} \
                -r "eclipse-che-preview-${platform}.*\.v${RELEASE}.*yaml" \
                -t ${RELEASE}

  cd $PLATFORM_DIR

  diff -u ${PRE_RELEASE_CSV} ${RELEASE_CSV} > ${RELEASE_CSV}".diff" || true
  diff -u ${PRE_RELEASE_CRD} ${RELEASE_CRD} > ${RELEASE_CRD}".diff" || true
done
