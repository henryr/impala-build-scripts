#!/usr/bin/python
# Download the latest metastore and hdfs snapshots from the nightly data load build.

import json
import logging
import os
import re
import sys
import urllib

from optparse import OptionParser

logging.basicConfig(level=logging.ERROR, format='%(message)s')
LOG = logging.getLogger('download_snapshot')
LOG.setLevel(level=logging.DEBUG)

# Constants
HDFS_SNAPSHOT_REGEX = re.compile('test-warehouse-cdh[4-5]-[0-9]+-SNAPSHOT.tar.gz')
HDFS_SNAPSHOT_FILE_TEMPLATE = "test-warehouse-cdh%s-%s-SNAPSHOT.tar.gz"
METASTORE_SNAPSHOT_REGEX = re.compile('hive_impala_dump_cdh[4-5]-[0-9]+.txt')
METASTORE_SNAPSHOT_TEMPLATE = "hive_impala_dump_cdh%s-%s.txt"
CDH_MAJOR_VERSION=os.getenv('CDH_MAJOR_VERSION')
JENKINS_JOB_NAMES = {
  '4' : 'impala-master-64bit-nightly-full-data-load',
  '5' : 'impala-CDH5-nightly-data-load'
}
JENKINS_JOB_URL = "http://sandbox.jenkins.cloudera.com/view/Impala/view/Build/job/%s"

def get_last_stable_build_num(jenkins_job_url):
  url = "%s/api/json" % jenkins_job_url
  LOG.info("Getting latest snapshot version from: %s" % (url,))
  handle = urllib.urlopen(url)
  resp = json.loads(''.join([l for l in handle.readlines()]))
  if resp is None or resp.get('lastStableBuild') is None:
    raise RuntimeError("No stable build found")
  return str(resp['lastStableBuild']['number'])

def download_hdfs_snapshot(config, clean):
  # Get the Jenkins url for the latest snapshot.
  # file_name = HDFS_SNAPSHOT_FILE_TEMPLATE % (CDH_MAJOR_VERSION, config['last_stable'])
  snapshot_dir = config['snapshot_dir']
  # url = "%s/lastStableBuild/artifact/testdata/test-warehouse-SNAPSHOT/%s"\
  #     % (config['url'], file_name)
  url = "https://s3-us-west-1.amazonaws.com/cdh5-snapshots/public-snapshot.tar.gz"
  # if clean:
  #   # List the snapshots in the download dir (if any). If a snapshot in different from the
  #   # one we're trying to download, delete it.
  #   if os.path.isdir(snapshot_dir):
  #     different_snapshots = filter(lambda x: re.match(HDFS_SNAPSHOT_REGEX, x) and\
  #         x != file_name, os.listdir(snapshot_dir))
  #     for different_snapshot in different_snapshots:
  #       LOG.info("Removing older snapshot: %s" % different_snapshot)
  #       os.system("rm -f %s/%s" % (snapshot_dir, different_snapshot))
  _download(snapshot_dir, url)

def download_metastore_snapshot(config):
  file_name = METASTORE_SNAPSHOT_TEMPLATE % (CDH_MAJOR_VERSION, config['last_stable'])
  url = "%s/lastStableBuild/artifact/%s" % (config['url'], file_name)
  os.system("rm -f %s/hive_impala_*.txt" % config['snapshot_dir'])
  _download(config['snapshot_dir'], url)

def _download(dest_dir, target_url):
  """Download a file from a target url to a destination directory"""
  # If the snapshot version has not changed, don't download it.
  # -no-clobber does not download the file if it already exists.
  LOG.info("Downloading snapshot from %s to %s" % (target_url, dest_dir))
  os.system("wget --no-clobber -nv -P %s %s " % (dest_dir, target_url))

def _validate():
  """Simple validation of environment variables"""
  if CDH_MAJOR_VERSION is None:
    raise RuntimeError("CDH_MAJOR_VERSION not set")
  if CDH_MAJOR_VERSION not in JENKINS_JOB_NAMES.keys():
    raise RuntimeError("Unrecognised CDH_MAJOR_VERSION: %s" % (CDH_MAJOR_VERSION,))

def _create_snapshot_config(snapshot_dir, jenkins_job_url):
  return {'snapshot_dir': os.path.abspath(snapshot_dir),
          'url': jenkins_job_url,
          'last_stable': ""} #get_last_stable_build_num(jenkins_job_url)}

if __name__ == "__main__":

  _validate()
  parser = OptionParser()
  parser.add_option("--warehouse_snapshot_dir", dest="warehouse_snapshot_dir",
      default="./", help="The directory to download the snapshot to. Default is ${pwd}")
  parser.add_option("--metastore_snapshot_dir", dest="metastore_snapshot_dir",
      default="./", help="The directory to download the snapshot to. Default is ${pwd}")
  parser.add_option("--clean", dest="clean", default=False, action="store_true",
      help="Clean all snapshots except the latest. Default is False.")
  parser.add_option("--jenkins_job_name", dest="jenkins_job_name", default=None,
      help="Name of the jenkins job to download the snapshot from.")
  options, args = parser.parse_args()
  if options.jenkins_job_name is None:
    # Use the master builds.
    jenkins_job_url = JENKINS_JOB_URL % JENKINS_JOB_NAMES[CDH_MAJOR_VERSION]
  else:
    jenkins_job_url = JENKINS_JOB_URL % options.jenkins_job_name
  # Setup the variables needed to call the download methods.
  config = _create_snapshot_config(options.warehouse_snapshot_dir, jenkins_job_url)
  LOG.info("Last stable build was %s" % (config.get('last_stable'),))
  download_hdfs_snapshot(config, options.clean)
  config = _create_snapshot_config(options.metastore_snapshot_dir, jenkins_job_url)
  download_metastore_snapshot(config)
