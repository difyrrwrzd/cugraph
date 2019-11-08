/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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

/**
 * ---------------------------------------------------------------------------*
 * @brief KTruss implementation
 *
 * @file ktruss.cu
 * --------------------------------------------------------------------------*/


#include <cugraph.h>
#include "utilities/error_utils.h"
#include <Hornet.hpp>
#include "Static/KTruss/KTruss.cuh"
#include <StandardAPI.hpp>
#include <rmm_utils.h>
#include <nvgraph_gdf.h>

using namespace hornets_nest;

gdf_error ktruss_max_impl(gdf_graph *graph,
                          int *k_max) {
  gdf_error err = gdf_add_adj_list(graph);
  if (err != GDF_SUCCESS)
    return err;
  int * src = static_cast<int*>(graph->edgeList->src_indices->data);
  int * dst = static_cast<int*>(graph->edgeList->dest_indices->data);
  using HornetGraph = hornet::gpu::Hornet<int>;
  using UpdatePtr   = ::hornet::BatchUpdatePtr<int, hornet::EMPTY, hornet::DeviceType::DEVICE>;
  using Update      = ::hornet::gpu::BatchUpdate<int>;

  UpdatePtr ptr(graph->edgeList->src_indices->size, src, dst);
  Update batch(ptr);
  HornetGraph hnt(graph->numberOfVertices);
  hnt.insert(batch);
  //Use hornet

/*
  int *h_tempOffset,*h_tempIndices;
  h_tempOffset = (int*)malloc((graph->numberOfVertices+1)*sizeof(int));
  h_tempIndices = (int*)malloc((graph->adjList->indices->size)*sizeof(int));

  cudaMemcpy(h_tempOffset,static_cast<int*>(graph->adjList->offsets->data),(graph->numberOfVertices+1)*sizeof(int),cudaMemcpyDeviceToHost);
  cudaMemcpy(h_tempIndices,static_cast<int*>(graph->adjList->indices->data),(graph->adjList->indices->size)*sizeof(int),cudaMemcpyDeviceToHost);

  // HornetInit init(graph->numberOfVertices, graph->adjList->indices->size,
  //     static_cast<int*>(graph->adjList->offsets->data),
  //     static_cast<int*>(graph->adjList->indices->data));
  using HornetInit  = hornet::HornetInit<int>;


  HornetInit init(graph->numberOfVertices, graph->adjList->indices->size,
      h_tempOffset,
      h_tempIndices);

  HornetGraph hnt(init);

  free(h_tempOffset);
  free(h_tempIndices);
*/

  
  KTruss kt(hnt);

  kt.init();
  kt.reset();

  kt.createOffSetArray();
  kt.setInitParameters(4, 8, 2, 64000, 32);
  kt.reset(); 
  kt.sortHornet();

  kt.run();

  // *k_max = 12;

  *k_max = kt.getMaxK();

  kt.release();
  
  return GDF_SUCCESS;
}

gdf_error gdf_k_truss_max(gdf_graph *graph,
                          int *k_max) {
  CUGRAPH_EXPECTS(graph->edgeList->src_indices != nullptr || graph->edgeList->dest_indices != nullptr, "Invalid API parameter");
  CUGRAPH_EXPECTS(graph->edgeList->src_indices->data != nullptr || graph->edgeList->dest_indices->data != nullptr, "Invalid API parameter");

  // gdf_error err = gdf_add_adj_list(graph);
  // if (err != GDF_SUCCESS)
  //   return err;
  // GDF_REQUIRE(graph->adjList->offsets->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  // GDF_REQUIRE(graph->adjList->indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  CUGRAPH_EXPECTS(graph->edgeList->src_indices->dtype == GDF_INT32, "Unsupported data type");
  CUGRAPH_EXPECTS(graph->edgeList->dest_indices->dtype == GDF_INT32, "Unsupported data type");

  ktruss_max_impl(graph, k_max);

  return GDF_SUCCESS;
}

