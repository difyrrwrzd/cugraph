/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <graph.hpp>
#include <algorithms.hpp>

#include <rmm/thrust_rmm_allocator.h>

#include <utilities/error_utils.h>
#include <utilities/cuda_utils.cuh>

namespace {

  template <typename vertex_t, typename edge_t, typename weight_t, bool has_weight>
  void extract_subgraph_by_vertices(cugraph::experimental::GraphCOO<vertex_t, edge_t, weight_t> const &graph,
                                    vertex_t const *vertices,
                                    vertex_t num_vertices,
                                    cugraph::experimental::GraphCOO<vertex_t, edge_t, weight_t> &result,
                                    cudaStream_t stream) {

    rmm::device_vector<int64_t> error_count_v{1, 0};
    rmm::device_vector<vertex_t> vertex_used_v{num_vertices, num_vertices};

    vertex_t *d_vertex_used = vertex_used_v.data().get();
    int64_t  *d_error_count = error_count_v.data().get();
    edge_t    graph_num_verts = graph.number_of_vertices;

    thrust::for_each(rmm::exec_policy(stream)->on(stream),
                     thrust::make_counting_iterator<vertex_t>(0),
                     thrust::make_counting_iterator<vertex_t>(num_vertices),
                     [vertices, d_vertex_used, d_error_count, graph_num_verts]
                     __device__ (vertex_t idx) {
                       vertex_t v = vertices[idx];
                       if ((v >= 0) && (v < graph_num_verts))
                         d_vertex_used[v] = idx;
                       else
                         cugraph::atomicAdd(d_error_count, int64_t{1});
                     });

    CUGRAPH_EXPECTS(error_count_v[0] > 0, "Input error... vertices specifies vertex id out of range");

    vertex_t *graph_src = graph.src_indices;
    vertex_t *graph_dst = graph.dst_indices;
    weight_t *graph_weight = graph.edge_data;

    // iterate over the edges and count how many make it into the output
    int64_t count = thrust::count_if(rmm::exec_policy(stream)->on(stream),
                                     thrust::make_counting_iterator<edge_t>(0),
                                     thrust::make_counting_iterator<edge_t>(graph.number_of_edges),
                                     [graph_src, graph_dst, d_vertex_used, num_vertices]
                                     __device__ (edge_t e) {
                                       vertex_t s = graph_src[e];
                                       vertex_t d = graph_dst[e];
                                       return ((d_vertex_used[s] < num_vertices) && (d_vertex_used[d] < num_vertices));
                                     });

    if (count > 0) {
      rmm::device_vector<vertex_t> new_src_v(count);
      rmm::device_vector<vertex_t> new_dst_v(count);
      rmm::device_vector<weight_t> new_weight_v;

      vertex_t *d_new_src = new_src_v.data().get();
      vertex_t *d_new_dst = new_dst_v.data().get();
      weight_t *d_new_weight = nullptr;

      if (has_weight) {
        new_weight_v.resize(count);
        d_new_weight = new_weight_v.data().get();
      }

      //  reusing error_count as a vertex counter...
      thrust::for_each(rmm::exec_policy(stream)->on(stream),
                       thrust::make_counting_iterator<edge_t>(0),
                       thrust::make_counting_iterator<edge_t>(graph.number_of_edges),
                       [graph_src, graph_dst, graph_weight, d_vertex_used, num_vertices,
                        d_error_count, d_new_src, d_new_dst, d_new_weight]
                       __device__ (edge_t e) {
                         vertex_t s = graph_src[e];
                         vertex_t d = graph_dst[e];
                         if ((d_vertex_used[s] < num_vertices) && (d_vertex_used[d] < num_vertices)) {
                           //  NOTE: Could avoid atomic here by doing a inclusive sum, but that would
                           //     require 2*|E| temporary memory.  If this becomes important perhaps
                           //     we make 2 implementations and pick one based on the number of vertices
                           //     in the subgraph set.
                           auto pos = cugraph::atomicAdd(d_error_count, 1);
                           d_new_src[pos] = s;
                           d_new_dst[pos] = d;
                           if (has_weight)
                             d_new_weight[pos] = graph_weight[e];
                         }
                       });
      
      //
      //  Need to return rmm::device_vectors
      //

    } else {
      // return an empty graph
    }
  }
} //namespace anonymous


namespace cugraph {
namespace nvgraph {

template <typename VT, typename ET, typename WT>
void extract_subgraph_vertex(experimental::GraphCOO<VT, ET, WT> const &graph,
                             VT const *vertices,
                             VT num_vertices,
                             experimental::GraphCOO<VT, ET, WT> &result) {

  CUGRAPH_EXPECTS(vertices != nullptr, "API error, vertices must be non null");
  
  cudaStream_t stream{0};

  if (graph.edge_data == nullptr) {
    extract_subgraph_by_vertices<VT,ET,WT,false>(graph, vertices, num_vertices, result, stream);
  } else {
    extract_subgraph_by_vertices<VT,ET,WT,true>(graph, vertices, num_vertices, result, stream);
  }
}

template void extract_subgraph_vertex<int32_t,int32_t,float>(experimental::GraphCOO<int32_t, int32_t, float> const &, int32_t const *, int32_t, experimental::GraphCOO<int32_t, int32_t, float> &);
template void extract_subgraph_vertex<int32_t,int32_t,double>(experimental::GraphCOO<int32_t, int32_t, double> const &, int32_t const *, int32_t, experimental::GraphCOO<int32_t, int32_t, double> &);

} //namespace nvgraph
} //namespace cugraph

