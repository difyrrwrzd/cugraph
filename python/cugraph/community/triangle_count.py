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

from cugraph.community import triangle_count_wrapper
from cugraph.structure.graph import Graph


def triangles(G):
    """
    Compute the number of triangle (cycles of length three) in the
    input graph.

    Parameters
    ----------
    G : cugraph.graph
        cuGraph graph descriptor, should contain the connectivity information,
        (edge weights are not used in this algorithm)

    Returns
    -------
    count : int64
        A 64 bit integer whose value gives the number of triangles in the
        graph.

    Examples
    --------
    >>> gdf = cudf.read_csv('datasets/karate.csv',
                          delimiter = ' ',
                          dtype=['int32', 'int32', 'float32'],
                          header=None)
    >>> G = cugraph.Graph()
    >>> G.from_cudf_edgelist(gdf, source='0', destination='1')
    >>> count = cugraph.triangles(G)
    """

    if type(G) is not Graph:
        raise Exception("input graph must be undirected")

    result = triangle_count_wrapper.triangles(G)

    return result
