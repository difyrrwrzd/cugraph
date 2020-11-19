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

#include "louvain_api.cuh"

namespace cugraph {

// Explicit template instantations
// instantations with multi_gpu = true
template std::pair<size_t, float> louvain(
  raft::handle_t const &,
  experimental::graph_view_t<int32_t, int32_t, float, false, true> const &,
  int32_t *,
  size_t,
  float);
}  // namespace cugraph
