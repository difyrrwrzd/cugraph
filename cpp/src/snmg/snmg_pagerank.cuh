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

// snmg pagerank
// Author: Alex Fender afender@nvidia.com
 
#pragma once
#include "cub/cub.cuh"
#include <omp.h>
#include "graph_utils.cuh"
#include "snmg_utils.cuh"
#include "snmg_spmv.cuh"
//#define SNMG_DEBUG

namespace cugraph
{
  class SNMGpagerank 
{ 
  private:
    size_t v_glob;
    size_t v_loc;
    size_t e_loc;
    SNMGinfo env;
    size_t* part_off;
    IndexType * off;
    IndexType * ind;
    ValueType * val;
    ValueType * a;
    ValueType * b;
    ValueType * tmp;
    bool converged;
    bool is_setup;

  public: 
    SNMGpagerank(SNMGinfo & env_, size_t* part_off_, 
                 IndexType * off_, IndexType * ind_) : 
                 env(env_), part_off(part_off_), off(off_), ind(ind_) { 
      v_glob = part_off[p];
      v_loc = part_off[i+1]-part_off[i];
      IndexType tmp;
      CUDA_TRY(cudaMemcpy(&tmp, &off[v_loc], sizeof(idx_t),cudaMemcpyDeviceToHost));
      e_loc = tmp;
    } 
    ~SNMGpagerank() { 
      // TODO free _val, _a, _b, tmp
    }
    // compute degree and tansition matrix 
    // allocate and set _val, _a, _b, tmp.
    bool setup(ValueType alpha) {
      
      //todo
      is_setup=true;
      return true;
    }

    // run the power iteration
    bool solve (float tolerance, int max_iter, ValueType ** pagerank) {

    converged = false;
    ValueType  dot_res;
    ValueType residual;
    int id = env.get_thread_num()
    ValueType pr = pagerank[id];
    int iter;

    for (iter = 0; iter < max_iter; ++iter) {
      snmg_csrmv (env, part_off, off, ind, val, pagerank);
      scal(v_glob, alpha, pr);
      dot_res = dot( v_glob, a, tmp);
      axpy(v_glob, dot_res,  b,  pr);
      scal(v_glob, (ValueType)1.0/nrm2(v_glob, pr) , pr);
      axpy(v_glob, (ValueType)-1.0,  pr,  tmp);
      residual = nrm2(v_glob, tmp);
      if (residual < tolerance) {
          scal(v_glob, (ValueType)1.0/nrm1(v_glob,pr), pr);
          converged = true;
          break;
      }
      else {
          if (iter< max_iter) {
              std::swap(pr, tmp);
          }
          else {
             scal(v_glob, (ValueType)1.0/nrm1(v_glob,pr), pr);
          }
      }
    }
  }
};


    template<typename IndexType, typename ValueType>
  __global__ void __launch_bounds__(CUDA_MAX_KERNEL_THREADS)
  transition_kernel(const IndexType e,
                    const IndexType *ind,
                    IndexType *degree,
                    ValueType *val) {
    for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < e; i += gridDim.x * blockDim.x)
      val[i] = 1.0 / degree[ind[i]];
  }

  void transition_vals( SNMGinfo & env,
                        const IndexType e,
                        const IndexType *csrInd,
                        const IndexType *degree,
                        ValueType *val) {
    int threads min(e, 256);
    int blocks min(32*env.get_num_sm(), CUDA_MAX_BLOCKS);
    transition_kernel<IndexType, ValueType> <<<blocks, threads>>> (e, csrInd, degree, val);
    cudaCheckError();
  }

  template <typename IndexType, typename ValueType>
  bool  pagerankIteration( IndexType n, IndexType e, IndexType *cscPtr, IndexType *cscInd,ValueType *cscVal,
                           ValueType alpha, ValueType *a, ValueType *b, float tolerance, int iter, int max_iter, 
                           ValueType * &tmp, ValueType * &pr, ValueType *residual) {
    




} //namespace cugraph
