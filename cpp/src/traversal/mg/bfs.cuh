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

#pragma once

#include <raft/handle.hpp>
#include "../traversal_common.cuh"
#include "common_utils.cuh"
#include "frontier_expand.cuh"

namespace cugraph {

namespace mg {

namespace detail {

template <typename vertex_t, typename edge_t, typename weight_t, typename operator_t>
void bfs_traverse(raft::handle_t const &handle,
                  cugraph::GraphCSRView<vertex_t, edge_t, weight_t> const &graph,
                  const vertex_t start_vertex,
                  rmm::device_vector<uint32_t> &visited_bmap,
                  rmm::device_vector<uint32_t> &output_frontier_bmap,
                  operator_t &bfs_op)
{
  // Frontiers required for BFS
  rmm::device_vector<vertex_t> input_frontier(graph.number_of_vertices);
  rmm::device_vector<vertex_t> output_frontier(graph.number_of_vertices);

  // Bitmaps required for BFS
  size_t word_count = detail::number_of_words(graph.number_of_vertices);
  rmm::device_vector<uint32_t> isolated_bmap(word_count, 0);
  rmm::device_vector<uint32_t> unique_bmap(word_count, 0);
  rmm::device_vector<size_t> temp_buffer_len(handle.get_comms().get_size());

  // Reusing buffers to create isolated bitmap
  {
    rmm::device_vector<vertex_t> &local_isolated_ids  = input_frontier;
    rmm::device_vector<vertex_t> &global_isolated_ids = output_frontier;
    detail::create_isolated_bitmap(
      handle, graph, local_isolated_ids, global_isolated_ids, temp_buffer_len, isolated_bmap);
  }

  // Frontier Expand for calls to bfs functors
  detail::FrontierExpand<vertex_t, edge_t, weight_t> fexp(handle, graph);

  cudaStream_t stream = handle.get_stream();

  // Initialize input frontier
  input_frontier[0]           = start_vertex;
  vertex_t input_frontier_len = 1;

  do {
    // Mark all input frontier vertices as visited
    detail::add_to_bitmap(handle, visited_bmap, input_frontier, input_frontier_len);

    bfs_op.increment_level();

    // Remove duplicates,isolated and out of partition vertices
    // from input_frontier and store it to output_frontier
    input_frontier_len = detail::preprocess_input_frontier(handle,
                                                           graph,
                                                           unique_bmap,
                                                           isolated_bmap,
                                                           input_frontier,
                                                           input_frontier_len,
                                                           output_frontier);
    // Swap input and output frontier
    input_frontier.swap(output_frontier);

    // Clear output frontier bitmap
    thrust::fill(rmm::exec_policy(stream)->on(stream),
                 output_frontier_bmap.begin(),
                 output_frontier_bmap.end(),
                 static_cast<uint32_t>(0));

    // Generate output frontier bitmap from input frontier
    vertex_t output_frontier_len =
      fexp(bfs_op, input_frontier, input_frontier_len, output_frontier);

    // Collect output_frontier from all ranks to input_frontier
    // If not empty then we proceed to next iteration.
    // Note that its an error to remove duplicates and non local
    // start vertices here since it is possible that doing so will
    // result in input_frontier_len to be 0. That would cause some
    // ranks to go ahead with the iteration and some to terminate.
    // This would further cause a nccl communication error since
    // not every rank participates in broadcast/allgather in
    // subsequent calls
    input_frontier_len = detail::collect_vectors(
      handle, temp_buffer_len, output_frontier, output_frontier_len, input_frontier);

  } while (input_frontier_len != 0);
}

}  // namespace detail

template <typename vertex_t, typename edge_t, typename weight_t>
void bfs(raft::handle_t const &handle,
         cugraph::GraphCSRView<vertex_t, edge_t, weight_t> const &graph,
         vertex_t *distances,
         vertex_t *predecessors,
         const vertex_t start_vertex)
{
  CUGRAPH_EXPECTS(handle.comms_initialized(),
                  "cugraph::mg::bfs() expected to work only in multi gpu case.");

  size_t word_count = detail::number_of_words(graph.number_of_vertices);
  rmm::device_vector<uint32_t> visited_bmap(word_count, 0);
  rmm::device_vector<uint32_t> output_frontier_bmap(word_count, 0);

  cudaStream_t stream = handle.get_stream();

  // Set all predecessors to be invalid vertex ids
  thrust::fill(rmm::exec_policy(stream)->on(stream),
               predecessors,
               predecessors + graph.number_of_vertices,
               cugraph::invalid_idx<vertex_t>::value);

  if (distances == nullptr) {
    detail::BFSStepNoDist<vertex_t, edge_t> bfs_op(
      output_frontier_bmap.data().get(), visited_bmap.data().get(), predecessors);

    detail::bfs_traverse(handle, graph, start_vertex, visited_bmap, output_frontier_bmap, bfs_op);

  } else {
    // Update distances to max distances everywhere except start_vertex
    // where it is set to 0
    detail::fill_max_dist(handle, graph, start_vertex, distances);

    detail::BFSStep<vertex_t, edge_t> bfs_op(
      output_frontier_bmap.data().get(), visited_bmap.data().get(), predecessors, distances);

    detail::bfs_traverse(handle, graph, start_vertex, visited_bmap, output_frontier_bmap, bfs_op);

    // In place reduce to collect distances
    if (handle.comms_initialized()) {
      handle.get_comms().allreduce(
        distances, distances, graph.number_of_vertices, raft::comms::op_t::MIN, stream);
    }
  }

  // In place reduce to collect predecessors
  if (handle.comms_initialized()) {
    handle.get_comms().allreduce(
      predecessors, predecessors, graph.number_of_vertices, raft::comms::op_t::MIN, stream);
  }
}

}  // namespace mg

}  // namespace cugraph
