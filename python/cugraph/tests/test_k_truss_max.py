# Copyright (c) 2019, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import gc
from itertools import product

import pytest

import pandas as pd
import cugraph
from cugraph.tests import utils
from cugraph.structure import symmetrize 
import cudf

import rmm
from rmm import rmm_config
import networkx as nx

# Temporarily suppress warnings till networkX fixes deprecation warnings
# (Using or importing the ABCs from 'collections' instead of from
# 'collections.abc' is deprecated, and in 3.8 it will stop working) for
# python 3.7.  Also, this import networkx needs to be relocated in the
# third-party group once this gets fixed.
import warnings
with warnings.catch_warnings():
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    import networkx as nx


print('Networkx version : {} '.format(nx.__version__))

def networkx_k_truss_max(graph_file):
    NM = utils.read_csv_for_nx(graph_file)
    NM = NM.tocsr()

    k=3;
    Gnx = nx.Graph(NM)
    Gnx = Gnx.to_undirected()

    while(not nx.is_empty(Gnx)):
        Gnx = nx.k_truss(Gnx,k)
        k=k+1
    k=k-2;

    return k



def cugraph_k_truss_max(graph_file):
    cu_M = utils.read_csv_file(graph_file)

    src, dst = cugraph.symmetrize(cu_M['0'], cu_M['1'])

    G = cugraph.Graph()
    G.add_edge_list(src, dst)

    k_max = cugraph.ktruss_max(G)

    return k_max



def compare_k_truss(graph_file):
    k_truss_cugraph = cugraph_k_truss_max(graph_file)
    k_truss_nx      = networkx_k_truss_max(graph_file)

    assert (k_truss_cugraph==k_truss_nx)



DATASETS = ['../datasets/dolphins.csv',
            '../datasets/netscience.csv']


@pytest.mark.parametrize('managed, pool',
                         list(product([False, True], [False])))
@pytest.mark.parametrize('graph_file', DATASETS)
def test_ktruss_max(managed, pool, graph_file):
    gc.collect()

    rmm.finalize()
    rmm_config.use_managed_memory = managed
    rmm_config.use_pool_allocator = pool
    rmm.initialize()

    assert(rmm.is_initialized())

    compare_k_truss(graph_file)

    # print(kmax)

    # assert cn['cu_core_number'].equals(cn['nx_core_number'])
