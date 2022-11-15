/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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
 * See the License for the specific language governin_from_mtxg permissions and
 * limitations under the License.
 */

#include <cugraph/graph_view.hpp>

#include <raft/handle.hpp>

#include <rmm/device_uvector.hpp>

namespace cugraph {
namespace test {

template <typename vertex_t, typename edge_t, typename weight_t>
void check_correctness(raft::handle_t const& handle,
                       graph_view_t<vertex_t, edge_t, weight_t, false, false> const& graph_view,
                       rmm::device_uvector<edge_t> const& core_numbers,
                       std::tuple<rmm::device_uvector<vertex_t>,
                                  rmm::device_uvector<vertex_t>,
                                  std::optional<rmm::device_uvector<weight_t>>> const& subgraph,
                       size_t k);

}  // namespace test
}  // namespace cugraph
