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


#ifndef WORKER_KERNELS_CUH
#define WORKER_KERNELS_CUH

#include "vertex_binning.cuh"
#include "graph_csr_device_view.cuh"
#include <graph.hpp>

namespace detail {

namespace opg {

template <typename VT, typename ET, typename WT, typename Operator>
__global__ void kernel_per_vertex_worker_weightless(
    GraphCSRDeviceView<VT, ET, WT> graph,
    VT *vertex_ids,
    VT number_of_vertices,
    Operator op) {
  VT current_vertex_index = 0;
  ET tid = threadIdx.x + (blockIdx.x * blockDim.x);
  ET stride = blockDim.x*gridDim.x;

  while (current_vertex_index < number_of_vertices) {
    VT source = vertex_ids[current_vertex_index];
    ET offset_begin = graph.offsets()[source];
    ET offset_end = graph.offsets()[source+1];
    for (ET edge_index = tid + offset_begin;
        edge_index < offset_end;
        edge_index += stride) {
      op(source, graph.indices()[edge_index]);
    }
    current_vertex_index++;
  }
}

template <typename VT, typename ET, typename WT, typename Operator>
void large_vertex_worker(
    cugraph::experimental::GraphCSRView<VT, ET, WT>& graph,
    DegreeBucket<VT, ET>& bucket,
    Operator op,
    cudaStream_t stream) {
  GraphCSRDeviceView<VT, ET, WT> graph_device_view(graph);
  int block_size = 32;
  int block_count = 1024;
  if (bucket.numberOfVertices != 0) {
    kernel_per_vertex_worker_weightless<<<block_count,block_size,0,stream>>>(
        graph_device_view,
        bucket.vertexIds,
        bucket.numberOfVertices,
        op);
  }
}

template <typename VT, typename ET, typename WT, typename Operator>
__global__ void block_per_vertex_worker_weightless(
    GraphCSRDeviceView<VT, ET, WT> graph,
    VT *vertex_ids,
    VT number_of_vertices,
    Operator op) {
  VT current_vertex_index = blockIdx.x;
  if (current_vertex_index >= number_of_vertices) {
    return;
  }

  VT source = vertex_ids[current_vertex_index];
  for (ET edge_index = threadIdx.x + graph.offsets()[source];
      edge_index < graph.offsets()[source+1];
      edge_index += blockDim.x) {
    op(source, graph.indices()[edge_index]);
  }

}

template <typename VT, typename ET, typename WT, typename Operator>
void medium_vertex_worker(
    cugraph::experimental::GraphCSRView<VT, ET, WT>& graph,
    DegreeBucket<VT, ET>& bucket,
    Operator op,
    cudaStream_t stream) {
  GraphCSRDeviceView<VT, ET, WT> graph_device_view(graph);
  int block_size = 1024;
  int block_count = bucket.numberOfVertices;
  if (block_count != 0) {
    block_per_vertex_worker_weightless<<<block_count,block_size,0,stream>>>(
        graph_device_view,
        bucket.vertexIds,
        bucket.numberOfVertices,
        op);
  }
}

template <typename VT, typename ET, typename WT, typename Operator>
void small_vertex_worker(
    cugraph::experimental::GraphCSRView<VT, ET, WT>& graph,
    DegreeBucket<VT, ET>& bucket,
    Operator op,
    cudaStream_t stream) {
  GraphCSRDeviceView<VT, ET, WT> graph_device_view(graph);
  int block_size = 512;
  if (bucket.ceilLogDegreeEnd < 6)        { block_size =  32; }
  else if (bucket.ceilLogDegreeEnd <  8)  { block_size =  64; }
  else if (bucket.ceilLogDegreeEnd < 10)  { block_size = 128; }
  else if (bucket.ceilLogDegreeEnd < 12)  { block_size = 512; }
  int block_count = bucket.numberOfVertices;
  if (block_count != 0) {
    block_per_vertex_worker_weightless<<<block_count,block_size,0,stream>>>(
        graph_device_view,
        bucket.vertexIds,
        bucket.numberOfVertices,
        op);
  }
}

}//namespace opg

}//namespace detail

#endif //WORKER_KERNELS_CUH
