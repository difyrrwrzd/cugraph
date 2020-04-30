# Copyright (c) 2019-2020, NVIDIA CORPORATION.
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
import queue
import time

import numpy as np
import pytest
import scipy
import cugraph
from cugraph.tests import utils
import rmm
import random

# Temporarily suppress warnings till networkX fixes deprecation warnings
# (Using or importing the ABCs from 'collections' instead of from
# 'collections.abc' is deprecated, and in 3.8 it will stop working) for
# python 3.7.  Also, this import networkx needs to be relocated in the
# third-party group once this gets fixed.
import warnings
with warnings.catch_warnings():
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    import networkx as nx
    import networkx.algorithms.centrality.betweenness as nxacb

# =============================================================================
# Parameters
# =============================================================================
RMM_MANAGED_MEMORY_OPTIONS = [False, True]
RMM_POOL_ALLOCATOR_OPTIONS = [False, True]

DIRECTED_GRAPH_OPTIONS = [True]

TINY_DATASETS = ['../datasets/karate.csv',
                 '../datasets/dolphins.csv',
                 '../datasets/polbooks.csv']
SMALL_DATASETS = ['../datasets/netscience.csv',
                  '../datasets/email-Eu-core.csv']

DATASETS = TINY_DATASETS + SMALL_DATASETS

SUBSET_SEED_OPTIONS = [42]

DEFAULT_EPSILON = 1e-6


# =============================================================================
# Utils
# =============================================================================
def prepare_rmm(managed_memory, pool_allocator, **kwargs):
    gc.collect()
    rmm.reinitialize(
        managed_memory=managed_memory,
        pool_allocator=pool_allocator,
        **kwargs
    )
    assert rmm.is_initialized()


# TODO: This is also present in test_betweenness_centrality.py
#       And it could probably be used in SSSP also
def build_graphs(graph_file, directed=True):
    # cugraph
    cu_M = utils.read_csv_file(graph_file)
    G = cugraph.DiGraph() if directed else cugraph.Graph()
    G.from_cudf_edgelist(cu_M, source='0', destination='1')
    G.view_adj_list()  # Enforce CSR generation before computation

    # networkx
    M = utils.read_csv_for_nx(graph_file)
    Gnx = nx.from_pandas_edgelist(M, create_using=(nx.DiGraph() if directed
                                                   else nx.Graph()),
                                  source='0', target='1')
    return G, Gnx


# =============================================================================
# Functions for comparison
# =============================================================================
# NOTE: We need to use relative error, the values of the shortest path
# counters can reach extremely high values 1e+80 and above
def compare_single_sp_counter(result, expected, epsilon=DEFAULT_EPSILON):
    return np.isclose(result, expected, rtol=epsilon)


def compare_bfs(graph_file, directed=True, return_sp_counter=False,
                seed=42):
    """ Genereate both cugraph and reference bfs traversal

    Parameters
    -----------
    graph_file : string
        Path to COO Graph representation in .csv format

    directed : bool, optional, default=True
        Indicated wheter the graph is directed or not

    return_sp_counter : bool, optional, default=False
        Retrun shortest path counters from traversal if True

    seed : int, optional, default=42
        Value for random seed to obtain starting vertex

    Returns
    -------
    """
    G, Gnx = build_graphs(graph_file, directed)
    # Seed for reproductiblity
    if isinstance(seed, int):
        random.seed(seed)
        start_vertex = random.sample(Gnx.nodes(), 1)[0]

        # Test for  shortest_path_counter
        compare_func = _compare_bfs_spc if return_sp_counter else _compare_bfs

        # NOTE: We need to take 2 differnt path for verification as the nx
        #       functions used as reference return dictionnaries that might
        #       not contain all the vertices while the cugraph version return
        #       a cudf.DataFrame with all the vertices, also some verification
        #       become slow with the data transfer
        compare_func(G, Gnx, start_vertex, directed)
    elif isinstance(seed, list):  # For other Verifications
        for start_vertex in seed:
            compare_func = _compare_bfs_spc if return_sp_counter else \
                           _compare_bfs
            compare_func(G, Gnx, start_vertex, directed)
    elif seed is None:  # Same here, it is only to run full checks
        for start_vertex in Gnx:
            compare_func = _compare_bfs_spc if return_sp_counter else \
                           _compare_bfs
            compare_func(G, Gnx, start_vertex, directed)
    else:  # Unknown type given to seed
        raise NotImplementedError("Invalid type for seed")


def _compare_bfs(G,  Gnx, source, directed):
    df = cugraph.bfs(G, source, directed=directed,
                     return_sp_counter=False)
    # This call should only contain 3 columns:
    # 'vertex', 'distance', 'predecessor'
    # It also confirms wether or not 'sp_counter' has been created by the call
    # 'sp_counter' triggers atomic operations in BFS, thus we want to make
    # sure that it was not the case
    # NOTE: 'predecessor' is always returned while the C++ function allows to
    # pass a nullptr
    assert len(df.columns) == 3, "The result of the BFS has an invalid " \
                                 "number of columns"
    cu_distances = {vertex: dist for vertex, dist in
                    zip(df['vertex'].to_array(), df['distance'].to_array())}
    cu_predecessors = {vertex: dist for vertex, dist in
                       zip(df['vertex'].to_array(),
                           df['predecessor'].to_array())}
    nx_distances = nx.single_source_shortest_path_length(Gnx, source)
    # TODO: The following only verifies vertices that were reached
    #       by cugraph's BFS.
    # We assume that the distances are ginven back as integers in BFS
    max_val = np.iinfo(df['distance'].dtype).max
    # Unreached vertices have a distance of max_val

    missing_vertex_error = 0
    distance_mismatch_error = 0
    invalid_predrecessor_error = 0
    for vertex in nx_distances:
        if vertex in cu_distances:
            result = cu_distances[vertex]
            expected = nx_distances[vertex]
            if (result != expected):
                print("[ERR] Mismatch on distances: "
                      "vid = {}, cugraph = {}, nx = {}".format(vertex,
                                                               result,
                                                               expected))
                distance_mismatch_error += 1
            pred = cu_predecessors[vertex]
            # The graph is unwehigted thus, predecessors are 1 away
            if (vertex != source and (nx_distances[pred] + 1 !=
                                      cu_distances[vertex])):
                print("[ERR] Invalid on predecessors: "
                      "vid = {}, cugraph = {}".format(vertex, pred))
                invalid_predrecessor_error += 1
        elif cu_distance[vertex] != max_val:
            missing_vertex_error += 1
    assert missing_vertex_error == 0, "There are missing vertices"
    assert distance_mismatch_error == 0, "There are invalid distances"
    assert invalid_predrecessor_error == 0, "There are invalid predecessors"


def _compare_bfs_spc(G, Gnx, source, directed):
    df = cugraph.bfs(G, source, directed=directed,
                     return_sp_counter=True)
    cu_sp_counter = {vertex: dist for vertex, dist in
                     zip(df['vertex'].to_array(), df['sp_counter'].to_array())}
    # This call should only contain 3 columns:
    # 'vertex', 'distance', 'predecessor', 'sp_counter'
    assert len(df.columns) == 4, "The result of the BFS has an invalid " \
                                 "number of columns"
    _, _, nx_sp_counter = nxacb._single_source_shortest_path_basic(Gnx,
                                                                   source)
    # We are not checking for distances / predecessors here as we assume
    # that these have been checked  in the _compare_bfs tests
    # We focus solely on shortest path counting
    # NOTE:(as 04/29/2020) The networkx implementation generates a dict with
    # all the vertices thus we check for all of them
    missing_vertex_error = 0
    shortest_path_counter_errors = 0
    for vertex in nx_sp_counter:
        if vertex in cu_sp_counter:
            result = cu_sp_counter[vertex]
            expected = cu_sp_counter[vertex]
            if not compare_single_sp_counter(result, expected):
                print("[ERR] Mismatch on shortest paths: "
                      "vid = {}, cugraph = {}, nx = {}".format(vertex,
                                                               result,
                                                               expected))
                shortest_path_counter_errors += 1
        else:
            missing_vertex_error += 1
    assert missing_vertex_error == 0, "There are missing vertices"
    assert shortest_path_counter_errors == 0, "Shortest path counters are " \
                                              "too different"


# =============================================================================
# Tests
# =============================================================================
# Test all combinations of default/managed and pooled/non-pooled allocation
@pytest.mark.parametrize('managed, pool',
                         list(product(RMM_MANAGED_MEMORY_OPTIONS,
                                      RMM_POOL_ALLOCATOR_OPTIONS)))
@pytest.mark.parametrize('graph_file', DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('seed', SUBSET_SEED_OPTIONS)
def test_bfs(managed, pool, graph_file, directed, seed):
    """Test BFS traversal on random source with distance and predecessors"""
    prepare_rmm(managed_memory=managed, pool_allocator=pool,
                initial_pool_size=2 << 27)
    compare_bfs(graph_file, directed=directed, return_sp_counter=False,
                seed=seed)


@pytest.mark.parametrize('managed, pool',
                         list(product(RMM_MANAGED_MEMORY_OPTIONS,
                                      RMM_POOL_ALLOCATOR_OPTIONS)))
@pytest.mark.parametrize('graph_file', DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('seed', SUBSET_SEED_OPTIONS)
def test_bfs_spc(managed, pool, graph_file, directed, seed):
    """Test BFS traversal on random source with shortest path counting"""
    prepare_rmm(managed_memory=managed, pool_allocator=pool,
                initial_pool_size=2 << 27)
    compare_bfs(graph_file, directed=directed, return_sp_counter=True,
                seed=seed)


@pytest.mark.parametrize('managed, pool',
                         list(product(RMM_MANAGED_MEMORY_OPTIONS,
                                      RMM_POOL_ALLOCATOR_OPTIONS)))
@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
def test_bfs_spc_full(managed, pool, graph_file, directed):
    """Test BFS traversal on every vertex with shortest path counting"""
    prepare_rmm(managed_memory=managed, pool_allocator=pool,
                initial_pool_size=2 << 27)
    compare_bfs(graph_file, directed=directed, return_sp_counter=True,
                seed=None)
