#!/bin/bash
# Sets up a common environment for Jenkins builds.
# Once complete, pwd will be ${IMPALA_HOME}, and bin/impala-config.sh will have been
# sourced.
echo "********************************************************************************"
echo " Building ${JOB_NAME} #${BUILD_NUMBER} "
echo " Node: ${NODE_NAME} / `hostname`"
echo " Branch: ${GIT_BRANCH}@${GIT_COMMIT}"
echo " ${BUILD_URL}"
echo " Path: ${WORKSPACE}"
echo "********************************************************************************"

echo ">>> Setting up Impala Jenkins environment..."
echo ">>> Mounting toolchain"
. /opt/toolchain/toolchain.sh # Sets, among other things, THRIFT_HOME

# Don't exit automatically if any pipeline command returns non-0
set +e
# Make this verbose.
set -x

export IMPALA_HOME=$WORKSPACE/repos/impala
export IMPALA_AUX_TEST_HOME=
export IMPALA_BUILD_SCRIPTS_HOME=${WORKSPACE}/repos/impala-build-scripts/
export IMPALA_LZO=$WORKSPACE/repos/Impala-lzo
export HADOOP_LZO=$WORKSPACE/repos/hadoop-lzo
export TARGET_FILESYSTEM=${TARGET_FILESYSTEM-"hdfs"}
export S3_BUCKET=${S3_BUCKET-}
export FILESYSTEM_PREFIX=""
export LLVM_HOME=/opt/toolchain/llvm-3.3
export PATH=$LLVM_HOME/bin:$THRIFT_HOME/bin:$PATH
export PIC_LIB_PATH=/opt/toolchain/impala_3rdparty-0.5

# If the target filesystem is s3, we need the following information:
# - A valid S3 bucket.
# - A valid aws access key.
# - A valid aws secret key.
# The aws keys are used to populate core-site.xml and enable the hadoop client to talk to
# s3. They're also used as the defaults for Amazon's aws commandline tool.
# Also note that the s3 buckets must be set up by the user to whom the aws keys belong.
if [ "${TARGET_FILESYSTEM}" = "s3" ]; then
  set -e
  # Do some validation checks.
  # If either of the access keys are not provided exit.
  if [[ "${AWS_ACCESS_KEY_ID}" = "" || "${AWS_SECRET_ACCESS_KEY}" = "" ]]; then
    echo "Both AWS_ACCESS_KEY_ID and AWS_SECRET_KEY_ID need to be set"
    echo " and belong to the owner of the s3 bucket in order to access the file system"
    exit 1
  fi
  # Check if the s3 bucket is NULL.
  if [ "${S3_BUCKET}" = "" ]; then
    echo "The ${S3_BUCKET} cannot be an empty string for s3"
    exit 1;
  fi
  echo ">>> Checking access to S3 bucket: ${S3_BUCKET}"
  aws s3 ls "s3://${S3_BUCKET}/"
  echo ">>> Access successful"
  # At this point, we've verified that:
  #   - All the required environment variables are set.
  #   - We are able to talk to the s3 bucket with the credentials provided.
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export FILESYSTEM_PREFIX="s3a://${S3_BUCKET}"
  set +e
fi

TEST_WAREHOUSE_SNAPSHOT_DIR=${WORKSPACE}/testdata/test-warehouse-SNAPSHOT/
METASTORE_SNAPSHOT_DIR=${WORKSPACE}/testdata/hive_metastore_snapshot
rm -rf ${METASTORE_SNAPSHOT_DIR}
mkdir ${METASTORE_SNAPSHOT_DIR}

echo ">>> Building hadoop-lzo"
cd $HADOOP_LZO
if $CLEAN; then
  git clean -dfx && git reset --hard HEAD
fi
ant package || { echo "building hadoop-lzo failed"; exit 1; }

pushd $IMPALA_HOME
if $CLEAN; then
  echo ">>> Cleaning workspace"
  git clean -dfx && git reset --hard HEAD
fi

# Get rid of old results.
rm -rf tests/results
# Nuke /tmp/hadoop-jenkins, which some tests leave behind.
rm -rf /tmp/hadoop-jenkins
# Nuke the cluster_logs directory, which is occasionally left behind.
rm -rf cluster_logs

# Find all java processes by this user that aren't slave.jar-related, and if those
# proceses' parents are 1, kill them to death.
(ps -fe -u $USER |grep java|grep -v grep |grep -v "slave.jar" |\
 awk '{ if ($3 ~ "1") { print $2 } }'|xargs kill -9)

# Enable core dumps
ulimit -c unlimited

# Create a link to the actual data files on the machine
mkdir -p testdata/impala-data
ln -s /data/1/workspace/impala-data/* testdata/impala-data/

. bin/impala-config.sh &> /dev/null
if [ "$CDH_MAJOR_VERSION" != "4" ]; then
  # CDH5+ requires Java 7. JAVA7_HOME should always be set by toolchain.sh.
  # Also clear the LD_* variables so they will pick up the new Java version.
  export JAVA_HOME=$JAVA7_HOME
  export JAVA64_HOME=$JAVA7_HOME
  export PATH=$JAVA_HOME/bin:$PATH
  export LD_LIBRARY_PATH=""
  export LD_PRELOAD=""
  # Re-source impala-config since JAVA_HOME has changed.
  # TODO: Split up impala-config so this step isn't needed?
  . bin/impala-config.sh &> /dev/null
fi
popd

# Unset NUM_CONCURRENT_TESTS for Jenkins, we want the highest degree of parallelism
# possile.
unset NUM_CONCURRENT_TESTS

# Build the arguments for download the test warehouse and metastore snapshots.
DOWNLOAD_SNAPSHOT_ARGS=("--warehouse_snapshot_dir=${TEST_WAREHOUSE_SNAPSHOT_DIR}")
DOWNLOAD_SNAPSHOT_ARGS+=("--metastore_snapshot_dir=${METASTORE_SNAPSHOT_DIR}")
if [ -n "${DATA_LOAD_BUILD_NAME}" ] ; then
  DOWNLOAD_SNAPSHOT_ARGS+=("--jenkins_job_name=${DATA_LOAD_BUILD_NAME}")
fi
DOWNLOAD_SNAPSHOT_ARGS+=("--clean")

# Download the appropriate snapshot if required, and set IMPALA_SNAPSHOT_FILE to its
# location. If a snapshot exists that's different from the one we want to download, delete
# it.
pushd ${IMPALA_BUILD_SCRIPTS_HOME}/jenkins
#if [[ "${SKIP_FULL_DATA_LOAD}" = "true" ]]; then
if ! ./download-latest-snapshot.py ${DOWNLOAD_SNAPSHOT_ARGS[@]}; then
    echo "Unable to download snapshots, aborting build"
    exit 1
fi
#fi
popd

# Find the snapshot (may be empty if one was not downloaded)
export IMPALA_SNAPSHOT_FILE=\
`find $WORKSPACE/testdata/test-warehouse-SNAPSHOT/ -name public-snapshot.tar.gz`
# Find the metastore snapshot (maybe empty if one was not downloaded)
export METASTORE_SNAPSHOT_FILE=\
`find ${METASTORE_SNAPSHOT_DIR}/ -name hive_impala_dump*.txt`

echo ">>> Shell environment:"
env

echo
echo
echo "********************************************************************************"
echo " Environment setup complete, build proper follows"
echo "********************************************************************************"
echo
echo
