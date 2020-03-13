# Copyright (c) 2019, NVIDIA CORPORATION.
#aLicensed under the Apache License, Version 2.0 (the "License");
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

from cugraph.layout import force_atlas2_wrapper
from cugraph.structure.graph import Graph


def force_atlas2(input_graph,
                 max_iter=1000,
                 pos_list=None,
                 outbound_attraction_distribution=True,
                 lin_log_mode=False,
                 prevent_overlapping=False,
                 edge_weight_influence=1.0,
                 jitter_tolerance=1.0,
                 barnes_hut_theta=0.5,
                 scaling_ratio=2.0,
                 strong_gravity_mode=False,
                 gravity=1.0):

	"""
        ForceAtlas2 is a continuous graph layout algorithm for handy network
        visualization.

	Parameters
	----------
	input_graph : cugraph.Graph
	cuGraph graph descriptor, should contain the connectivity information
	as an edge list.
	The adjacency list will be computed if not already present. The graph
	should be undirected where an undirected edge is represented by a
	directed edge in both direction.

	max_iter : integer
	    This controls the maximum number of levels/iterations of the Force Atlas
	    algorithm. When specified the algorithm will terminate after no more
	    than the specified number of iterations. No error occurs when the
	    algorithm terminates early in this manner.
        pos_list: cudf.Series
            Dictionary of initial positions indexed by vertex id.
        gravity : float
            Attracts nodes to the center. Prevents islands from drifting away.
        scaling_ratio: : float
            How much repulsion you want. More makes a more sparse graph.
	edge_weight_influence: float
            How much influence you give to the edges weight. 0 is “no influence” and 1 is “normal”.
	    lin_log_mode: bool
        prevent_overlapping:
        lin_log_mode: bool
            Switch ForceAtlas model from lin-lin to lin-log. Makes clusters more tight.
        prevent_overlapping: bool
            

	Returns
	-------
	pos : cudf.DataFrame
	    GPU data frame of size V containing two columns the x and y positions
            indexed by vertex id

	"""

	pos = force_atlas2_wrapper.force_atlas2(input_graph,
						max_iter=max_iter,
                                                pos_list=pos_list,
						gravity=gravity,
						scaling_ratio=scaling_ratio,
                                                barnes_hut_theta=barnes_hut_theta,
						edge_weight_influence=edge_weight_influence,
                                                lin_log_mode=lin_log_mode,
                                                prevent_overlapping=prevent_overlapping)
	return pos
