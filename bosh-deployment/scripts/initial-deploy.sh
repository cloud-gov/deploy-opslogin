#!/bin/bash

set -e

if [ -z "$BOSH_TARGET" ] || [ -z "$DOMAIN" ] || [ -z "$STACK_NAME" ] || [ -z "$STEMCELL_SHA1"] || [ -z "$STEMCELL_VERSION" ]
then
cat << EOF
  ERROR: Missing environment variable(s).
  
  Required: 

    BOSH_TARGET: The name of the bosh target alias. Example: toolingbosh.
    DOMAIN: The domain of this deployment. Example: westa.cloud.gov
    STACK_NAME: The name of the stack. Example: westa-hub.
    STEMCELL_SHA1: The SHA1 of the stemcell to use. 
    STEMCELL_VERSION: The version of the stemcell. Example: 1.406

  Please be sure the required environment variables are set and run this script again.
EOF
exit 1
fi

# CLONE 
workspace="$HOME/deploy/opslogin"
rm -fr $workspace
mkdir -p $workspace
mkdir -p ${workspace}/cloud-gov
pushd ${workspace}/cloud-gov
    git clone https://github.com/cloud-gov/cg-deploy-opslogin.git
    cd cg-deploy-opslogin
    git checkout f140
popd

# STEMCELL 
bosh -e $BOSH_TARGET upload-stemcell --sha1 ${STEMCELL_SHA1} \
  https://bosh.io/d/stemcells/bosh-aws-xen-hvm-ubuntu-jammy-go_agent?v=${STEMCELL_VERSION}


# RELEASES 
bosh -e $BOSH_TARGET upload-release \
    --sha1 16b91e72fa5fc4b2872718296a07319bda83faa7 \
    https://bosh.io/d/github.com/cloudfoundry/uaa-release?v=77.4.0
bosh -e $BOSH_TARGET upload-release --sha1 9c571c3463818ec1f8afe63d2da98c24381f7dda \
  "https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.2.17"    
bosh -e $BOSH_TARGET upload-release --sha1 55b3dced813ff9ed92a05cda02156e4b5604b273 \
  "https://bosh.io/d/github.com/cloudfoundry/bosh-dns-aliases-release?v=0.0.4"
mkdir -p ${workspace}/releases
pushd $workspace/releases
  aws s3 cp s3://westa-hub-cloud-gov-bosh-releases/uaa-customized-56.tgz . --sse AES256
  aws s3 cp s3://westa-hub-cloud-gov-bosh-releases/secureproxy-64.tgz . --sse AES256
  bosh -e $BOSH_TARGET upload-release --name=uaa-customized --version=56 ./uaa-customized-56.tgz 
  bosh -e $BOSH_TARGET upload-release --name=secureproxy --version=64 ./secureproxy-64.tgz 
popd


# Config 
config_dir=${workspace}/config
rm -fr $config_dir
mkdir -p $config_dir

bosh interpolate ${workspace}/cloud-gov/cg-deploy-opslogin/bosh-deployment/manifest.yml \
  --vars-store ${config_dir}/secrets.yml

aws s3 cp "s3://${STACK_NAME}-terraform-state/${STACK_NAME}/state.yml" ${config_dir}/state.yml --sse AES256

cat <<EOF >> ${config_dir}/domains.yml
uaa:
  base_url: opsuaa.${DOMAIN}
  url: https://opsuaa.${DOMAIN}
opslogin:
  base_url: opslogin.${DOMAIN}
  url: https://opslogin.${DOMAIN}
EOF

pushd $workspace
  bosh -e $BOSH_TARGET deploy -d opslogin cloud-gov/cg-deploy-opslogin/manifest.yml \
    -o cloud-gov/cg-deploy-opslogin/ops/add-bpm.yml \
    -o cloud-gov/cg-deploy-opslogin/ops/disk.yml \
    -l ${config_dir}/domains.yml \
    -l ${config_dir}/secrets.yml \
    -l ${config_dir}/state.yml
popd
