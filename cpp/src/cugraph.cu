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
#include "pagerank.cuh"
#include "COOtoCSR.cuh"
#include "utilities/error_utils.h"
#include "bfs.cuh"
#include "renumber.cuh"

#include <rmm_utils.h>

void gdf_col_delete(gdf_column* col) {
  if (col)
  {
    col->size = 0; 
    if(col->data)
        {
        ALLOC_FREE_TRY(col->data, nullptr);
        }
#if 1
// If delete col is executed, the memory pointed by col is no longer valid and
// can be used in another memory allocation, so executing col->data = nullptr
// after delete col is dangerous, also, col = nullptr has no effect here (the
// address is passed by value, for col = nullptr should work, the input
// parameter should be gdf_column*& col (or alternatively, gdf_column** col and
// *col = nullptr also work)
    col->data = nullptr;
    delete col;
#else
    delete col;
    col->data = nullptr;
    col = nullptr;
#endif
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
  GDF_REQUIRE( offsets->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );                    
  GDF_REQUIRE( indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( (offsets->dtype == indices->dtype), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((offsets->dtype == GDF_INT32) || (offsets->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( (offsets->size > 0), GDF_DATASET_EMPTY ); 
  GDF_REQUIRE( (graph->adjList == nullptr) , GDF_INVALID_API_CALL);

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
				gdf_column **src_renumbered, gdf_column **dst_renumbered,
				gdf_column **numbering_map) {

  GDF_REQUIRE( src->size == dst->size, GDF_COLUMN_SIZE_MISMATCH );
  GDF_REQUIRE( src->dtype == dst->dtype, GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((src->dtype == GDF_INT32) || (src->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( src->size > 0, GDF_DATASET_EMPTY ); 

  *src_renumbered = new gdf_column;
  *dst_renumbered = new gdf_column;
  *numbering_map = new gdf_column;

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

    printf("in renumber, 32-bit\n");
    ALLOC_MANAGED_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view((*src_renumbered), tmp, src->valid, src->size, src->dtype);
  
    ALLOC_MANAGED_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view((*dst_renumbered), tmp, dst->valid, dst->size, dst->dtype);

    gdf_error err = cugraph::renumber_vertices(src_size,
					       (const int32_t *) src->data,
					       (const int32_t *) dst->data,
					       (int32_t *) (*src_renumbered)->data,
					       (int32_t *) (*dst_renumbered)->data,
					       &new_size, &tmp);
    if (err != GDF_SUCCESS)
      return err;

    gdf_column_view((*numbering_map), tmp, nullptr, new_size, GDF_INT32);
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
    printf("in renumber, 64-bit, src->dtype = %d\n", src->dtype);
    int64_t *tmp;
    ALLOC_MANAGED_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view((*src_renumbered), tmp, src->valid, src->size, GDF_INT32);
  
    ALLOC_MANAGED_TRY((void**) &tmp, sizeof(int32_t) * src->size, stream);
    gdf_column_view((*dst_renumbered), tmp, dst->valid, dst->size, GDF_INT32);

    gdf_error err = cugraph::renumber_vertices(src_size,
					       (const int64_t *) src->data,
					       (const int64_t *) dst->data,
					       (int32_t *) (*src_renumbered)->data,
					       (int32_t *) (*dst_renumbered)->data,
					       &new_size, &tmp);
    if (err != GDF_SUCCESS)
      return err;

    //
    //  If there are too many vertices then the renumbering overflows so we'll
    //  return an error.
    //
    if (new_size > 0x7fffffff) {
      ALLOC_FREE_TRY((*src_renumbered), stream);
      ALLOC_FREE_TRY((*dst_renumbered), stream);
      return GDF_COLUMN_SIZE_TOO_BIG;
    }

    gdf_column_view((*numbering_map), tmp, nullptr, new_size, GDF_INT32);

    printf("done with renumbering, data types: %d, %d, %d\n", (*src_renumbered)->dtype, (*dst_renumbered)->dtype, (*numbering_map)->dtype);
  } else {
    return GDF_UNSUPPORTED_DTYPE;
  }

  return GDF_SUCCESS;
}

gdf_error gdf_edge_list_view(gdf_graph *graph, const gdf_column *src_indices, 
                                 const gdf_column *dest_indices, const gdf_column *edge_data) {
  GDF_REQUIRE( src_indices->size == dest_indices->size, GDF_COLUMN_SIZE_MISMATCH );
  GDF_REQUIRE( src_indices->dtype == dest_indices->dtype, GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( ((src_indices->dtype == GDF_INT32) || (src_indices->dtype == GDF_INT64)), GDF_UNSUPPORTED_DTYPE );
  GDF_REQUIRE( src_indices->size > 0, GDF_DATASET_EMPTY ); 
  GDF_REQUIRE( src_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );                    
  GDF_REQUIRE( dest_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( graph->edgeList == nullptr , GDF_INVALID_API_CALL);

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

      CSR_Result_Weighted<T,WT> adj_list;
      status = ConvertCOOtoCSR_weighted((T *)graph->edgeList->src_indices->data,
                                        (T *)graph->edgeList->dest_indices->data,
                                        (WT*)graph->edgeList->edge_data->data,
                                        nnz, adj_list);
      
      gdf_column_view(graph->adjList->offsets, adj_list.rowOffsets, 
                            nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
      gdf_column_view(graph->adjList->indices, adj_list.colIndices, 
                            nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
      gdf_column_view(graph->adjList->edge_data, adj_list.edgeWeights, 
                          nullptr, adj_list.nnz, graph->edgeList->edge_data->dtype);
    }
    else {
      CSR_Result<T> adj_list;

      status = ConvertCOOtoCSR((T *)graph->edgeList->src_indices->data,
                               (T *)graph->edgeList->dest_indices->data,
                               nnz, adj_list);
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


      CUDA_TRY(cudaMallocManaged ((void**)&d_src, sizeof(int) * graph->adjList->indices->size));

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


template <typename T, typename WT>
gdf_error gdf_add_transpose_impl (gdf_graph *graph) {
    if (graph->transposedAdjList == nullptr ) {
      GDF_REQUIRE( graph->edgeList != nullptr , GDF_INVALID_API_CALL);
      int nnz = graph->edgeList->src_indices->size, status = 0;
      graph->transposedAdjList = new gdf_adj_list;
      graph->transposedAdjList->offsets = new gdf_column;
      graph->transposedAdjList->indices = new gdf_column;
      graph->transposedAdjList->ownership = 1;
    
      if (graph->edgeList->edge_data) {
        graph->transposedAdjList->edge_data = new gdf_column;
        CSR_Result_Weighted<T,WT> adj_list;
        status = ConvertCOOtoCSR_weighted((T *) graph->edgeList->dest_indices->data,
                                          (T *) graph->edgeList->src_indices->data,
                                          (WT *) graph->edgeList->edge_data->data,
                                          nnz, adj_list);
        gdf_column_view(graph->transposedAdjList->offsets, adj_list.rowOffsets, 
                              nullptr, adj_list.size+1, graph->edgeList->src_indices->dtype);
        gdf_column_view(graph->transposedAdjList->indices, adj_list.colIndices, 
                              nullptr, adj_list.nnz, graph->edgeList->src_indices->dtype);
        gdf_column_view(graph->transposedAdjList->edge_data, adj_list.edgeWeights, 
                            nullptr, adj_list.nnz, graph->edgeList->edge_data->dtype);
      }
      else {

        CSR_Result<T> adj_list;
        status = ConvertCOOtoCSR((T *) graph->edgeList->dest_indices->data,
                                 (T *) graph->edgeList->src_indices->data,
                                 nnz, adj_list);      
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

template <typename T, typename WT>
gdf_error gdf_pagerank_impl (gdf_graph *graph,
                      gdf_column *pagerank, float alpha = 0.85,
                      float tolerance = 1e-4, int max_iter = 200,
                      bool has_guess = false) {

  
  GDF_REQUIRE( graph->edgeList != nullptr, GDF_VALIDITY_UNSUPPORTED );
  GDF_REQUIRE( graph->edgeList->src_indices->size == graph->edgeList->dest_indices->size, GDF_COLUMN_SIZE_MISMATCH ); 
  GDF_REQUIRE( graph->edgeList->src_indices->dtype == graph->edgeList->dest_indices->dtype, GDF_UNSUPPORTED_DTYPE );  
  GDF_REQUIRE( graph->edgeList->src_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );                 
  GDF_REQUIRE( graph->edgeList->dest_indices->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );  
  GDF_REQUIRE( pagerank != nullptr , GDF_INVALID_API_CALL ); 
  GDF_REQUIRE( pagerank->data != nullptr , GDF_INVALID_API_CALL ); 
  GDF_REQUIRE( pagerank->null_count == 0 , GDF_VALIDITY_UNSUPPORTED );          
  GDF_REQUIRE( pagerank->size > 0 , GDF_INVALID_API_CALL );         

  int m=pagerank->size, nnz = graph->edgeList->src_indices->size, status = 0;
  WT *d_pr, *d_val = nullptr, *d_leaf_vector = nullptr; 
  WT res = 1.0;
  WT *residual = &res;

  if (graph->transposedAdjList == nullptr) {
    gdf_add_transpose(graph);
  }
  cudaStream_t stream{nullptr};
  ALLOC_MANAGED_TRY((void**)&d_leaf_vector, sizeof(WT) * m, stream);
  ALLOC_MANAGED_TRY((void**)&d_val, sizeof(WT) * nnz , stream);
  ALLOC_MANAGED_TRY((void**)&d_pr,    sizeof(WT) * m, stream);

  //  The templating for HT_matrix_csc_coo assumes that m, nnz and data are all the same type
  T localm = m;
  T localnnz = nnz;
  cugraph::HT_matrix_csc_coo(localm, localnnz, (T *)graph->transposedAdjList->offsets->data, (T *)graph->transposedAdjList->indices->data, d_val, d_leaf_vector);

  if (has_guess)
  {
    GDF_REQUIRE( pagerank->data != nullptr, GDF_VALIDITY_UNSUPPORTED );
    cugraph::copy<WT>(m, (WT*)pagerank->data, d_pr);
  }

  status = cugraph::pagerank<T,WT>( m,nnz, (T *) graph->transposedAdjList->offsets->data, (T *) graph->transposedAdjList->indices->data, 
    d_val, alpha, d_leaf_vector, false, tolerance, max_iter, d_pr, residual);
 
  if (status !=0)
    switch ( status ) { 
      case -1: std::cerr<< "Error : bad parameters in Pagerank"<<std::endl; return GDF_CUDA_ERROR; 
      case 1: std::cerr<< "Warning : Pagerank did not reached the desired tolerance"<<std::endl;  return GDF_CUDA_ERROR; 
      default:  std::cerr<< "Pagerank failed"<<std::endl;  return GDF_CUDA_ERROR; 
    }   
 
  cugraph::copy<WT>(m, d_pr, (WT*)pagerank->data);

  ALLOC_FREE_TRY(d_val, stream);
  ALLOC_FREE_TRY(d_pr, stream);
  ALLOC_FREE_TRY(d_leaf_vector, stream);

  return GDF_SUCCESS;
}


gdf_error gdf_add_adj_list(gdf_graph *graph)
{ 
  if (graph->adjList != nullptr)
    return GDF_SUCCESS;

  GDF_REQUIRE( graph->edgeList != nullptr , GDF_INVALID_API_CALL);
  GDF_REQUIRE( graph->edgeList->src_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE );

  if (graph->edgeList->edge_data != nullptr) {
    switch (graph->edgeList->edge_data->dtype) {
      case GDF_FLOAT32:   return gdf_add_adj_list_impl<int, float>(graph);
      case GDF_FLOAT64:   return gdf_add_adj_list_impl<int, double>(graph);
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  }
  else {
    return gdf_add_adj_list_impl<int, float>(graph);
  }
}

gdf_error gdf_add_transpose(gdf_graph *graph)
{
  //
  //  If coo doesn't exist, create it.  Then check type to make sure it is 32-bit.
  //
  if (graph->edgeList == nullptr)
    gdf_add_edge_list(graph);

  GDF_REQUIRE(graph->edgeList->src_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(graph->edgeList->dest_indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);

  if (graph->edgeList->edge_data != nullptr) {
    switch (graph->edgeList->edge_data->dtype) {
      case GDF_FLOAT32:   return gdf_add_transpose_impl<int, float>(graph);
      case GDF_FLOAT64:   return gdf_add_transpose_impl<int, double>(graph);
      default: return GDF_UNSUPPORTED_DTYPE;
    }
  } else {
    return gdf_add_transpose_impl<int, float>(graph);
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
gdf_error gdf_delete_transpose(gdf_graph *graph) {
  if (graph->transposedAdjList) {
    delete graph->transposedAdjList;
  }
  graph->transposedAdjList = nullptr;
  return GDF_SUCCESS;
}

gdf_error gdf_pagerank(gdf_graph *graph, gdf_column *pagerank, float alpha, float tolerance, int max_iter, bool has_guess) {
  //
  //  page rank operates on CSR and can't currently support 64-bit integers.
  //
  //  If csr doesn't exist, create it.  Then check type to make sure it is 32-bit.
  //
  GDF_REQUIRE(graph->adjList != nullptr || graph->edgeList != nullptr, GDF_INVALID_API_CALL);
  gdf_error err = gdf_add_adj_list(graph);
  if (err != GDF_SUCCESS)
    return err;

  GDF_REQUIRE(graph->adjList->offsets->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(graph->adjList->indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);

  switch (pagerank->dtype) {
    case GDF_FLOAT32:   return gdf_pagerank_impl<int, float>(graph, pagerank, alpha, tolerance, max_iter, has_guess);
    case GDF_FLOAT64:   return gdf_pagerank_impl<int, double>(graph, pagerank, alpha, tolerance, max_iter, has_guess);
    default: return GDF_UNSUPPORTED_DTYPE;
  }
}

gdf_error gdf_bfs(gdf_graph *graph, gdf_column *distances, gdf_column *predecessors, int start_node, bool directed) {
  GDF_REQUIRE(graph->adjList != nullptr || graph->edgeList != nullptr, GDF_INVALID_API_CALL);
  gdf_error err = gdf_add_adj_list(graph);
  if (err != GDF_SUCCESS)
    return err;
  GDF_REQUIRE(graph->adjList->offsets->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(graph->adjList->indices->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(distances->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);
  GDF_REQUIRE(predecessors->dtype == GDF_INT32, GDF_UNSUPPORTED_DTYPE);

  int n = graph->adjList->offsets->size - 1;
  int e = graph->adjList->indices->size;
  int* offsets_ptr = (int*)graph->adjList->offsets->data;
  int* indices_ptr = (int*)graph->adjList->indices->data;
  int* distances_ptr = (int*)distances->data;
  int* predecessors_ptr = (int*)predecessors->data;
  int alpha = 15;
  int beta = 18;

  cugraph::Bfs<int> bfs(n, e, offsets_ptr, indices_ptr, directed, alpha, beta);
  bfs.configure(distances_ptr, predecessors_ptr, nullptr);
  bfs.traverse(start_node);
  return GDF_SUCCESS;
}
