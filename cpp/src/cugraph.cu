// -*-c++-*-

 /*
 * Copyright (c) 2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 *
 */

// Graph analytics features
// Author: Alex Fender afender@nvidia.com

#include <cugraph.h>
#include "graph_utils.cuh"
#include "COOtoCSR.cuh"
#include "utilities/error_utils.h"
#include "renumber.cuh"
#include <library_types.h>
#include <nvgraph/nvgraph.h>
#include <thrust/device_vector.h>

#include <rmm_utils.h>

/*
 * cudf has gdf_column_free and using this is, in general, better design than
 * creating our own, but we will keep this as cudf is planning to remove the
 * function. cudf plans to redesign cudf::column to fundamentally solve this
 * problem, so once they finished the redesign, we need to update this code to
 * use their new features. Until that time, we may rely on this as a temporary
 * solution.
 */
void gdf_col_delete(gdf_column* col) {
  if (col != nullptr) {
    cudaStream_t stream {nullptr};
    if (col->data != nullptr) {
      ALLOC_FREE_TRY(col->data, stream);
    }
    if (col->valid != nullptr) {
      ALLOC_FREE_TRY(col->valid, stream);
    }
#if 0/* Currently, gdf_column_view does not set col_name, and col_name can have
        an arbitrary value, so freeing col_name can lead to freeing a ranodom
        address. This problem should be cleaned up once cudf finishes
        redesigning cudf::column. */
    if (col->col_name != nullptr) {
      free(col->col_name);
    }
#endif
    delete col;
  }
}

void gdf_col_release(gdf_column* col) {
  delete col;
}

void cpy_column_view(const gdf_column *in, gdf_column *out) {
  if (in != nullptr && out !=nullptr) {
    gdf_column_view(out, in->data, in->valid, in->size, in->dtype);
  }
}

gdf_error gdf_adj_list_view(gdf_graph *graph, const gdf_column *offsets,
                                 const gdf_column *indices, const gdf_column *edge_data) {
  //This function returns an error if this graph object has at least one graph
  //representation to prevent a single object storing two different graphs.
  GDF_REQUIRE( ((graph->edgeList == nullptr) && (graph->adjList == nullptr) &&
    (graph->transposedAdjList == nullptr)), GDF_INVALID_API_CALL);
  GDF_REQUIRE( offsets->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( (offsets->dtype == indices->dtype), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((offsets->dtype == GDF_INT32) || (offsets->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( (offsets->size > 0), GDF_DATASET_EMPTY );

  graph->adjList = new gdf_adj_list;
  graph->adjList->offsets = new gdf_column;
  graph->adjList->indices = new gdf_column;
  graph->adjList->ownership = 0;

  cpy_column_view(offsets, graph->adjList->offsets);
  cpy_column_view(indices, graph->adjList->indices);
  if (edge_data) {
      GDF_REQUIRE( indices->size == edge_data->size, GDF_COLUMN_SIZE_MISMATCH );
      graph->adjList->edge_data = new gdf_column;
      cpy_column_view(edge_data, graph->adjList->edge_data);
  }
  else {
    graph->adjList->edge_data = nullptr;
  }
  return GDF_SUCCESS;
}

gdf_error gdf_adj_list::get_vertex_identifiers(gdf_column *identifiers) {
  GDF_REQUIRE( offsets != nullptr , GDF_INVALID_API_CALL);
  GDF_REQUIRE( offsets->data != nullptr , GDF_INVALID_API_CALL);
  cugraph::sequence<int>((int)offsets->size-1, (int*)identifiers->data);
  return GDF_SUCCESS;
}

gdf_error gdf_adj_list::get_source_indices (gdf_column *src_indices) {
  GDF_REQUIRE( offsets != nullptr , GDF_INVALID_API_CALL);
  GDF_REQUIRE( offsets->data != nullptr , GDF_INVALID_API_CALL);
  GDF_REQUIRE( src_indices->size == indices->size, GDF_COLUMN_SIZE_MISMATCH );
  GDF_REQUIRE( src_indices->dtype == indices->dtype, GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( src_indices->size > 0, GDF_DATASET_EMPTY );
  cugraph::offsets_to_indices<int>((int*)offsets->data, offsets->size-1, (int*)src_indices->data);

  return GDF_SUCCESS;
}

gdf_error gdf_renumber_vertices(const gdf_column *src, const gdf_column *dst,
                                gdf_column *src_renumbered, gdf_column *dst_renumbered,
                                gdf_column *numbering_map) {
  GDF_REQUIRE( src->size == dst->size, GDF_COLUMN_SIZE_MISMATCH );
  GDF_REQUIRE( src->dtype == dst->dtype, GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((src->dtype == GDF_INT32) || (src->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( src->size > 0, GDF_DATASET_EMPTY ); 

  //
  //  TODO: we're currently renumbering without using valid.  We need to
  //        worry about that at some point, but for now we'll just
  //        copy the valid pointers to the new columns and go from there.
  //
  cudaStream_t stream{nullptr};

  size_t src_size = src->size;
  size_t new_size;

  //
  // TODO:  I assume int64_t for output.  A few thoughts:
  //
  //    * I could match src->dtype - since if the raw values fit in an int32_t,
  //      then the renumbered values must fit within an int32_t
  //    * If new_size < (2^31 - 1) then I could allocate 32-bit integers
  //      and copy them in order to make the final footprint smaller.
  //
  //
  //  NOTE:  Forcing match right now - it appears that cugraph is artficially
  //         forcing the type to be 32
  if (src->dtype == GDF_INT32) {
    int32_t *tmp;

    ALLOC_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view(src_renumbered, tmp, src->valid, src->size, src->dtype);
  
    ALLOC_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view(dst_renumbered, tmp, dst->valid, dst->size, dst->dtype);

    gdf_error err = cugraph::renumber_vertices(src_size,
                                               (const int32_t *) src->data,
                                               (const int32_t *) dst->data,
                                               (int32_t *) src_renumbered->data,
                                               (int32_t *) dst_renumbered->data,
                                               &new_size, &tmp);
    if (err != GDF_SUCCESS)
      return err;

    gdf_column_view(numbering_map, tmp, nullptr, new_size, src->dtype);
  } else if (src->dtype == GDF_INT64) {

    //
    //  NOTE: At the moment, we force the renumbered graph to use
    //        32-bit integer ids.  Since renumbering is going to make
    //        the vertex range dense, this limits us to 2 billion
    //        vertices.
    //
    //        The renumbering code supports 64-bit integer generation
    //        so we can run this with int64_t output if desired...
    //        but none of the algorithms support that.
    //
    int64_t *tmp;
    ALLOC_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view(src_renumbered, tmp, src->valid, src->size, GDF_INT32);
  
    ALLOC_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view(dst_renumbered, tmp, dst->valid, dst->size, GDF_INT32);

    gdf_error err = cugraph::renumber_vertices(src_size,
                                               (const int64_t *) src->data,
                                               (const int64_t *) dst->data,
                                               (int32_t *) src_renumbered->data,
                                               (int32_t *) dst_renumbered->data,
                                               &new_size, &tmp);
    if (err != GDF_SUCCESS)
      return err;

    //
    //  If there are too many vertices then the renumbering overflows so we'll
    //  return an error.
    //
    if (new_size > 0x7fffffff) {
      ALLOC_FREE_TRY(src_renumbered, stream);
      ALLOC_FREE_TRY(dst_renumbered, stream);
      return GDF_COLUMN_SIZE_TOO_BIG;
    }

    gdf_column_view(numbering_map, tmp, nullptr, new_size, src->dtype);
  } else {
    return GDF_UNSUPPORTED_DTYPE;
  }

  return GDF_SUCCESS;
}

gdf_error gdf_edge_list_view(gdf_graph *graph, const gdf_column *src_indices,
                                 const gdf_column *dest_indices, const gdf_column *edge_data) {
  //This function returns an error if this graph object has at least one graph
  //representation to prevent a single object storing two different graphs.
  GDF_REQUIRE( ((graph->edgeList == nullptr) && (graph->adjList == nullptr) &&
    (graph->transposedAdjList == nullptr)), GDF_INVALID_API_CALL);
  GDF_REQUIRE( src_indices->size == dest_indices->size, GDF_COLUMN_SIZE_MISMATCH );
  GDF_REQUIRE( src_indices->dtype == dest_indices->dtype, GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((src_indices->dtype == GDF_INT32) || (src_indices->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( src_indices->size > 0, GDF_DATASET_EMPTY );
  GDF_REQUIRE( src_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( dest_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );

  graph->edgeList = new gdf_edge_list;
  graph->edgeList->src_indices = new gdf_column;
  graph->edgeList->dest_indices = new gdf_column;
  graph->edgeList->ownership = 0;

  cpy_column_view(src_indices, graph->edgeList->src_indices);
  cpy_column_view(dest_indices, graph->edgeList->dest_indices);
  if (edge_data) {
      GDF_REQUIRE( src_indices->size == edge_data->size, GDF_COLUMN_SIZE_MISMATCH );
      graph->edgeList->edge_data = new gdf_column;
      cpy_column_view(edge_data, graph->edgeList->edge_data);
  }
  else {
    graph->edgeList->edge_data = nullptr;
  }

  return GDF_SUCCESS;
}

template <typename T, typename WT>
gdf_error gdf_add_adj_list_impl (gdf_graph *graph) {
    if (graph->adjList == nullptr) {
      GDF_REQUIRE( graph->edgeList != nullptr , GDF_INVALID_API_CALL);
      int nnz = graph->edgeList->src_indices->size, status = 0;
      graph->adjList = new gdf_adj_list;
      graph->adjList->offsets = new gdf_column;
      graph->adjList->indices = new gdf_column;
      graph->adjList->ownership = 1;

    if (graph->edgeList->edge_data!= nullptr) {
      graph->adjList->edge_data = new gdf_column;

      CSR_Result_Weighted<int32_t,WT> adj_list;
      status = ConvertCOOtoCSR_weighted((int*)graph->edgeList->src_indices->data, (int*)graph->edgeList->dest_indices->data, (WT*)graph->edgeList->edge_data->data, nnz, adj_list);

      gdf_column_view(graph->adjList->offsets, adj_list.rowOffsets,
                            nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
      gdf_column_view(graph->adjList->indices, adj_list.colIndices,
                            nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
      gdf_column_view(graph->adjList->edge_data, adj_list.edgeWeights,
                          nullptr, adj_list.nnz, graph->edgeList->edge_data->dtype);
    }
    else {
      CSR_Result<int> adj_list;
      status = ConvertCOOtoCSR((int*)graph->edgeList->src_indices->data,(int*)graph->edgeList->dest_indices->data, nnz, adj_list);
      gdf_column_view(graph->adjList->offsets, adj_list.rowOffsets,
                            nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
      gdf_column_view(graph->adjList->indices, adj_list.colIndices,
                            nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
    }
    if (status !=0) {
      std::cerr << "Could not generate the adj_list" << std::endl;
      return GDF_CUDA_ERROR;
    }
  }
  return GDF_SUCCESS;
}

gdf_error gdf_add_edge_list (gdf_graph *graph) {
    if (graph->edgeList == nullptr) {
      GDF_REQUIRE( graph->adjList != nullptr , GDF_INVALID_API_CALL);
      int *d_src;
      graph->edgeList = new gdf_edge_list;
      graph->edgeList->src_indices = new gdf_column;
      graph->edgeList->dest_indices = new gdf_column;
      graph->edgeList->ownership = 2;

      cudaStream_t stream{nullptr};
      ALLOC_TRY((void**)&d_src, sizeof(int) * graph->adjList->indices->size, stream);

      cugraph::offsets_to_indices<int>((int*)graph->adjList->offsets->data,
                                  graph->adjList->offsets->size-1,
                                  (int*)d_src);

      gdf_column_view(graph->edgeList->src_indices, d_src,
                      nullptr, graph->adjList->indices->size, graph->adjList->indices->dtype);
      cpy_column_view(graph->adjList->indices, graph->edgeList->dest_indices);

      if (graph->adjList->edge_data != nullptr) {
        graph->edgeList->edge_data = new gdf_column;
        cpy_column_view(graph->adjList->edge_data, graph->edgeList->edge_data);
      }
  }
  return GDF_SUCCESS;
}


template <typename WT>
gdf_error gdf_add_transposed_adj_list_impl (gdf_graph *graph) {
    if (graph->transposedAdjList == nullptr ) {
      GDF_REQUIRE( graph->edgeList != nullptr , GDF_INVALID_API_CALL);
      int nnz = graph->edgeList->src_indices->size, status = 0;
      graph->transposedAdjList = new gdf_adj_list;
      graph->transposedAdjList->offsets = new gdf_column;
      graph->transposedAdjList->indices = new gdf_column;
      graph->transposedAdjList->ownership = 1;

      if (graph->edgeList->edge_data) {
        graph->transposedAdjList->edge_data = new gdf_column;
        CSR_Result_Weighted<int32_t,WT> adj_list;
        status = ConvertCOOtoCSR_weighted( (int*)graph->edgeList->dest_indices->data, (int*)graph->edgeList->src_indices->data, (WT*)graph->edgeList->edge_data->data, nnz, adj_list);
        gdf_column_view(graph->transposedAdjList->offsets, adj_list.rowOffsets,
                              nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
        gdf_column_view(graph->transposedAdjList->indices, adj_list.colIndices,
                              nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
        gdf_column_view(graph->transposedAdjList->edge_data, adj_list.edgeWeights,
                            nullptr, adj_list.nnz, graph->edgeList->edge_data->dtype);
      }
      else {

        CSR_Result<int> adj_list;
        status = ConvertCOOtoCSR((int*)graph->edgeList->dest_indices->data, (int*)graph->edgeList->src_indices->data, nnz, adj_list);
        gdf_column_view(graph->transposedAdjList->offsets, adj_list.rowOffsets,
                              nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
        gdf_column_view(graph->transposedAdjList->indices, adj_list.colIndices,
                              nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
      }
      if (status !=0) {
        std::cerr << "Could not generate the adj_list" << std::endl;
        return GDF_CUDA_ERROR;
      }
    }
    return GDF_SUCCESS;
}

gdf_error gdf_degree_impl(int n, int e, gdf_column* col_ptr, gdf_column* degree, bool offsets) {
  if(offsets == true) {
    dim3 nthreads, nblocks;
    nthreads.x = min(n, CUDA_MAX_KERNEL_THREADS);
    nthreads.y = 1;
    nthreads.z = 1;
    nblocks.x = min((n + nthreads.x - 1) / nthreads.x, CUDA_MAX_BLOCKS);
    nblocks.y = 1;
    nblocks.z = 1;

    switch (col_ptr->dtype) {
      case GDF_INT32:   cugraph::degree_offsets<int32_t, float> <<<nblocks, nthreads>>>(n, e, static_cast<int*>(col_ptr->data), static_cast<int*>(degree->data));break;
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  }
  else {
    dim3 nthreads, nblocks;
    nthreads.x = min(e, CUDA_MAX_KERNEL_THREADS);
    nthreads.y = 1;
    nthreads.z = 1;
    nblocks.x = min((e + nthreads.x - 1) / nthreads.x, CUDA_MAX_BLOCKS);
    nblocks.y = 1;
    nblocks.z = 1;

    switch (col_ptr->dtype) {
      case GDF_INT32:   cugraph::degree_coo<int32_t, float> <<<nblocks, nthreads>>>(n, e, static_cast<int*>(col_ptr->data), static_cast<int*>(degree->data));break;
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  }
  return GDF_SUCCESS;
}


gdf_error gdf_degree(gdf_graph *graph, gdf_column *degree, int x) {
  // Calculates the degree of all vertices of the graph
  // x = 0: in+out degree
  // x = 1: in-degree
  // x = 2: out-degree
  GDF_REQUIRE(graph->adjList != nullptr || graph->transposedAdjList != nullptr, GDF_INVALID_API_CALL);
  int n;
  int e;
  if(graph->adjList != nullptr) {
    n = graph->adjList->offsets->size -1;
    e = graph->adjList->indices->size;
  }
  else {
    n = graph->transposedAdjList->offsets->size - 1;
    e = graph->transposedAdjList->indices->size;
  }

  if(x!=1) {
    // Computes out-degree for x=0 and x=2
    if(graph->adjList)
      gdf_degree_impl(n, e, graph->adjList->offsets, degree, true);
    else
      gdf_degree_impl(n, e, graph->transposedAdjList->indices, degree, false);
  }

  if(x!=2) {
    // Computes in-degree for x=0 and x=1
    if(graph->adjList)
      gdf_degree_impl(n, e, graph->adjList->indices, degree, false);
    else
      gdf_degree_impl(n, e, graph->transposedAdjList->offsets, degree, true);
  }
  return GDF_SUCCESS;
}


gdf_error gdf_add_adj_list(gdf_graph *graph) {
  if (graph->adjList != nullptr)
    return GDF_SUCCESS;

  GDF_REQUIRE( graph->edgeList != nullptr , GDF_INVALID_API_CALL);
  GDF_REQUIRE( graph->edgeList->src_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE );

  if (graph->edgeList->edge_data != nullptr) {
    switch (graph->edgeList->edge_data->dtype) {
      case GDF_FLOAT32:   return gdf_add_adj_list_impl<int32_t, float>(graph);
      case GDF_FLOAT64:   return gdf_add_adj_list_impl<int32_t, double>(graph);
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  }
  else {
    return gdf_add_adj_list_impl<int32_t, float>(graph);
  }
}

gdf_error gdf_add_transposed_adj_list(gdf_graph *graph) {
  if (graph->edgeList == nullptr)
    gdf_add_edge_list(graph);

  GDF_REQUIRE(graph->edgeList->src_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(graph->edgeList->dest_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);

  if (graph->edgeList->edge_data != nullptr) {
    switch (graph->edgeList->edge_data->dtype) {
      case GDF_FLOAT32:   return gdf_add_transposed_adj_list_impl<float>(graph);
      case GDF_FLOAT64:   return gdf_add_transposed_adj_list_impl<double>(graph);
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  }
  else {
    return gdf_add_transposed_adj_list_impl<float>(graph);
  }
}

gdf_error gdf_delete_adj_list(gdf_graph *graph) {
  if (graph->adjList) {
    delete graph->adjList;
  }
  graph->adjList = nullptr;
  return GDF_SUCCESS;
}

gdf_error gdf_delete_edge_list(gdf_graph *graph) {
  if (graph->edgeList) {
    delete graph->edgeList;
  }
  graph->edgeList = nullptr;
  return GDF_SUCCESS;
}

gdf_error gdf_delete_transposed_adj_list(gdf_graph *graph) {
  if (graph->transposedAdjList) {
    delete graph->transposedAdjList;
  }
  graph->transposedAdjList = nullptr;
  return GDF_SUCCESS;
}

gdf_error gdf_louvain(gdf_graph *graph, void *final_modularity, void *num_level, gdf_column *louvain_parts) {
  GDF_REQUIRE(graph->adjList != nullptr || graph->edgeList != nullptr, GDF_INVALID_API_CALL);
  gdf_error err = gdf_add_adj_list(graph);
  if (err != GDF_SUCCESS)
    return err;

  size_t n = graph->adjList->offsets->size - 1;
  size_t e = graph->adjList->indices->size;

  void* offsets_ptr = graph->adjList->offsets->data;
  void* indices_ptr = graph->adjList->indices->data;

  void* value_ptr;
  rmm::device_vector<float> d_values;
  if(graph->adjList->edge_data) {
      value_ptr = graph->adjList->edge_data->data;
  }
  else {
      cudaStream_t stream {nullptr};
      d_values.resize(graph->adjList->indices->size);
      thrust::fill(rmm::exec_policy(stream)->on(stream), d_values.begin(), d_values.end(), 1.0);
      value_ptr = (void * ) thrust::raw_pointer_cast(d_values.data());
  }

  void* louvain_parts_ptr = louvain_parts->data;

  auto gdf_to_cudadtype= [](gdf_column *col){
    cudaDataType_t cuda_dtype;
    switch(col->dtype){
      case GDF_INT8: cuda_dtype = CUDA_R_8I; break;
      case GDF_INT32: cuda_dtype = CUDA_R_32I; break;
      case GDF_FLOAT32: cuda_dtype = CUDA_R_32F; break;
      case GDF_FLOAT64: cuda_dtype = CUDA_R_64F; break;
      default: throw new std::invalid_argument("Cannot convert data type");
      }return cuda_dtype;
  };

  cudaDataType_t index_type = gdf_to_cudadtype(graph->adjList->indices);
  cudaDataType_t val_type = graph->adjList->edge_data? gdf_to_cudadtype(graph->adjList->edge_data): CUDA_R_32F;

  nvgraphLouvain(index_type, val_type, n, e, offsets_ptr, indices_ptr, value_ptr, 1, 0, NULL,
                 final_modularity, louvain_parts_ptr, num_level);
  return GDF_SUCCESS;
}
