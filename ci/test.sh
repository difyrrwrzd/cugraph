#!/bin/bash

set -o pipefail

NUMARGS=$#
ARGS=$*
THISDIR=$(cd $(dirname $0);pwd)
CUGRAPH_ROOT=$(cd ${THISDIR}/..;pwd)
GTEST_ARGS="--gtest_output=xml:${CUGRAPH_ROOT}/test-results/"
CI_MODE_FLAG_TO_PASS=""
export RAPIDS_DATASET_ROOT_DIR=${CUGRAPH_ROOT}/datasets

# FIXME: consider using getopts for option parsing
function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

# Add options unique to running tests in CI here:
#  - pass --ci-mode flag to download script to skip large downloads
#  - filter the "huge" dataset tests
if hasArg "--ci-mode"; then
    CI_MODE_FLAG_TO_PASS="--ci-mode"
    GTEST_FILTER="--gtest_filter=-hibench_test/Tests_MGSpmv_hibench.CheckFP32_hibench*:*huge*"
else
    GTEST_FILTER="--gtest_filter=-hibench_test/Tests_MGSpmv_hibench.CheckFP32_hibench*"
fi

if hasArg "--skip-download"; then
    echo "Using datasets in ${RAPIDS_DATASET_ROOT_DIR}"
else
    echo "Download datasets..."
    cd ${RAPIDS_DATASET_ROOT_DIR}
    bash ./get_test_data.sh ${CI_MODE_FLAG_TO_PASS}
fi

cd ${CUGRAPH_ROOT}/cpp/build

for gt in gtests/*; do
    test_name=$(basename $gt)
    echo "Running GoogleTest $test_name"
    ${gt} ${GTEST_FILTER} ${GTEST_ARGS}
done

exit 0

echo "Python py.test for cuGraph..."
cd ${CUGRAPH_ROOT}/python
py.test --cache-clear --junitxml=${CUGRAPH_ROOT}/junit-cugraph.xml -v
