#!/bin/bash
# This script builds Impala and runs all tests.

# Set up common environment
source ${WORKSPACE}/repos/impala-build-scripts/jenkins/jenkins-preamble.sh

# Enable debug logging in Jenkins.
# TODO: Look into removing this if it does not have much value.
set -x
# Cleanup old logs, snapshots and tarballs.
rm -rf ${IMPALA_HOME}/cluster_logs/
rm -f ${WORKSPACE}/cluster_logs*tar.gz
rm -f ${WORKSPACE}/hive_impala_dump_*.txt
# Make the be testing directory.
mkdir -p be/Testing/

# Set defaults.
: ${EXPLORATION_STRATEGY:=core}
: ${BUILD_TYPE:=""}
: ${SKIP_METADATA_LOAD:=false}
: ${SKIP_FULL_DATA_LOAD:=true}
BUILDALL_ARGS=""
RET_VAL=0
case $BUILD_TYPE in
  ASAN)
    BUILDALL_ARGS+=("-asan")
    BUILDALL_ARGS+=("-skiptests")
    export ASAN_OPTIONS="handle_segv=0"
    ;;
  HEAPCHECK)
    export HEAPCHECK=normal
    ;;
esac

if [[ "$SKIP_FULL_DATA_LOAD" = "true" ]]; then
  ${IMPALA_HOME}/bin/build_thirdparty.sh -noclean
  if [[ "$SKIP_METADATA_LOAD" = "true" ]]; then
    BUILDALL_ARGS+=("-format_cluster")
    BUILDALL_ARGS+=("-snapshot_file ${IMPALA_SNAPSHOT_FILE}")
    BUILDALL_ARGS+=("-metastore_snapshot_file ${METASTORE_SNAPSHOT_FILE}")
  else
    # Reload the metadata.
    BUILDALL_ARGS+=("-format")
    BUILDALL_ARGS+=("-snapshot_file ${IMPALA_SNAPSHOT_FILE}")
  fi
else
  BUILDALL_ARGS+=("-format")
  BUILDALL_ARGS+=("-testdata")
fi

if ! ${IMPALA_HOME}/buildall.sh ${BUILDALL_ARGS[@]}; then
  echo "buildall.sh ${BUILDALL_ARGS[@]} failed."
  RET_VAL=1
fi

# ASAN runs only a curated set of tests.
if [[ "$BUILD_TYPE" = "ASAN" && $RET_VAL -eq 0 ]]; then
  if ! FE_TEST=false JDBC_TEST=false\
    $IMPALA_HOME/bin/run-all-tests.sh -e $EXPLORATION_STRATEGY; then
    RET_VAL=1
  fi
fi

# If the build was successful, kill all the running services. This is to help workaround a
# Jenkins bug which causes artifact archiving to fail if files continue to be modified.
# Skip this step if the build fails, because it might be useful to keep the services up for
# debugging.
if [ ${RET_VAL} -eq 0 ]; then
  ${IMPALA_HOME}/testdata/bin/kill-all.sh
fi

# Get a UUID for the jenkins job to use as a prefix for archived artifacts. This is useful
# to distinguish artifact names when looking at them locally.
if [[ "$BUILD_TYPE" = "ASAN" || "$BUILD_TYPE" = "HEAPCHECK" ]]; then
  # A Jenkins Matrix build JOB_NAME environment variable includes the job name plus the
  # current vector values, separated by front slashes. To get the actual job name, strip
  # out everything up to the first front slash.
  JOB_UUID=`cut -d "/" -f1 <<< ${JOB_NAME}`-${BUILD_TYPE}-${BUILD_NUMBER}
else
  JOB_UUID=${JOB_NAME}-${BUILD_NUMBER}
fi

CLUSTER_LOG_TARBALL=cluster_logs-${JOB_UUID}.tar.gz
if ! tar -czf ${WORKSPACE}/$CLUSTER_LOG_TARBALL ${IMPALA_HOME}/cluster_logs; then
  echo "Could not create a tarball of the cluster logs."
fi

# Store the psql dump of the metastore.
pg_dump -U hiveuser hive_impala > ${WORKSPACE}/hive_impala_dump_${JOB_UUID}.txt
exit ${RET_VAL}
