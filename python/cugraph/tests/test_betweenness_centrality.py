# Copyright (c) 2019-2020, NVIDIA CORPORATION.:
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

import pytest

import cugraph
from cugraph.tests import utils
import random
import numpy as np
import cupy

# Temporarily suppress warnings till networkX fixes deprecation warnings
# (Using or importing the ABCs from 'collections' instead of from
# 'collections.abc' is deprecated, and in 3.8 it will stop working) for
# python 3.7.  Also, this import networkx needs to be relocated in the
# third-party group once this gets fixed.
import warnings
with warnings.catch_warnings():
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    import networkx as nx

# NOTE: Endpoint parameter is not currently being tested, there could be a test
#       to verify that python raise an error if it is used
# =============================================================================
# Parameters
# =============================================================================
DIRECTED_GRAPH_OPTIONS = [False, True]
DEFAULT_EPSILON = 0.0001

TINY_DATASETS = ['../datasets/karate.csv']

UNRENUMBERED_DATASETS = ['../datasets/karate.csv']

SMALL_DATASETS = ['../datasets/netscience.csv']

SUBSET_SIZE_OPTIONS = [4]
SUBSET_SEED_OPTIONS = [42]

# NOTE: The following is not really being exploited in the tests as the
# datasets that are used are too small to compare, but it ensures that both
# path are actually sane
RESULT_DTYPE_OPTIONS = [np.float32, np.float64]


# =============================================================================
# Comparison functions
# =============================================================================
def calc_betweenness_centrality(graph_file, directed=True, normalized=False,
                                weight=None, endpoints=False,
                                k=None, seed=None,
                                result_dtype=np.float64):
    """ Generate both cugraph and networkx betweenness centrality

    Parameters
    ----------
    graph_file : string
        Path to COO Graph representation in .csv format

    directed : bool, optional, default=True

    normalized : bool
        True: Normalize Betweenness Centrality scores
        False: Scores are left unnormalized

    k : int or None, optional, default=None
        int:  Number of sources  to sample  from
        None: All sources are used to compute

    seed : int or None, optional, default=None
        Seed for random sampling  of the starting point

    Returns
    -------
        cu_bc : dict
            Each key is the vertex identifier, each value is the betweenness
            centrality score obtained from cugraph betweenness_centrality
        nx_bc : dict
            Each key is the vertex identifier, each value is the betweenness
            centrality score obtained from networkx betweenness_centrality
    """
    G, Gnx = utils.build_cu_and_nx_graphs(graph_file, directed=directed)
    calc_func = None
    if k is not None and seed is not None:
        calc_func = _calc_bc_subset
    elif k is not None:
        calc_func = _calc_bc_subset_fixed
    else:  # We processed to a comparison using every sources
        calc_func = _calc_bc_full
    sorted_df = calc_func(G, Gnx, normalized=normalized, weight=weight,
                          endpoints=endpoints, k=k, seed=seed,
                          result_dtype=result_dtype)

    return sorted_df


def _calc_bc_subset(G, Gnx, normalized, weight, endpoints, k, seed,
                    result_dtype):
    # NOTE: Networkx API does not allow passing a list of vertices
    # And the sampling is operated on Gnx.nodes() directly
    # We first mimic acquisition of the nodes to compare with same sources
    random.seed(seed)  # It will be called again in nx's call
    sources = random.sample(Gnx.nodes(), k)
    df = cugraph.betweenness_centrality(G, normalized=normalized,
                                        weight=weight,
                                        endpoints=endpoints,
                                        k=sources,
                                        result_dtype=result_dtype)
    nx_bc = nx.betweenness_centrality(Gnx, normalized=normalized, k=k,
                                      seed=seed)

    sorted_df = df.sort_values("vertex").rename({"betweenness_centrality":
                                                 "cu_bc"})

    sorted_df["ref_bc"] = [nx_bc[key] for key in sorted(nx_bc.keys())]

    return sorted_df


def _calc_bc_subset_fixed(G, Gnx, normalized, weight, endpoints, k, seed,
                          result_dtype):
    assert isinstance(k, int), "This test is meant for verifying coherence " \
                               "when k is given as an int"
    # In the fixed set we compare cu_bc against itself as we random.seed(seed)
    # on the same seed and then sample on the number of vertices themselves
    if seed is None:
        seed = 123  # random.seed(None) uses time, but we want same sources
    random.seed(seed)  # It will be called again in cugraph's call
    sources = random.sample(range(G.number_of_vertices()), k)
    # The first call is going to proceed to the random sampling in the same
    # fashion as the lines above
    df = cugraph.betweenness_centrality(G, k=k, normalized=normalized,
                                        weight=weight,
                                        endpoints=endpoints,
                                        seed=seed,
                                        result_dtype=result_dtype)
    # The second call is going to process source that were already sampled
    # We set seed to None as k : int, seed : not none should not be normal
    # behavior
    df2 = cugraph.betweenness_centrality(G, k=sources, normalized=normalized,
                                         weight=weight,
                                         endpoints=endpoints,
                                         seed=None,
                                         result_dtype=result_dtype)
    sorted_df = df.sort_values("vertex").rename({"betweenness_centrality":
                                                 "cu_bc"})
    sorted_df2 = df2.sort_values("vertex")

    sorted_df["ref_bc"] = sorted_df2["betweenness_centrality"]

    return sorted_df


def _calc_bc_full(G, Gnx, normalized, weight, endpoints,
                  k, seed,
                  result_dtype):
    df = cugraph.betweenness_centrality(G, normalized=normalized,
                                        weight=weight,
                                        endpoints=endpoints,
                                        result_dtype=result_dtype)
    assert df['betweenness_centrality'].dtype == result_dtype,  \
        "'betweenness_centrality' column has not the expected type"
    nx_bc = nx.betweenness_centrality(Gnx, normalized=normalized,
                                      weight=weight,
                                      endpoints=endpoints)

    sorted_df = df.sort_values("vertex").rename({"betweenness_centrality":
                                                 "cu_bc"})

    sorted_df["ref_bc"] = [nx_bc[key] for key in sorted(nx_bc.keys())]

    return sorted_df


# =============================================================================
# Utils
# =============================================================================
# NOTE: We assume that both column are ordered in such way that values
#        at ith positions are expected to be compared in both columns
# i.e: sorted_df[idx][first_key] should be compared to
#      sorted_df[idx][second_key]
def compare_scores(sorted_df, first_key, second_key, epsilon=DEFAULT_EPSILON):
    errors = sorted_df[~cupy.isclose(sorted_df[first_key],
                                     sorted_df[second_key],
                                     rtol=epsilon)]
    num_errors = len(errors)
    if num_errors > 0:
        print(errors)
    assert num_errors == 0, \
        "Mismatch were found when comparing '{}' and '{}' (rtol = {})" \
        .format(first_key, second_key, epsilon)


def prepare_test():
    gc.collect()


# =============================================================================
# Tests
# =============================================================================
@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_tiny(graph_file,
                                                directed,
                                                result_dtype):
    """Test Normalized Betweenness Centrality"""
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file, directed=directed,
                                            normalized=True,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_unnormalized_tiny(graph_file,
                                                  directed,
                                                  result_dtype):
    """Test Unnormalized Betweenness Centrality"""
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file, directed=directed,
                                            normalized=False,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', SMALL_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_small(graph_file,
                                                 directed,
                                                 result_dtype):
    """Test Unnormalized Betweenness Centrality"""
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file, directed=directed,
                                            normalized=True,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', SMALL_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_unnormalized_small(graph_file,
                                                   directed,
                                                   result_dtype):
    """Test Unnormalized Betweenness Centrality"""
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file, directed=directed,
                                            normalized=False,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', SMALL_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('subset_size', SUBSET_SIZE_OPTIONS)
@pytest.mark.parametrize('subset_seed', SUBSET_SEED_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_subset_small(graph_file,
                                                        directed,
                                                        subset_size,
                                                        subset_seed,
                                                        result_dtype):
    """Test Unnormalized Betweenness Centrality using a subset

    Only k sources are considered for an approximate Betweenness Centrality
    """
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file,
                                            directed=directed,
                                            normalized=True,
                                            k=subset_size,
                                            seed=subset_seed,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


# NOTE: This test should only be execute on unrenumbered datasets
#       the function operating the comparison inside is first proceeding
#       to a random sampling over the number of vertices (thus direct offsets)
#       in the graph structure instead of actual vertices identifiers
@pytest.mark.parametrize('graph_file', UNRENUMBERED_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('subset_size', SUBSET_SIZE_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_fixed_sample(graph_file,
                                                        directed,
                                                        subset_size,
                                                        result_dtype):
    """Test Unnormalized Betweenness Centrality using a subset

    Only k sources are considered for an approximate Betweenness Centrality
    """
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file,
                                            directed=directed,
                                            normalized=True,
                                            k=subset_size,
                                            seed=None,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', SMALL_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('subset_size', SUBSET_SIZE_OPTIONS)
@pytest.mark.parametrize('subset_seed', SUBSET_SEED_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_unnormalized_subset_small(graph_file,
                                                          directed,
                                                          subset_size,
                                                          subset_seed,
                                                          result_dtype):
    """Test Unnormalized Betweenness Centrality on Graph on subset

    Only k sources are considered for an approximate Betweenness Centrality
    """
    prepare_test()
    sorted_df = calc_betweenness_centrality(graph_file,
                                            directed=directed,
                                            normalized=False,
                                            k=subset_size,
                                            seed=subset_seed,
                                            result_dtype=result_dtype)
    compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_unnormalized_endpoints_except(graph_file,
                                                              directed,
                                                              result_dtype):
    """Test calls betwenness_centrality unnormalized + endpoints"""
    prepare_test()
    with pytest.raises(NotImplementedError):
        sorted_df = calc_betweenness_centrality(graph_file,
                                                normalized=False,
                                                endpoints=True,
                                                directed=directed,
                                                result_dtype=result_dtype)
        compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_endpoints_except(graph_file,
                                                            directed,
                                                            result_dtype):
    """Test calls betwenness_centrality normalized + endpoints"""
    prepare_test()
    with pytest.raises(NotImplementedError):
        sorted_df = calc_betweenness_centrality(graph_file,
                                                normalized=True,
                                                endpoints=True,
                                                directed=directed,
                                                result_dtype=result_dtype)
        compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_unnormalized_weight_except(graph_file,
                                                           directed,
                                                           result_dtype):
    """Test calls betwenness_centrality unnormalized + weight"""
    prepare_test()
    with pytest.raises(NotImplementedError):
        sorted_df = calc_betweenness_centrality(graph_file,
                                                normalized=False,
                                                weight=True,
                                                directed=directed,
                                                result_dtype=result_dtype)
        compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
@pytest.mark.parametrize('result_dtype', RESULT_DTYPE_OPTIONS)
def test_betweenness_centrality_normalized_weight_except(graph_file,
                                                         directed,
                                                         result_dtype):
    """Test calls betwenness_centrality normalized + weight"""
    prepare_test()
    with pytest.raises(NotImplementedError):
        sorted_df = calc_betweenness_centrality(graph_file,
                                                normalized=True,
                                                weight=True,
                                                directed=directed,
                                                result_dtype=result_dtype)
        compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")


@pytest.mark.parametrize('graph_file', TINY_DATASETS)
@pytest.mark.parametrize('directed', DIRECTED_GRAPH_OPTIONS)
def test_betweenness_centrality_invalid_dtype(graph_file, directed):
    """Test calls betwenness_centrality normalized + weight"""
    prepare_test()
    with pytest.raises(TypeError):
        sorted_df = calc_betweenness_centrality(graph_file,
                                                normalized=True,
                                                result_dtype=str,
                                                directed=directed)
        compare_scores(sorted_df, first_key="cu_bc", second_key="ref_bc")
